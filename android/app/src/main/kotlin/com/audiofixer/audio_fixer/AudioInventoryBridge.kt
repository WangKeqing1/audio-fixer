package com.audiofixer.audio_fixer

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.OperationCanceledException
import android.os.SystemClock
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.io.Writer
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** A read-only, unfiltered inventory. This never changes the normal library query. */
class AudioInventoryBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "audio-inventory-io").apply { isDaemon = true }
    }
    private val canceller = Executors.newSingleThreadExecutor { task ->
        Thread(task, "audio-inventory-cancel").apply { isDaemon = true }
    }
    private val methods = MethodChannel(messenger, "audio_fixer/audio_inventory")
    private val events = EventChannel(messenger, "audio_fixer/audio_inventory_progress")
    private val progressQueued = AtomicBoolean(false)
    @Volatile private var latestProgress: Map<String, Any?>? = null
    @Volatile private var disposed = false
    private var resumed = false
    private var eventSink: EventChannel.EventSink? = null
    private var active: Operation? = null // Main thread only.
    private var ready: ReadyInventory? = null // Main thread only.
    private var picker: Operation? = null // Retained until its activity result arrives.
    private val requestCode = 42010 + (nextRequestCode.getAndIncrement() and Int.MAX_VALUE) % 22000

    init {
        methods.setMethodCallHandler(::onMethodCall)
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                eventSink = sink
                latestProgress?.let(sink::success)
            }
            override fun onCancel(arguments: Any?) { eventSink = null }
        })
    }

    fun onResume() { resumed = true }

    fun onPause() {
        resumed = false
        active?.takeIf { it.phase == "querying" || it.phase == "scanning" }?.let(::requestCancel)
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        active?.let { operation ->
            requestCancel(operation)
            if (picker === operation) {
                // Generation already closed its private TXT before opening SAF.
                runCatching { activity.finishActivity(requestCode) }
                picker = null
                finish(operation, "cancelled", "页面已关闭，已取消保存。")
            }
        }
        if (active == null) {
            ready?.file?.delete()
            ready = null
        }
        eventSink = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        // Drain queued jobs so every pending MethodChannel result settles after
        // its worker has closed descriptors/retrievers, never before native I/O.
        worker.shutdown()
        canceller.shutdown()
    }

    private fun onMethodCall(call: MethodCall, reply: MethodChannel.Result) {
        val id = call.argument<Number>("operationId")?.toLong()
        if (disposed || id == null || id < 0) {
            reply.error("invalid_operation", "A non-negative operationId is required.", null)
            return
        }
        when (call.method) {
            "exportInventory" -> start(id, reply, retry = false)
            "retrySave" -> start(id, reply, retry = true)
            "cancelExport" -> {
                val operation = active
                if (operation?.id == id) {
                    requestCancel(operation)
                    if (picker === operation) {
                        // Cancel only the activity this bridge launched. Do not delete its document.
                        runCatching { activity.finishActivity(requestCode) }
                    }
                    reply.success(true)
                } else if (operation == null && ready?.ownerId == id) {
                    val file = ready?.file
                    ready = null
                    val cancellationReply = OneShot(reply)
                    worker.execute {
                        val removed = file == null || !file.exists() || file.delete()
                        cancellationReply.send(removed)
                    }
                } else {
                    reply.success(false)
                }
            }
            else -> reply.notImplemented()
        }
    }

    private fun start(id: Long, reply: MethodChannel.Result, retry: Boolean) {
        val operation = Operation(id, OneShot(reply))
        if (active != null || picker != null) {
            operation.reply.send(result(operation, "busy", "另一个音频清单任务尚未结束。"))
            return
        }
        if (!retry && !hasPermission()) {
            operation.reply.send(result(operation, "permissionDenied", "请先允许读取设备音频。"))
            return
        }
        if (retry) {
            val complete = ready
            if (complete == null || !complete.file.isFile) {
                operation.reply.send(result(operation, "failed", "没有可重新保存的完整清单，请重新生成。"))
                return
            }
            ready = complete.copy(ownerId = id)
            operation.counts.copyFrom(complete.counts)
            operation.fileName = complete.fileName
            active = operation
            chooseDestination(operation)
            return
        }
        val previous = ready?.file
        ready = null
        active = operation
        emit(operation, "querying", force = true)
        worker.execute {
            previous?.delete()
            var complete: ReadyInventory? = null
            var status = "failed"
            var message = "无法生成音频清单，未保存清单。"
            try {
                complete = generate(operation)
            } catch (_: OperationCanceledException) {
                status = "cancelled"
                message = "已取消生成，未保存清单。"
            } catch (_: SecurityException) {
                status = "permissionDenied"
                message = "音频读取权限已不可用，请重新检查权限。"
            } catch (error: Exception) {
                message = "无法生成音频清单（${error.javaClass.simpleName}），未保存清单。"
            } finally {
                operation.signal = null
                operation.io = null
            }
            // All generation resources have left their use/finally blocks.
            val generated = complete
            main.post {
                if (active !== operation) {
                    generated?.file?.delete()
                } else if (generated != null) {
                    ready = generated
                    if (disposed || operation.cancelled.get() || !resumed) {
                        finish(operation, "cancelled", if (disposed) {
                            "页面已关闭，清单任务已取消。"
                        } else { "生成已结束；已取消打开保存位置，可重新保存完整清单。" })
                    } else {
                        chooseDestination(operation)
                    }
                } else {
                    finish(operation, status, message)
                }
            }
        }
    }

    private fun generate(operation: Operation): ReadyInventory {
        val directory = File(activity.cacheDir, "audio_inventory")
        if (!directory.isDirectory && !directory.mkdirs()) throw IOException("Cannot create inventory cache")
        val file = File.createTempFile("inventory_", ".txt", directory)
        val createdAt = utcFormat("yyyy-MM-dd'T'HH:mm:ss'Z'").format(Date())
        operation.fileName = "audio_inventory_${utcFormat("yyyyMMdd_HHmmss").format(Date())}.txt"
        var completed = false
        try {
            file.bufferedWriter(Charsets.UTF_8, BUFFER_SIZE).use { output ->
                AudioInventoryText.writeHeader(output, createdAt)
                val volumes = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    (MediaStore.getExternalVolumeNames(activity) + MediaStore.VOLUME_INTERNAL).sorted()
                } else {
                    listOf("external", "internal")
                }
                var queriedVolumes = 0
                for (volume in volumes) {
                    operation.checkCancelled()
                    if (!hasPermission()) throw SecurityException("Audio permission revoked")
                    val collection = MediaStore.Audio.Media.getContentUri(volume)
                    val signal = CancellationSignal()
                    operation.registerSignal(signal)
                    try {
                        val folderColumn = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            MediaStore.MediaColumns.RELATIVE_PATH
                        } else {
                            @Suppress("DEPRECATION")
                            MediaStore.MediaColumns.DATA
                        }
                        // Deliberately no IS_MUSIC, size, duration, folder or app-library filter.
                        val cursor = activity.contentResolver.query(
                            collection,
                            arrayOf(
                                MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME,
                                folderColumn, MediaStore.MediaColumns.SIZE,
                                MediaStore.Audio.AudioColumns.DURATION,
                                MediaStore.Audio.AudioColumns.TITLE, MediaStore.Audio.AudioColumns.ARTIST,
                                MediaStore.Audio.AudioColumns.ALBUM, MediaStore.Audio.AudioColumns.IS_MUSIC,
                            ),
                            null, null, "${MediaStore.MediaColumns._ID} ASC", signal,
                        ) ?: throw IOException("Media provider returned no cursor")
                        cursor.use {
                            queriedVolumes++
                            operation.counts.totalIndexed += cursor.count
                            while (true) {
                                operation.checkCancelled()
                                if (!cursor.moveToNext()) break
                                writeRecord(output, operation, cursor, collection, volume, folderColumn)
                                emit(operation, "scanning")
                            }
                        }
                    } catch (error: Exception) {
                        operation.checkCancelled()
                        if (error is SecurityException && !hasPermission()) throw error
                        operation.counts.volumeErrors++
                        AudioInventoryText.writeVolumeError(output, volume, error.javaClass.simpleName)
                    } finally {
                        operation.signal = null
                    }
                }
                operation.checkCancelled()
                if (queriedVolumes == 0) throw IOException("No media volume could be queried")
                operation.counts.complete = true
                AudioInventoryText.writeSummary(
                    output,
                    operation.counts.totalIndexed,
                    operation.counts.scanned,
                    operation.counts.metadataSuccess,
                    operation.counts.unreadable,
                    operation.counts.volumeErrors,
                )
                output.flush()
            }
            operation.checkCancelled()
            completed = true
            return ReadyInventory(file, operation.fileName, operation.id, operation.counts.snapshot())
        } finally {
            if (!completed) file.delete()
        }
    }

    private fun writeRecord(
        output: Writer,
        operation: Operation,
        cursor: Cursor,
        collection: Uri,
        volume: String,
        folderColumn: String,
    ) {
        output.append("\n[record ${operation.counts.scanned + 1}]\n")
        AudioInventoryText.writeField(output, "volume", volume)
        var retriever: MediaMetadataRetriever? = null
        var readOpened = false
        var failed = false
        val errors = ArrayList<String>()
        val writtenTags = HashSet<String>()
        try {
            AudioInventoryText.writeField(output, "file_name_raw", cursor.string(MediaStore.MediaColumns.DISPLAY_NAME))
            val folder = cursor.string(folderColumn)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                AudioInventoryText.writeField(output, "relative_path", folder)
            } else {
                AudioInventoryText.writeField(output, "relative_path", null)
                AudioInventoryText.writeField(output, "legacy_parent_path", folder?.let { File(it).parent })
            }
            AudioInventoryText.writeField(output, "size_bytes_index", cursor.string(MediaStore.MediaColumns.SIZE))
            AudioInventoryText.writeField(output, "duration_ms_index", cursor.string(MediaStore.Audio.AudioColumns.DURATION))
            AudioInventoryText.writeField(output, "is_music_index", cursor.string(MediaStore.Audio.AudioColumns.IS_MUSIC))
            AudioInventoryText.writeField(output, "index_title", cursor.string(MediaStore.Audio.AudioColumns.TITLE))
            AudioInventoryText.writeField(output, "index_artist", cursor.string(MediaStore.Audio.AudioColumns.ARTIST))
            AudioInventoryText.writeField(output, "index_album", cursor.string(MediaStore.Audio.AudioColumns.ALBUM))
            operation.checkCancelled()
            val id = cursor.string(MediaStore.MediaColumns._ID)?.toLongOrNull()
                ?: throw IOException("Missing media id")
            val descriptor = activity.contentResolver.openAssetFileDescriptor(
                ContentUris.withAppendedId(collection, id), "r", operation.signal,
            ) ?: throw IOException("No readable media descriptor")
            operation.registerIo(descriptor)
            descriptor.use {
                operation.checkCancelled()
                readOpened = true
                retriever = MediaMetadataRetriever()
                val metadata = retriever
                if (descriptor.declaredLength < 0) {
                    metadata.setDataSource(descriptor.fileDescriptor)
                } else {
                    metadata.setDataSource(descriptor.fileDescriptor, descriptor.startOffset, descriptor.declaredLength)
                }
                for ((name, key) in TAG_KEYS) {
                    operation.checkCancelled()
                    val value = try {
                        metadata.extractMetadata(key)
                    } catch (error: RuntimeException) {
                        failed = true
                        errors += "$name:${error.javaClass.simpleName}"
                        null
                    }
                    AudioInventoryText.writeField(output, name, value)
                    writtenTags += name
                }
            }
        } catch (error: Exception) {
            operation.checkCancelled()
            failed = true
            errors += error.javaClass.simpleName
        } finally {
            operation.io = null
            try { retriever?.release() } catch (_: Exception) { /* Release is best-effort. */ }
        }
        operation.checkCancelled()
        for ((name, _) in TAG_KEYS) {
            if (name !in writtenTags) AudioInventoryText.writeField(output, name, null)
        }
        AudioInventoryText.writeField(output, "file_read_status", if (readOpened) "opened" else "unreadable")
        AudioInventoryText.writeField(output, "metadata_status", if (failed) "read_error" else "read_ok")
        AudioInventoryText.writeField(output, "read_error", errors.joinToString(", ").takeIf { it.isNotEmpty() })
        AudioInventoryText.writeField(output, "tag_comment", null)
        AudioInventoryText.writeField(output, "comment_status", "unsupported_by_android_retriever")
        AudioInventoryText.writeField(output, "cover_status", "unchecked_no_image_bytes_read")
        if (failed) operation.counts.unreadable++ else operation.counts.metadataSuccess++
        operation.counts.scanned++
    }

    private fun chooseDestination(operation: Operation) {
        if (disposed || active !== operation) return
        if (operation.cancelled.get() || !resumed) {
            finish(operation, "cancelled", "已取消保存，完整清单仍可重新保存。")
            return
        }
        emit(operation, "choosingDestination", force = true)
        picker = operation
        try {
            activity.startActivityForResult(
                Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TITLE, operation.fileName)
                },
                requestCode,
            )
        } catch (error: RuntimeException) {
            picker = null
            finish(operation, "failed", "无法打开系统保存位置（${error.javaClass.simpleName}），可重新保存。")
        }
    }

    fun onActivityResult(code: Int, resultCode: Int, data: Intent?) {
        if (code != requestCode) return
        val operation = picker ?: return
        picker = null
        if (disposed || active !== operation) return
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            finish(operation, "cancelled", "已取消保存，完整清单仍可重新保存。")
            return
        }
        operation.destinationChosen = true
        if (operation.cancelled.get()) {
            finish(operation, "cancelled", "已取消保存，所选位置可能留下空的新 TXT；完整清单可重新保存。", partial = true)
            return
        }
        val complete = ready
        if (complete == null || !complete.file.isFile || uri.scheme != "content") {
            finish(operation, "failed", "完整清单或保存位置不可用，所选位置可能留下空的新 TXT；请重新生成。", partial = true)
            return
        }
        // ACTION_CREATE_DOCUMENT chooses a new document. Never delete a URI on failure.
        emit(operation, "saving", force = true)
        worker.execute {
            var status = "saved"
            var partial = false
            var message = if (operation.counts.volumeErrors > 0) {
                "已保存清单；部分存储卷读取失败，请查看 TXT 中的覆盖范围说明。"
            } else { "音频清单已保存。" }
            try {
                operation.checkCancelled()
                val signal = CancellationSignal()
                operation.registerSignal(signal)
                val descriptor = activity.contentResolver.openFileDescriptor(uri, "w", signal)
                    ?: throw IOException("No writable document descriptor")
                operation.registerIo(descriptor)
                android.os.ParcelFileDescriptor.AutoCloseOutputStream(descriptor).use { destination ->
                    complete.file.inputStream().use { source ->
                        val buffer = ByteArray(BUFFER_SIZE)
                        while (true) {
                            operation.checkCancelled()
                            val length = source.read(buffer)
                            if (length < 0) break
                            destination.write(buffer, 0, length)
                        }
                    }
                    destination.flush()
                }
                operation.checkCancelled()
            } catch (error: Exception) {
                partial = true
                if (operation.cancelled.get() || error is OperationCanceledException) {
                    status = "cancelled"
                    message = "保存已取消，所选位置可能留下不完整的新 TXT；完整清单可重新保存。"
                } else {
                    status = "failed"
                    message = "保存失败（${error.javaClass.simpleName}），所选位置可能留下不完整的新 TXT；完整清单可重新保存。"
                }
            } finally {
                operation.signal = null
                operation.io = null
            }
            // Settle only after both streams and the native descriptor close.
            main.post { finish(operation, status, message, partial) }
        }
    }

    private fun requestCancel(operation: Operation) {
        operation.cancelled.set(true)
        val signal = operation.signal
        val io = operation.io
        if (!canceller.isShutdown) canceller.execute {
            runCatching { signal?.cancel() }
            runCatching { io?.close() }
        }
    }

    private fun finish(operation: Operation, status: String, message: String, partial: Boolean = false) {
        if (active !== operation) return
        active = null
        val saved = status == "saved"
        val response = result(operation, status, message, partial)
        if (saved || disposed) {
            ready?.file?.delete()
            ready = null
        }
        emit(operation, if (saved) "complete" else if (status == "cancelled") "cancelled" else "failed", force = true)
        operation.reply.send(response)
    }

    private fun result(operation: Operation, status: String, message: String, partial: Boolean = false): Map<String, Any?> =
        linkedMapOf(
            "operationId" to operation.id,
            "status" to status,
            "fileName" to operation.fileName,
            "totalIndexed" to operation.counts.totalIndexed,
            "scanned" to operation.counts.scanned,
            "metadataSuccess" to operation.counts.metadataSuccess,
            "unreadable" to operation.counts.unreadable,
            "cancelled" to if (operation.counts.complete) 0 else (operation.counts.totalIndexed - operation.counts.scanned).coerceAtLeast(0),
            "volumeErrors" to operation.counts.volumeErrors,
            "coveragePartial" to (operation.counts.volumeErrors > 0 || !operation.counts.complete),
            "canRetrySave" to (!disposed && status != "saved" && ready?.ownerId == operation.id && ready?.file?.isFile == true),
            "possiblePartialDocument" to (partial || (disposed && operation.destinationChosen)),
            "message" to message,
        )

    private fun emit(operation: Operation, phase: String, force: Boolean = false) {
        operation.phase = phase
        val now = SystemClock.elapsedRealtime()
        if (!force && now - operation.lastProgressMs < 250) return
        operation.lastProgressMs = now
        latestProgress = linkedMapOf(
            "operationId" to operation.id,
            "phase" to phase,
            "scanned" to operation.counts.scanned,
            "total" to if (operation.counts.complete) operation.counts.totalIndexed else -1,
            "readFailures" to operation.counts.unreadable,
        )
        // Coalesce to one outstanding main-thread callback even if the UI is busy.
        if (progressQueued.compareAndSet(false, true)) main.post {
            progressQueued.set(false)
            if (!disposed) latestProgress?.let { eventSink?.success(it) }
        }
    }

    private fun hasPermission(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
        activity.checkSelfPermission(if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else { Manifest.permission.READ_EXTERNAL_STORAGE }) == PackageManager.PERMISSION_GRANTED

    private class Operation(val id: Long, val reply: OneShot) {
        val cancelled = AtomicBoolean(false)
        val counts = Counts()
        @Volatile var phase = "querying"
        @Volatile var signal: CancellationSignal? = null
        @Volatile var io: Closeable? = null
        @Volatile var fileName = "audio_inventory.txt"
        @Volatile var destinationChosen = false
        var lastProgressMs = 0L
        fun checkCancelled() {
            if (cancelled.get() || Thread.currentThread().isInterrupted) throw OperationCanceledException()
        }
        fun registerSignal(value: CancellationSignal) {
            signal = value
            if (cancelled.get()) {
                value.cancel()
                throw OperationCanceledException()
            }
        }
        fun registerIo(value: Closeable) {
            io = value
            if (cancelled.get()) {
                runCatching { value.close() }
                throw OperationCanceledException()
            }
        }
    }

    private class Counts {
        @Volatile var totalIndexed = 0
        @Volatile var scanned = 0
        @Volatile var metadataSuccess = 0
        @Volatile var unreadable = 0
        @Volatile var volumeErrors = 0
        @Volatile var complete = false
        fun snapshot() = Counts().also { it.copyFrom(this) }
        fun copyFrom(other: Counts) {
            totalIndexed = other.totalIndexed; scanned = other.scanned
            metadataSuccess = other.metadataSuccess; unreadable = other.unreadable
            volumeErrors = other.volumeErrors; complete = other.complete
        }
    }

    private data class ReadyInventory(val file: File, val fileName: String, val ownerId: Long, val counts: Counts)

    private class OneShot(private val reply: MethodChannel.Result) {
        private val sent = AtomicBoolean(false)
        fun send(value: Any?) {
            if (sent.compareAndSet(false, true)) Handler(Looper.getMainLooper()).post { reply.success(value) }
        }
    }

    private companion object {
        const val BUFFER_SIZE = 32 * 1024
        val nextRequestCode = AtomicInteger(0)
        val TAG_KEYS = listOf(
            "tag_title" to MediaMetadataRetriever.METADATA_KEY_TITLE,
            "tag_artist" to MediaMetadataRetriever.METADATA_KEY_ARTIST,
            "tag_album" to MediaMetadataRetriever.METADATA_KEY_ALBUM,
            "tag_album_artist" to MediaMetadataRetriever.METADATA_KEY_ALBUMARTIST,
            "tag_year" to MediaMetadataRetriever.METADATA_KEY_YEAR,
            "tag_genre" to MediaMetadataRetriever.METADATA_KEY_GENRE,
            "tag_track_pair" to MediaMetadataRetriever.METADATA_KEY_CD_TRACK_NUMBER,
            "tag_disc_pair" to MediaMetadataRetriever.METADATA_KEY_DISC_NUMBER,
            "tag_composer" to MediaMetadataRetriever.METADATA_KEY_COMPOSER,
            "duration_ms_metadata" to MediaMetadataRetriever.METADATA_KEY_DURATION,
        )

        fun utcFormat(pattern: String) = SimpleDateFormat(pattern, Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }


    }
}

/** Pure streaming formatter, kept separate from Android calls for JVM regression tests. */
internal object AudioInventoryText {
    const val MAX_FIELD_CHARS = 32 * 1024

    fun writeHeader(output: Writer, createdAt: String) {
        output.append("Audio Fixer 音频清单 / Audio inventory v1\n")
        AudioInventoryText.writeField(output, "generated_at_utc", createdAt)
        output.append("编码：UTF-8。字符串使用双引号；换行、控制符及方向控制符转义；<unknown> 表示未知或读取器未提供。\n")
        output.append("覆盖范围：仅 Android MediaStore 当前可见且已获授权的音频索引，包含内部卷及所有已连接外部卷。逐条尝试读取；失败项保留。\n")
        output.append("忽略 Audio Fixer 的文件夹、时长及音乐筛选；包含 IS_MUSIC=0、短音频、零字节索引。系统隐藏的待处理/回收站条目以系统实际可见范围为准。\n")
        output.append("不包含未被系统索引、未连接存储或其他应用私有/无权访问的文件；此清单不保证覆盖设备上的每一个文件。\n")
        output.append("index_* 来自 MediaStore 索引，可能过时或由文件名推断；tag_* 是直接打开音频文件后 Android MediaMetadataRetriever 返回的字段，支持程度取决于格式和系统。\n")
        output.append("track/disc pair 保留读取器返回的原值；未返回的总数未知。comment 无可用读取接口，标记未知；封面只记未检查，不读取图片。\n")
        output.append("不复制音频、不导出歌词内容或图片、不包含 content URI、不联网或自动上传。字段中的原始空格和 Unicode 保留。\n")
        output.append("每个字段最多输出 ${AudioInventoryText.MAX_FIELD_CHARS} 个 UTF-16 字符，过长字段明确标记截断。元数据不存在与读取器不支持无法完全区分。\n")
        output.append("读取按存储卷名称、MediaStore ID 排序；扫描期间文件变化可能影响结果。Android 9 及更早版本只可提供父目录路径。\n")
    }

    fun writeSummary(
        output: Writer,
        totalIndexed: Int,
        recordsWritten: Int,
        metadataSuccess: Int,
        unreadable: Int,
        volumeErrors: Int,
    ) {
        output.append("\n[summary]\n")
        output.append("total_indexed=$totalIndexed\nrecords_written=$recordsWritten\n")
        output.append("metadata_success=$metadataSuccess\nunreadable_or_metadata_error=$unreadable\n")
        output.append("cancelled=0\nvolume_read_errors=$volumeErrors\n")
        output.append("coverage_complete_for_queried_volumes=${volumeErrors == 0}\n")
        if (volumeErrors > 0) output.append("注意：存在无法查询或未完整读取的卷；total_indexed 仅为已获得的索引数量。\n")
    }

    fun writeVolumeError(output: Writer, volume: String, error: String) {
        output.append("\n[volume_read_error]\n")
        writeField(output, "volume", volume)
        writeField(output, "error", error)
    }

    fun writeField(output: Writer, name: String, value: String?) {
        output.append(name).append('=')
        if (value == null) {
            output.append("<unknown>\n")
            return
        }
        output.append('"')
        val limit = minOf(value.length, MAX_FIELD_CHARS)
        for (index in 0 until limit) {
            val character = value[index]
            when (character) {
                '\\' -> output.append("\\\\")
                '"' -> output.append("\\\"")
                '\n' -> output.append("\\n")
                '\r' -> output.append("\\r")
                '\t' -> output.append("\\t")
                else -> {
                    val pairedHigh = Character.isHighSurrogate(character) && index + 1 < limit && Character.isLowSurrogate(value[index + 1])
                    val pairedLow = Character.isLowSurrogate(character) && index > 0 && Character.isHighSurrogate(value[index - 1])
                    if (Character.isISOControl(character) || Character.getType(character) == Character.FORMAT.toInt() ||
                        character == '\u2028' || character == '\u2029' ||
                        (Character.isSurrogate(character) && !pairedHigh && !pairedLow)) {
                        output.append("\\u").append(character.code.toString(16).padStart(4, '0'))
                    } else { output.append(character) }
                }
            }
        }
        output.append('"')
        if (value.length > limit) output.append(" [truncated; original_utf16_length=${value.length}]")
        output.append('\n')
    }
}

private fun Cursor.string(column: String): String? {
    val index = getColumnIndex(column)
    return if (index < 0 || isNull(index)) null else getString(index)
}
