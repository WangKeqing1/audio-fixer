package com.audiofixer.audio_fixer

import android.Manifest
import android.app.Activity
import android.app.RecoverableSecurityException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.atomic.AtomicBoolean

/** Consent/lifecycle adapter. All byte writes and recovery run on the shared I/O queue. */
internal class AudioWriteBridge(
    private val activity: Activity,
    private val executor: ExecutorService,
    private val exportJournal: ExportRecoveryJournal,
) {
    private val handler = Handler(Looper.getMainLooper())
    private val originalJournal = OriginalSaveJournal(activity)
    @Volatile var active = false
        private set
    @Volatile private var disposed = false
    private var pendingOriginal: PendingOriginal? = null
    private var pendingDirectory: Reply? = null
    private var pendingBatchConsent: PendingBatchConsent? = null
    private data class PendingBatchConsent(val chunks: List<List<Uri>>, val reply: Reply, var index: Int = 0)
    private data class PendingOriginal(val target: Uri, val tagged: File?, val sourceHash: String?,
                                       val reply: Reply, var consentRequested: Boolean = false,
                                       val recoverOnly: Boolean = false)

    fun dispose() { disposed = true }
    fun notices(): String? = listOfNotNull(originalJournal.notice(), exportJournal.notice())
        .takeIf { it.isNotEmpty() }?.joinToString("\n\n")
    fun recover(): String? = exportJournal.exclusively {
        originalJournal.recover()
        exportJournal.recover()
        notices()
    }
    fun acknowledgeRecovery() = exportJournal.exclusively {
        originalJournal.acknowledgeNotice()
        exportJournal.setNotice(null)
    }
    fun confirmRecorded(uri: String) = exportJournal.exclusively {
        originalJournal.acknowledgeVerified(uri)
        exportJournal.acknowledgeVerified(uri)
    }

    fun handles(method: String) = method in setOf("saveAudioOriginal", "authorizeOriginalWrites", "retryOriginalRecovery", "chooseExportDirectory", "exportAudioToDirectory")
    fun onMethodCall(call: MethodCall, result: MethodChannel.Result, otherWriteActive: Boolean) {
        val reply = Reply(result)
        if (active || otherWriteActive) {
            reply.error("save_in_progress", "已有音频保存或授权操作进行中，请等待完成。")
            return
        }
        when (call.method) {
            "saveAudioOriginal" -> saveOriginal(call, reply)
            "authorizeOriginalWrites" -> authorizeOriginalWrites(call, reply)
            "retryOriginalRecovery" -> retryOriginalRecovery(reply)
            "chooseExportDirectory" -> chooseDirectory(reply)
            "exportAudioToDirectory" -> exportToDirectory(call, reply)
        }
    }

    private fun taggedFile(call: MethodCall): File {
        val file = call.argument<String>("path")?.let { File(it).canonicalFile }
            ?: throw IOException("缺少校验过的音频副本。")
        val root = File(activity.cacheDir, "tagged_exports").canonicalFile
        if (file.parentFile?.parentFile != root || !file.parentFile!!.name.startsWith("export_") ||
            file.name !in setOf("tagged.mp3", "tagged.flac", "tagged.m4a", "tagged.mp4") ||
            !file.isFile || file.length() == 0L) throw IOException("只允许写入经过校验的临时音频副本。")
        return file
    }

    private fun saveOriginal(call: MethodCall, reply: Reply) {
        try {
            val tagged = taggedFile(call)
            val target = originalJournal.validateTarget(call.argument("sourceUri"), call.argument("sourcePath"))
            val hash = call.argument<String>("sourceSha256")
            if (hash == null || !Regex("^[a-f0-9]{64}$").matches(hash)) throw IOException("缺少原音频校验信息。")
            active = true
            val pending = PendingOriginal(target, tagged, hash, reply)
            pendingOriginal = pending
            requestConsent(pending)
        } catch (error: Exception) {
            active = false
            pendingOriginal = null
            reply.error("original_save_failed", error.message ?: "无法请求原音频写入权限。")
        }
    }

    private fun authorizeOriginalWrites(call: MethodCall, reply: Reply) {
        try {
            val raw = call.argument<List<*>>("uris") ?: throw IOException("缺少待授权的原音频列表。")
            val uris = raw.map { value ->
                originalJournal.validateTarget(value as? String ?: throw IOException("原音频位置无效。"), null)
            }.distinct()
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R || uris.isEmpty()) {
                // Android 10's recoverable consent is per item. Older releases
                // use the existing legacy runtime-write permission path.
                reply.success(true)
                return
            }
            active = true
            schedule(reply) {
                try {
                    val needsConsent = exportJournal.exclusively {
                        uris.filter { uri ->
                            if (activity.checkUriPermission(uri, android.os.Process.myPid(), android.os.Process.myUid(),
                                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION) == PackageManager.PERMISSION_GRANTED) {
                                return@filter false
                            }
                            try {
                                activity.contentResolver.openFileDescriptor(uri, "rw")?.close()
                                false
                            } catch (_: SecurityException) {
                                true
                            } catch (_: IOException) {
                                // Missing/unmounted items remain per-item failures;
                                // do not block healthy items in the same batch.
                                false
                            }
                        }
                    }
                    handler.post {
                        if (!disposed) {
                            if (needsConsent.isEmpty()) {
                                active = false
                                reply.success(true)
                            } else {
                                // Android's documented cap is 2000 for recent
                                // targets; use smaller bounded groups on all APIs.
                                pendingBatchConsent = PendingBatchConsent(needsConsent.chunked(1000), reply)
                                launchNextBatchConsent()
                            }
                        }
                    }
                } catch (error: Exception) {
                    active = false
                    reply.error("original_authorization_failed", error.message ?: "无法准备批量原文件授权。")
                }
            }
        } catch (error: Exception) {
            active = false
            reply.error("original_authorization_failed", error.message ?: "批量原文件授权无效。")
        }
    }

    private fun launchNextBatchConsent() {
        val pending = pendingBatchConsent ?: return
        if (pending.index >= pending.chunks.size) {
            pendingBatchConsent = null
            active = false
            pending.reply.success(true)
            return
        }
        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) throw IOException("系统不支持批量写入授权。")
            val request = MediaStore.createWriteRequest(activity.contentResolver, pending.chunks[pending.index])
            activity.startIntentSenderForResult(request.intentSender, BATCH_CONSENT_CODE, null, 0, 0, 0)
        } catch (error: Exception) {
            pendingBatchConsent = null
            active = false
            pending.reply.error("original_authorization_failed", error.message ?: "无法打开批量原文件授权。")
        }
    }

    private fun retryOriginalRecovery(reply: Reply) {
        try {
            val target = originalJournal.recoveryTarget()
            active = true
            if (target == null) {
                schedule(reply) {
                    try { reply.success(recover()) } catch (error: Exception) {
                        reply.error("original_recovery_required", error.message ?: "原音频恢复未完成。")
                    } finally { active = false }
                }
                return
            }
            // Uses the retained record directly; a truncated file need not be
            // parsed or have candidates before the user can authorize restore.
            val pending = PendingOriginal(target, null, null, reply, recoverOnly = true)
            pendingOriginal = pending
            requestConsent(pending)
        } catch (error: Exception) {
            active = false
            pendingOriginal = null
            reply.error("original_recovery_required", error.message ?: "无法请求原音频恢复权限。")
        }
    }

    private fun requestConsent(pending: PendingOriginal) {
        if (pending.target.scheme == "file") {
            runOriginal(pending)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && pending.recoverOnly) {
            // Explicit recovery must also work after process-scoped grants expire.
            launchOriginalConsent(pending)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && Build.VERSION.SDK_INT <= Build.VERSION_CODES.P &&
            activity.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            pending.consentRequested = true
            activity.requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), LEGACY_WRITE_CODE)
        } else {
            runOriginal(pending)
        }
    }

    private fun launchOriginalConsent(pending: PendingOriginal) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) throw IOException("系统不支持此写入授权方式。")
        pending.consentRequested = true
        val request = MediaStore.createWriteRequest(activity.contentResolver, listOf(pending.target))
        activity.startIntentSenderForResult(request.intentSender, ORIGINAL_CONSENT_CODE, null, 0, 0, 0)
    }

    private fun runOriginal(pending: PendingOriginal) {
        schedule(pending.reply) {
            try {
                val saved = exportJournal.exclusively {
                    if (!pending.recoverOnly) originalJournal.ensureReady()
                    // Probe write access without truncation before making any backup/write.
                    // Android 10 reports its per-item consent requirement here.
                    if (pending.target.scheme == "content") {
                        val descriptor = activity.contentResolver.openFileDescriptor(pending.target, "rw")
                            ?: throw IOException("无法打开原音频。")
                        descriptor.close()
                    }
                    if (pending.recoverOnly) {
                        originalJournal.ensureReady()
                        notices()
                    } else {
                        originalJournal.save(pending.target, pending.tagged!!, pending.sourceHash!!)
                    }
                }
                pendingOriginal = null
                active = false
                pending.reply.success(saved)
            } catch (error: Exception) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && error is SecurityException && !pending.consentRequested) {
                    handler.post {
                        if (!disposed) try {
                            launchOriginalConsent(pending)
                        } catch (failure: Exception) {
                            active = false
                            pendingOriginal = null
                            pending.reply.error("original_permission_failed", failure.message ?: "无法打开系统授权。")
                        }
                    }
                } else if (Build.VERSION.SDK_INT == Build.VERSION_CODES.Q && error is RecoverableSecurityException && !pending.consentRequested) {
                    pending.consentRequested = true
                    handler.post {
                        if (!disposed) try {
                            activity.startIntentSenderForResult(error.userAction.actionIntent.intentSender,
                                ORIGINAL_CONSENT_CODE, null, 0, 0, 0)
                        } catch (failure: Exception) {
                            active = false
                            pendingOriginal = null
                            pending.reply.error("original_permission_failed", failure.message ?: "无法打开系统授权。")
                        }
                    }
                } else {
                    pendingOriginal = null
                    active = false
                    pending.reply.error(
                        if (error is OriginalRecoveryRequiredException) "original_recovery_required" else "original_save_failed",
                        error.message ?: "原音频保存失败。",
                    )
                }
            }
        }
    }

    fun onRequestPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != LEGACY_WRITE_CODE) return false
        val pending = pendingOriginal ?: return true
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            activity.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED) {
            runOriginal(pending)
        } else {
            pendingOriginal = null
            active = false
            pending.reply.success(if (pending.recoverOnly) notices() else null)
        }
        return true
    }

    private fun chooseDirectory(reply: Reply) {
        active = true
        pendingDirectory = reply
        try {
            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            }, DIRECTORY_CODE)
        } catch (error: Exception) {
            pendingDirectory = null
            active = false
            reply.error("directory_failed", error.message ?: "无法打开文件夹选择器。")
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        when (requestCode) {
            BATCH_CONSENT_CODE -> {
                // An orphan authorization result grants access only; it never
                // starts writes without its original Dart batch caller.
                val pending = pendingBatchConsent ?: return true
                if (resultCode == Activity.RESULT_OK) {
                    pending.index++
                    launchNextBatchConsent()
                } else {
                    pendingBatchConsent = null
                    active = false
                    pending.reply.success(false)
                }
                return true
            }
            ORIGINAL_CONSENT_CODE -> {
                val pending = pendingOriginal ?: return true // Orphan consent never writes a file.
                if (resultCode == Activity.RESULT_OK) runOriginal(pending) else {
                    pendingOriginal = null
                    active = false
                    pending.reply.success(if (pending.recoverOnly) notices() else null)
                }
                return true
            }
            DIRECTORY_CODE -> {
                val reply = pendingDirectory
                pendingDirectory = null
                active = false
                val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
                if (uri != null && (uri.scheme != "content" || !DocumentsContract.isTreeUri(uri))) {
                    reply?.error("directory_failed", "所选位置不是可用的文件夹。")
                } else reply?.success(uri?.toString())
                return true
            }
        }
        return false
    }

    private fun exportToDirectory(call: MethodCall, reply: Reply) {
        try {
            val tagged = taggedFile(call)
            val tree = Uri.parse(call.argument<String>("directoryUri") ?: throw IOException("请先选择导出文件夹。"))
            if (tree.scheme != "content" || !DocumentsContract.isTreeUri(tree)) throw IOException("导出文件夹无效。")
            val name = call.argument<String>("fileName")?.let { File(it).name }
                ?.takeIf { it.isNotBlank() } ?: throw IOException("导出文件名无效。")
            val mime = call.argument<String>("mimeType")
            if (mime !in setOf("audio/mpeg", "audio/flac", "audio/mp4")) throw IOException("导出音频格式无效。")
            active = true
            schedule(reply) {
                try {
                    val saved = exportJournal.exclusively {
                        exportJournal.recover()
                        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                        // Provider creation + journal commit cannot be atomic. A restart
                        // in that gap leaves a specific warning about this folder.
                        exportJournal.record(ExportRecoveryJournal.CREATING, tagged, tree)
                        var target: Uri? = null
                        try {
                            target = DocumentsContract.createDocument(activity.contentResolver, parent, mime!!, name)
                                ?: throw IOException("无法在所选文件夹中建立音频副本。")
                            exportJournal.record(ExportRecoveryJournal.WRITING, tagged, target)
                            val expected = OriginalSaveJournal.hash(tagged)
                            val output = activity.contentResolver.openOutputStream(target, "wt")
                                ?: throw IOException("无法写入音频副本。")
                            output.use { sink ->
                                tagged.inputStream().use { OriginalSaveJournal.copyBounded(it, sink) }
                                sink.flush()
                            }
                            val input = activity.contentResolver.openInputStream(target)
                                ?: throw IOException("无法校验音频副本。")
                            val actual = input.use { source ->
                                val digest = java.security.MessageDigest.getInstance("SHA-256")
                                val buffer = ByteArray(64 * 1024)
                                while (true) {
                                    val count = source.read(buffer)
                                    if (count < 0) break
                                    digest.update(buffer, 0, count)
                                }
                                digest.digest().joinToString("") { "%02x".format(it) }
                            }
                            if (actual != expected) throw IOException("音频副本保存后校验失败。")
                            exportJournal.record(ExportRecoveryJournal.VERIFIED, tagged, target)
                            target.toString()
                        } catch (error: Exception) {
                            if (target == null || exportJournal.deleteNewDocument(target)) {
                                exportJournal.clear()
                                throw IOException("导出失败，原文件未修改。", error)
                            }
                            val message = "导出失败，未完成的新副本无法自动删除，请手动检查：$target。原文件未修改。"
                            exportJournal.setNotice(message)
                            throw IOException(message, error)
                        }
                    }
                    active = false
                    reply.success(saved)
                } catch (error: Exception) {
                    active = false
                    reply.error("export_failed", error.message ?: "音频副本导出失败。")
                }
            }
        } catch (error: Exception) {
            active = false
            reply.error("export_failed", error.message ?: "无法准备音频副本。")
        }
    }

    private fun schedule(reply: Reply, action: () -> Unit) {
        try { executor.execute(action) } catch (error: RuntimeException) {
            active = false
            pendingOriginal = null
            reply.error("save_failed", error.message ?: "无法开始保存音频。")
        }
    }

    private inner class Reply(private val result: MethodChannel.Result) {
        private val completed = AtomicBoolean(false)
        fun success(value: Any?) = once { result.success(value) }
        fun error(code: String, message: String) = once { result.error(code, message, null) }
        private fun once(action: () -> Unit) {
            if (completed.compareAndSet(false, true)) handler.post { if (!disposed) action() }
        }
    }

    companion object {
        private const val ORIGINAL_CONSENT_CODE = 41939
        private const val LEGACY_WRITE_CODE = 41940
        private const val DIRECTORY_CODE = 41941
        private const val BATCH_CONSENT_CODE = 41942
    }
}
