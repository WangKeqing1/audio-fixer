package com.audiofixer.audio_fixer

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import java.security.MessageDigest
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Bridges Flutter to the user's Android media library without taking ownership
 * of the original media files.
 */
class DeviceLibraryBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "device-library-io").apply { isDaemon = true }
    }
    private val preferences = activity.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val exportJournal = ExportRecoveryJournal(activity)
    @Volatile private var exportActive = false

    @Volatile
    private var disposed = false

    /** Only one Android runtime permission request may be active at a time. */
    private var pendingPermissionResult: OneShotResult? = null
    private var pendingExport: PendingExport? = null

    init {
        channel.setMethodCallHandler(::onMethodCall)
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (disposed || requestCode != PERMISSION_REQUEST_CODE) return

        val reply = pendingPermissionResult ?: return
        pendingPermissionResult = null

        // Read the current system state instead of trusting grantResults. This
        // also handles a cancelled permission sheet and OEM-specific results.
        reply.success(permissionStatusValue())
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        pendingPermissionResult = null
        channel.setMethodCallHandler(null)
        ioExecutor.shutdownNow()
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) return

        when (call.method) {
            "permissionStatus" -> OneShotResult(result).success(permissionStatusValue())
            "requestPermission" -> requestPermission(result)
            "openSettings" -> openSettings(result)
            "querySongs" -> querySongs(result)
            "copyForRead" -> copyForRead(call, result)
            "releaseReadCopy" -> releaseReadCopy(call, result)
            "exportAudioCopy" -> exportAudioCopy(call, result)
            "recoverExport" -> executeIo(OneShotResult(result), "export_recovery_failed") {
                if (exportActive) exportJournal.notice() else exportJournal.recover()
            }
            "acknowledgeExportRecovery" -> executeIo(OneShotResult(result), "export_recovery_failed") {
                exportJournal.setNotice(null)
                null
            }
            "confirmExportRecorded" -> executeIo(OneShotResult(result), "export_recovery_failed") {
                val uri = call.argument<String>("uri")
                    ?: throw BridgeException("invalid_argument", "An exported document URI is required.")
                exportJournal.acknowledgeVerified(uri)
                null
            }
            else -> result.notImplemented()
        }
    }

    private fun requestPermission(result: MethodChannel.Result) {
        val reply = OneShotResult(result)
        if (pendingPermissionResult != null) {
            reply.error(
                "request_in_progress",
                "An audio permission request is already in progress.",
                null,
            )
            return
        }

        val currentStatus = permissionStatusValue()
        when (currentStatus) {
            PERMISSION_GRANTED -> reply.success(PERMISSION_GRANTED)
            PERMISSION_BLOCKED -> reply.success(PERMISSION_BLOCKED)
            else -> {
                // Persist this before opening the sheet. If Android recreates
                // the activity while the sheet is visible, the next status is
                // still based on the fact that a request was made.
                preferences.edit().putBoolean(KEY_PERMISSION_REQUESTED, true).apply()
                pendingPermissionResult = reply
                try {
                    activity.requestPermissions(arrayOf(requiredPermission()), PERMISSION_REQUEST_CODE)
                } catch (error: SecurityException) {
                    pendingPermissionResult = null
                    reply.error(
                        "request_failed",
                        "Unable to request audio permission.",
                        error.message,
                    )
                } catch (error: RuntimeException) {
                    pendingPermissionResult = null
                    reply.error(
                        "request_failed",
                        "Unable to request audio permission.",
                        error.message,
                    )
                }
            }
        }
    }

    private fun openSettings(result: MethodChannel.Result) {
        val reply = OneShotResult(result)
        try {
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:${activity.packageName}"),
            )
            activity.startActivity(intent)
            reply.success(null)
        } catch (error: ActivityNotFoundException) {
            reply.error(
                "settings_failed",
                "Unable to open this app's system settings.",
                error.message,
            )
        } catch (error: RuntimeException) {
            reply.error(
                "settings_failed",
                "Unable to open this app's system settings.",
                error.message,
            )
        }
    }

    private fun querySongs(result: MethodChannel.Result) {
        val reply = OneShotResult(result)
        if (!hasLibraryPermission()) {
            reply.error(
                "permission_denied",
                "Audio library permission is required before querying songs.",
                null,
            )
            return
        }

        executeIo(reply, "query_failed") {
            if (!hasLibraryPermission()) {
                throw BridgeException(
                    "permission_denied",
                    "Audio library permission is no longer granted.",
                )
            }
            querySongsOnWorker()
        }
    }

    private fun copyForRead(call: MethodCall, result: MethodChannel.Result) {
        val reply = OneShotResult(result)
        val arguments = call.arguments as? Map<*, *>
        val uriText = arguments?.get("uri") as? String
        if (uriText == null) {
            reply.error("invalid_argument", "copyForRead requires a string uri.", null)
            return
        }

        val mediaUri = parseAllowedMediaUri(uriText)
        if (mediaUri == null) {
            reply.error(
                "invalid_argument",
                "Only content://media/<volume>/audio/media/<id> is allowed.",
                null,
            )
            return
        }
        if (!hasLibraryPermission()) {
            reply.error(
                "permission_denied",
                "Audio library permission is required before reading a song.",
                null,
            )
            return
        }

        executeIo(reply, "read_failed") {
            if (!hasLibraryPermission()) {
                throw BridgeException(
                    "permission_denied",
                    "Audio library permission is no longer granted.",
                )
            }
            copyForReadOnWorker(mediaUri)
        }
    }

    private fun releaseReadCopy(call: MethodCall, result: MethodChannel.Result) {
        val reply = OneShotResult(result)
        val arguments = call.arguments as? Map<*, *>
        val path = arguments?.get("path") as? String
        if (path == null) {
            reply.error("invalid_argument", "releaseReadCopy requires a string path.", null)
            return
        }

        executeIo(reply, "read_failed") {
            releaseReadCopyOnWorker(path)
            null
        }
    }

    private data class PendingExport(val file: File, val reply: OneShotResult)

    private fun exportAudioCopy(call: MethodCall, result: MethodChannel.Result) {
        val reply = OneShotResult(result)
        if (exportActive || pendingExport != null) {
            reply.error("export_in_progress", "An export is already in progress.", null)
            return
        }
        val path = call.argument<String>("path")
        val name = call.argument<String>("fileName")
        val mime = call.argument<String>("mimeType")
        if (path == null || name.isNullOrBlank() || mime !in setOf("audio/mpeg", "audio/flac", "audio/mp4")) {
            reply.error("invalid_argument", "Invalid audio export request.", null)
            return
        }
        try {
            val root = File(activity.cacheDir, "tagged_exports").canonicalFile
            val file = File(path).canonicalFile
            if (!file.path.startsWith(root.path + File.separator) || !file.isFile || file.length() == 0L) {
                reply.error("invalid_argument", "Only verified temporary audio copies may be exported.", null)
                return
            }
            // Flush provenance before Android can create any destination.
            exportJournal.record(ExportRecoveryJournal.PREPARED, file)
            exportActive = true
            pendingExport = PendingExport(file, reply)
            // ACTION_CREATE_DOCUMENT creates a separate document. Never request
            // a writable handle to the source MediaStore URI.
            activity.startActivityForResult(
                Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = mime
                    putExtra(Intent.EXTRA_TITLE, File(name).name)
                },
                EXPORT_REQUEST_CODE,
            )
        } catch (error: Exception) {
            pendingExport = null
            exportActive = false
            reply.error("export_failed", "Unable to open the system save dialog.", error.message)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (disposed || requestCode != EXPORT_REQUEST_CODE) return
        val pending = pendingExport
        pendingExport = null
        val target = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (pending == null) {
            // Android may deliver this after Activity/process recreation.
            try {
                ioExecutor.execute {
                    try { exportJournal.recoverOrphanResult(target) } catch (_: Exception) {
                        // Keep the durable record; startup recovery can retry.
                    }
                }
            } catch (_: RuntimeException) {
                // The durable journal remains available on the next launch.
            }
            return
        }
        if (target == null) {
            exportActive = false
            try { exportJournal.clear() } catch (_: IOException) { /* recover next launch */ }
            pending.reply.success(null)
            return
        }
        try {
            // This must commit before opening a writable destination handle.
            exportJournal.record(ExportRecoveryJournal.WRITING, pending.file, target)
        } catch (error: IOException) {
            exportActive = false
            val removed = exportJournal.deleteNewDocument(target)
            pending.reply.error(if (removed) "export_failed" else "export_cleanup_failed", error.message, null)
            return
        }
        executeIo(pending.reply, "export_failed") {
            exportJournal.exclusively {
                try {
                    val expected = MessageDigest.getInstance("SHA-256")
                    val stream = activity.contentResolver.openOutputStream(target, "w")
                        ?: throw IOException("Unable to create exported audio.")
                    stream.use { output ->
                        pending.file.inputStream().use { input ->
                            val buffer = ByteArray(COPY_BUFFER_BYTES)
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                expected.update(buffer, 0, count)
                                output.write(buffer, 0, count)
                            }
                            output.flush()
                        }
                    }
                    val actual = MessageDigest.getInstance("SHA-256")
                    val verify = activity.contentResolver.openInputStream(target)
                        ?: throw IOException("Unable to verify exported audio.")
                    verify.use { input ->
                        val buffer = ByteArray(COPY_BUFFER_BYTES)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            actual.update(buffer, 0, count)
                        }
                    }
                    if (!MessageDigest.isEqual(expected.digest(), actual.digest())) {
                        throw IOException("The saved audio failed integrity verification.")
                    }
                    // Dart acknowledges this exact URI only after its task record commits.
                    exportJournal.record(ExportRecoveryJournal.VERIFIED, pending.file, target)
                    target.toString()
                } catch (error: Exception) {
                    // This URI is a new document from ACTION_CREATE_DOCUMENT only.
                    // Remove partial output if the provider supports deletion.
                    val removed = exportJournal.deleteNewDocument(target)
                    if (!removed) {
                        throw BridgeException(
                            "export_cleanup_failed",
                            "Audio export failed and the incomplete new document could not be removed. " +
                                "Delete the incomplete copy manually; the original is unchanged.",
                        )
                    }
                    try { exportJournal.clear() } catch (_: IOException) { /* recover next launch */ }
                    throw IOException("Audio export failed; the original is unchanged.", error)
                } finally {
                    exportActive = false
                }
            }
        }
    }

    private fun <T> executeIo(
        reply: OneShotResult,
        defaultErrorCode: String,
        block: () -> T,
    ) {
        try {
            ioExecutor.execute {
                try {
                    reply.success(block())
                } catch (error: BridgeException) {
                    reply.error(error.code, error.message, null)
                } catch (error: SecurityException) {
                    reply.error(
                        "permission_denied",
                        "Android denied access to the media library.",
                        null,
                    )
                } catch (error: IOException) {
                    reply.error(defaultErrorCode, error.message ?: "Media operation failed.", null)
                } catch (error: RuntimeException) {
                    reply.error(defaultErrorCode, error.message ?: "Media operation failed.", null)
                }
            }
        } catch (error: RuntimeException) {
            reply.error(defaultErrorCode, "Media operation could not be scheduled.", error.message)
        }
    }

    private fun permissionStatusValue(): String {
        if (hasLibraryPermission()) return PERMISSION_GRANTED
        if (!preferences.getBoolean(KEY_PERMISSION_REQUESTED, false)) {
            return PERMISSION_NOT_REQUESTED
        }
        return if (activity.shouldShowRequestPermissionRationale(requiredPermission())) {
            PERMISSION_DENIED
        } else {
            PERMISSION_BLOCKED
        }
    }

    private fun hasLibraryPermission(): Boolean {
        // Runtime permissions did not exist before API 23. The manifest
        // permission is granted at install time on those releases.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return activity.checkSelfPermission(requiredPermission()) == PackageManager.PERMISSION_GRANTED
    }

    private fun requiredPermission(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }

    private fun querySongsOnWorker(): List<Map<String, Any?>> {
        val rows = ArrayList<Map<String, Any?>>()
        val volumes = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.getExternalVolumeNames(activity).toList().sorted()
        } else {
            listOf(EXTERNAL_VOLUME)
        }

        for (volume in volumes) {
            val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.Audio.Media.getContentUri(volume)
            } else {
                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
            }
            queryVolume(collection, volume, rows)
        }
        return rows
    }

    private fun queryVolume(
        collection: Uri,
        volume: String,
        rows: MutableList<Map<String, Any?>>,
    ) {
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.Audio.AudioColumns.TITLE,
            MediaStore.Audio.AudioColumns.ARTIST,
            MediaStore.Audio.AudioColumns.ALBUM,
            MediaStore.Audio.AudioColumns.YEAR,
            MediaStore.Audio.AudioColumns.DURATION,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.DATE_MODIFIED,
            MediaStore.Audio.AudioColumns.IS_MUSIC,
        )
        val selectionParts = mutableListOf(
            "${MediaStore.Audio.AudioColumns.IS_MUSIC} != 0",
            "${MediaStore.MediaColumns.SIZE} > 0",
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            selectionParts += "${MediaStore.MediaColumns.IS_PENDING} = 0"
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            selectionParts += "${MediaStore.MediaColumns.IS_TRASHED} = 0"
        }

        val sortOrder = "${MediaStore.MediaColumns.DATE_ADDED} DESC, ${MediaStore.MediaColumns._ID} ASC"
        val cursor = activity.contentResolver.query(
            collection,
            projection,
            selectionParts.joinToString(" AND "),
            null,
            sortOrder,
        ) ?: throw IOException("The media provider returned no query cursor.")

        cursor.use {
            val idIndex = cursor.getColumnIndex(MediaStore.MediaColumns._ID)
            val displayNameIndex = cursor.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
            val sizeIndex = cursor.getColumnIndex(MediaStore.MediaColumns.SIZE)
            val titleIndex = cursor.getColumnIndex(MediaStore.Audio.AudioColumns.TITLE)
            val artistIndex = cursor.getColumnIndex(MediaStore.Audio.AudioColumns.ARTIST)
            val albumIndex = cursor.getColumnIndex(MediaStore.Audio.AudioColumns.ALBUM)
            val yearIndex = cursor.getColumnIndex(MediaStore.Audio.AudioColumns.YEAR)
            val durationIndex = cursor.getColumnIndex(MediaStore.Audio.AudioColumns.DURATION)
            val addedIndex = cursor.getColumnIndex(MediaStore.MediaColumns.DATE_ADDED)
            val modifiedIndex = cursor.getColumnIndex(MediaStore.MediaColumns.DATE_MODIFIED)

            while (cursor.moveToNext()) {
                if (idIndex < 0 || sizeIndex < 0 || cursor.isNull(idIndex) || cursor.isNull(sizeIndex)) continue
                val id = cursor.getLong(idIndex)
                val sizeBytes = cursor.getLong(sizeIndex)
                if (id <= 0L || sizeBytes <= 0L) continue

                val fileName = cursor.getStringOrNull(displayNameIndex)?.takeIf { it.isNotEmpty() }
                    ?: "audio-$id"
                val contentUri = Uri.withAppendedPath(collection, id.toString()).toString()
                val dateAddedMs = cursor.getLongOrNull(addedIndex)?.secondsToMillis()
                val dateModifiedMs = cursor.getLongOrNull(modifiedIndex)?.secondsToMillis() ?: 0L
                val year = cursor.getIntOrNull(yearIndex)?.takeIf { it > 0 }

                rows += linkedMapOf(
                    "id" to "media:$volume:$id",
                    "contentUri" to contentUri,
                    "fileName" to fileName,
                    "sizeBytes" to sizeBytes,
                    "title" to cursor.getStringOrNull(titleIndex).cleanMetadata(),
                    "artist" to cursor.getStringOrNull(artistIndex).cleanMetadata(),
                    "album" to cursor.getStringOrNull(albumIndex).cleanMetadata(),
                    "year" to year,
                    "durationMs" to cursor.getLongOrNull(durationIndex),
                    "dateAddedMs" to dateAddedMs,
                    "dateModifiedMs" to dateModifiedMs,
                )
            }
        }
    }

    private fun copyForReadOnWorker(uri: Uri): String {
        val directory = File(activity.cacheDir, READ_COPY_DIRECTORY_NAME)
        if (!directory.exists() && !directory.mkdirs()) {
            throw IOException("Unable to create the media read cache directory.")
        }
        if (!directory.isDirectory) {
            throw IOException("The media read cache path is not a directory.")
        }

        val temporary = try {
            File.createTempFile(READ_COPY_PREFIX, READ_COPY_SUFFIX, directory)
        } catch (error: IOException) {
            throw IOException("Unable to create a media read copy.", error)
        }

        try {
            val input = activity.contentResolver.openInputStream(uri)
                ?: throw IOException("The media provider returned no readable stream.")
            input.use { source ->
                temporary.outputStream().use { target ->
                    val buffer = ByteArray(COPY_BUFFER_BYTES)
                    var copied = 0L
                    while (true) {
                        val read = source.read(buffer)
                        if (read < 0) break
                        copied += read.toLong()
                        if (copied > MAX_READ_COPY_BYTES) {
                            throw BridgeException(
                                "read_too_large",
                                "The media file is larger than the supported read limit.",
                            )
                        }
                        target.write(buffer, 0, read)
                    }
                    target.flush()
                    if (copied == 0L) {
                        throw IOException("The media file is empty.")
                    }
                }
            }
            return temporary.canonicalPath
        } catch (error: BridgeException) {
            temporary.delete()
            throw error
        } catch (error: SecurityException) {
            temporary.delete()
            throw error
        } catch (error: Exception) {
            temporary.delete()
            throw IOException("Unable to copy the media file for reading.", error)
        }
    }

    private fun releaseReadCopyOnWorker(path: String) {
        val directory = File(activity.cacheDir, READ_COPY_DIRECTORY_NAME).canonicalFile
        val target = File(path).canonicalFile
        if (target.parentFile?.path != directory.path) {
            throw BridgeException(
                "invalid_argument",
                "Only a direct file in the device library read cache may be released.",
            )
        }
        if (!target.exists()) return
        if (!target.isFile) {
            throw BridgeException("invalid_argument", "The read copy path is not a file.")
        }
        if (!target.delete()) {
            throw IOException("Unable to release the media read copy.")
        }
    }

    private fun parseAllowedMediaUri(raw: String): Uri? {
        val uri = try {
            Uri.parse(raw)
        } catch (_: RuntimeException) {
            return null
        }
        if (
            uri.scheme != "content" ||
            uri.authority != "media" ||
            uri.query != null ||
            uri.fragment != null
        ) {
            return null
        }
        val path = uri.path ?: return null
        if (!MEDIA_URI_PATH.matches(path)) return null
        val id = path.substringAfterLast('/').toLongOrNull() ?: return null
        if (id <= 0L) return null
        return uri
    }

    private inner class OneShotResult(
        private val delegate: MethodChannel.Result,
    ) {
        private val replied = AtomicBoolean(false)

        fun success(value: Any?) {
            postIfActive { delegate.success(value) }
        }

        fun error(code: String, message: String?, details: Any?) {
            postIfActive { delegate.error(code, message, details) }
        }

        private fun postIfActive(action: () -> Unit) {
            if (!replied.compareAndSet(false, true) || disposed) return
            mainHandler.post {
                if (!disposed) action()
            }
        }
    }

    private class BridgeException(
        val code: String,
        override val message: String,
    ) : Exception(message)

    private companion object {
        private const val CHANNEL_NAME = "audio_fixer/device_library"
        private const val PREFERENCES_NAME = "audio_fixer_device_library"
        private const val KEY_PERMISSION_REQUESTED = "audio_permission_requested"
        private const val PERMISSION_REQUEST_CODE = 41937
        private const val EXPORT_REQUEST_CODE = 41938
        private const val EXTERNAL_VOLUME = "external"
        private const val PERMISSION_NOT_REQUESTED = "notRequested"
        private const val PERMISSION_DENIED = "denied"
        private const val PERMISSION_BLOCKED = "blocked"
        private const val PERMISSION_GRANTED = "granted"
        private const val READ_COPY_DIRECTORY_NAME = "device_library_read"
        private const val READ_COPY_PREFIX = "device_library_"
        private const val READ_COPY_SUFFIX = ".audio"
        private const val COPY_BUFFER_BYTES = 64 * 1024
        private const val MAX_READ_COPY_BYTES = 512L * 1024L * 1024L
        private val MEDIA_URI_PATH = Regex("^/[A-Za-z0-9._-]+/audio/media/[0-9]+$")
    }
}

private fun android.database.Cursor.getStringOrNull(index: Int): String? =
    if (index < 0 || isNull(index)) null else getString(index)

private fun android.database.Cursor.getLongOrNull(index: Int): Long? =
    if (index < 0 || isNull(index)) null else getLong(index)

private fun android.database.Cursor.getIntOrNull(index: Int): Int? =
    if (index < 0 || isNull(index)) null else getInt(index)

private fun String?.cleanMetadata(): String? {
    val normalized = this?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    return if (normalized.lowercase() in UNKNOWN_METADATA_VALUES) null else normalized
}

private fun Long.secondsToMillis(): Long = when {
    this > Long.MAX_VALUE / 1000L -> Long.MAX_VALUE
    this < Long.MIN_VALUE / 1000L -> Long.MIN_VALUE
    else -> this * 1000L
}

private val UNKNOWN_METADATA_VALUES = setOf(
    "unknown",
    "<unknown>",
    "unknown artist",
    "unknown album",
    "未知",
    "未知艺术家",
    "未知专辑",
)
