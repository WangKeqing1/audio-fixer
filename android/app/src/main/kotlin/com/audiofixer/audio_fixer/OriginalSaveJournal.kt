package com.audiofixer.audio_fixer

import android.content.Context
import android.net.Uri
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID

internal class OriginalRecoveryRequiredException(message: String, cause: Throwable? = null) : IOException(message, cause)

/** Never pass these original-file records to ExportRecoveryJournal.deleteNewDocument. */
internal class OriginalSaveJournal(context: Context) {
    private val context = context.applicationContext
    private val preferences = this.context.getSharedPreferences("audio_fixer_original_recovery", Context.MODE_PRIVATE)
    private val root get() = File(context.noBackupFilesDir, "original_audio_backups")

    data class Entry(val stage: String, val target: String, val backup: String,
                     val originalHash: String, val outputHash: String)

    fun read(): Entry? {
        val stage = preferences.getString("stage", null) ?: return null
        return Entry(stage, required("target"), required("backup"), required("originalHash"), required("outputHash"))
    }

    private fun required(key: String) = preferences.getString(key, null)
        ?: throw IOException("原音频恢复记录不完整，请保留应用数据并检查备份。")

    fun notice(): String? = preferences.getString("notice", null)
    fun setNotice(message: String?) {
        if (!preferences.edit().putString("notice", message).commit()) throw IOException("无法保存原音频恢复提醒。")
    }

    fun acknowledgeNotice() {
        // An unresolved backup must remain visible and must never be discarded.
        if (read()?.stage == WRITING) throw OriginalRecoveryRequiredException(notice() ?: "原音频备份尚待恢复，请保留应用数据。")
        setNotice(null)
    }

    private fun record(entry: Entry) {
        if (!preferences.edit().putString("stage", entry.stage).putString("target", entry.target)
                .putString("backup", entry.backup).putString("originalHash", entry.originalHash)
                .putString("outputHash", entry.outputHash).commit()) throw IOException("无法保存原音频恢复记录。")
    }

    private fun clear(entry: Entry) {
        // Clear provenance before deleting bytes. A failed clear leaves a usable backup.
        if (!preferences.edit().remove("stage").remove("target").remove("backup")
                .remove("originalHash").remove("outputHash").commit()) throw IOException("无法清除原音频恢复记录。")
        backupFile(entry).delete()
    }

    fun acknowledgeVerified(target: String) {
        read()?.let { if (it.stage == VERIFIED && it.target == target) clear(it) }
    }

    /** Only already-owned, imported audio is writable by filesystem path. */
    fun validateTarget(sourceUri: String?, sourcePath: String?): Uri {
        if (sourceUri != null) {
            val uri = Uri.parse(sourceUri)
            if (uri.scheme != "content" || uri.authority != "media" || uri.query != null || uri.fragment != null ||
                !Regex("^/[A-Za-z0-9._-]+/audio/media/[0-9]+$").matches(uri.path ?: "") ||
                (uri.lastPathSegment?.toLongOrNull() ?: 0L) <= 0L) throw IOException("只允许保存系统音乐库中的原音频。")
            return uri
        }
        val audio = File(context.filesDir, "audio").canonicalFile
        val file = sourcePath?.let { File(it).canonicalFile } ?: throw IOException("缺少原音频位置。")
        if (file.parentFile != audio || !Regex("^[a-f0-9]{64}\\.audio$").matches(file.name) || !file.isFile) {
            throw IOException("只允许保存应用已导入的私有音频。")
        }
        return Uri.fromFile(file)
    }

    private fun validateRecordedTarget(entry: Entry): Uri {
        val uri = Uri.parse(entry.target)
        return if (uri.scheme == "file") validateTarget(null, uri.path) else validateTarget(entry.target, null)
    }

    fun recoveryTarget(): Uri? = read()?.takeIf { it.stage == WRITING }?.let(::validateRecordedTarget)

    private fun backupFile(entry: Entry): File {
        val file = File(entry.backup).canonicalFile
        if (file.parentFile != root.canonicalFile || !Regex("^[a-f0-9-]+\\.backup$").matches(file.name)) {
            throw IOException("原音频备份位置异常，已停止恢复。")
        }
        return file
    }

    fun ensureReady() {
        try {
            recover()
        } catch (error: Exception) {
            throw OriginalRecoveryRequiredException("无法完成上次原音频保存的恢复，请保留应用数据。${error.message ?: ""}", error)
        }
        if (read() != null) throw OriginalRecoveryRequiredException(notice() ?: "上次原音频保存尚未恢复，暂不能继续写入。")
    }

    /** Caller holds ExportRecoveryJournal.exclusively for the whole transaction. */
    fun save(target: Uri, tagged: File, sourceHash: String): String {
        ensureReady()
        val outputHash = hash(tagged)
        if (!root.exists() && !root.mkdirs()) throw IOException("无法建立原音频备份目录。")
        val backup = File(root, "${UUID.randomUUID()}.backup")
        var entry: Entry? = null
        var writing = false
        try {
            readTarget(target).use { input ->
                FileOutputStream(backup).use { output ->
                    copyBounded(input, output)
                    output.flush()
                    output.fd.sync()
                }
            }
            // Make both backup contents and its directory entry durable before journaling.
            for (directory in listOf(root, context.noBackupFilesDir)) {
                val directoryFd = Os.open(directory.path, OsConstants.O_RDONLY, 0)
                try { Os.fsync(directoryFd) } finally { Os.close(directoryFd) }
            }
            if (hash(backup) != sourceHash) throw IOException("原音频已变化，请重新读取并查询后再保存。原文件未修改。")
            entry = Entry(PREPARED, target.toString(), backup.path, sourceHash, outputHash)
            record(entry)
            // Check the live source before marking it possibly modified. A
            // crash while hashing must not roll back a newer external edit.
            // Providers do not offer a compare-and-swap/atomic write contract.
            if (hashTarget(target) != sourceHash) throw IOException("原音频已变化，已停止保存。原文件未修改。")
            entry = entry.copy(stage = WRITING)
            record(entry)
            writing = true
            overwrite(target, tagged)
            if (hashTarget(target) != outputHash) throw IOException("原音频保存后校验失败。")
            entry = entry.copy(stage = VERIFIED)
            record(entry)
            return target.toString()
        } catch (error: Exception) {
            val current = entry
            if (writing && current != null) {
                // commit(false) still changes SharedPreferences' in-memory map.
                // Reassert a durable unverified state BEFORE any rollback; a
                // failed VERIFIED commit must never later classify a partial
                // rollback as a successfully saved original.
                val rollback = current.copy(stage = WRITING)
                try {
                    record(rollback)
                } catch (journalError: Exception) {
                    val message = recoveryFailure(rollback)
                    try { setNotice(message) } catch (_: Exception) { /* keep backup */ }
                    throw OriginalRecoveryRequiredException(message, journalError)
                }
                if (restore(rollback)) {
                    setNotice("原音频保存未完成，已从备份恢复并通过校验，请重新尝试。")
                    throw IOException("保存失败，原音频已从备份完整恢复。", error)
                }
                val message = recoveryFailure(rollback)
                try { setNotice(message) } catch (_: Exception) { /* durable journal still exists */ }
                throw OriginalRecoveryRequiredException(message, error)
            }
            if (current != null) clear(current) else backup.delete()
            throw error
        }
    }

    fun recover(): String? {
        val entry = read() ?: return notice()
        when (entry.stage) {
            PREPARED -> {
                setNotice("上次保存原音频在写入前中断，原文件未修改，请重新保存。")
                clear(entry)
            }
            VERIFIED -> {
                // Keep a verified backup until task acknowledgement, or show the orphan outcome.
                setNotice("上次原音频已保存并通过校验，但任务记录可能尚未更新，请重新读取歌曲。位置：${entry.target}")
                clear(entry)
            }
            WRITING -> {
                val targetHash = try { hashTarget(validateRecordedTarget(entry)) } catch (_: Exception) { null }
                when {
                    targetHash == entry.outputHash -> {
                        setNotice("上次原音频保存已完成并通过校验，请重新读取歌曲以更新任务。位置：${entry.target}")
                        clear(entry)
                    }
                    targetHash == entry.originalHash || restore(entry) -> {
                        setNotice("上次原音频保存中断，原音频已恢复并通过校验，请重新保存。")
                        if (read() != null) clear(entry)
                    }
                    else -> setNotice(recoveryFailure(entry))
                }
            }
            else -> throw IOException("无法识别原音频恢复记录，请保留应用数据。")
        }
        return notice()
    }

    private fun recoveryFailure(entry: Entry) = "原音频保存中断且自动恢复未完成。请勿卸载应用或清除应用数据；" +
        "原始备份已保留，恢复权限后可重新启动应用重试。原文件：${entry.target}；备份：${entry.backup}"

    private fun restore(entry: Entry): Boolean = try {
        val backup = backupFile(entry)
        if (!backup.isFile || hash(backup) != entry.originalHash) false else {
            val target = validateRecordedTarget(entry)
            overwrite(target, backup)
            if (hashTarget(target) != entry.originalHash) false else {
                clear(entry)
                true
            }
        }
    } catch (_: Exception) { false }

    private fun readTarget(target: Uri) = if (target.scheme == "file") FileInputStream(File(target.path!!))
        else context.contentResolver.openInputStream(target) ?: throw IOException("无法读取原音频。")

    private fun hashTarget(target: Uri) = readTarget(target).use(::digest)

    /** Provider streams are NOT atomic. A durable backup and recovery journal cover interruption. */
    private fun overwrite(target: Uri, source: File) {
        if (target.scheme == "file") {
            FileOutputStream(File(target.path!!), false).use { output ->
                source.inputStream().use { copyBounded(it, output) }
                output.flush()
                output.fd.sync()
            }
        } else {
            // "rwt" requires truncation, unlike provider-dependent "w" semantics.
            val descriptor = context.contentResolver.openFileDescriptor(target, "rwt")
                ?: throw IOException("无法打开原音频写入权限。")
            android.os.ParcelFileDescriptor.AutoCloseOutputStream(descriptor).use { output ->
                source.inputStream().use { input -> copyBounded(input, output) }
                output.flush()
                output.fd.sync()
            }
        }
    }

    companion object {
        const val PREPARED = "prepared"
        const val WRITING = "writing"
        const val VERIFIED = "verified"
        fun hash(file: File): String = file.inputStream().use(::digest)
        private fun digest(input: java.io.InputStream): String {
            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(64 * 1024)
            var total = 0L
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                total += count
                if (total > 544L * 1024 * 1024) throw IOException("音频超过支持的安全写入大小。")
                digest.update(buffer, 0, count)
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
        fun copyBounded(input: java.io.InputStream, output: java.io.OutputStream) {
            val buffer = ByteArray(64 * 1024)
            var total = 0L
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                total += count
                if (total > 544L * 1024 * 1024) throw IOException("音频超过支持的安全写入大小。")
                output.write(buffer, 0, count)
            }
        }
    }
}
