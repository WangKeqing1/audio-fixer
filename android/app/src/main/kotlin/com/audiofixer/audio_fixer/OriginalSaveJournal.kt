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
import org.json.JSONArray
import org.json.JSONObject

internal class OriginalRecoveryRequiredException(message: String, cause: Throwable? = null) : IOException(message, cause)

/** Never pass these original-file records to ExportRecoveryJournal.deleteNewDocument. */
internal class OriginalSaveJournal(context: Context) {
    private val context = context.applicationContext
    private val preferences = this.context.getSharedPreferences("audio_fixer_original_recovery", Context.MODE_PRIVATE)
    private val root get() = File(context.noBackupFilesDir, "original_audio_backups")

    data class Version(val id: String, val path: String, val hash: String, val exportedUri: String? = null)
    data class Entry(val stage: String, val target: String, val backup: String,
                     val originalHash: String, val outputHash: String,
                     val versions: List<Version> = emptyList(), val originalExportedUri: String? = null)
    data class ExportVersion(val id: String, val file: File, val hash: String)

    fun read(): Entry? {
        val stage = preferences.getString("stage", null) ?: return null
        val versions = JSONArray(preferences.getString("versions", "[]"))
        return Entry(stage, required("target"), required("backup"), required("originalHash"), required("outputHash"),
            (0 until versions.length()).map { index ->
                val item = versions.getJSONObject(index)
                Version(item.getString("id"), item.getString("path"), item.getString("hash"),
                    if (item.isNull("exportedUri")) null else item.getString("exportedUri"))
            }, preferences.getString("originalExportedUri", null))
    }

    private fun required(key: String) = preferences.getString(key, null)
        ?: throw IOException("原音频恢复记录不完整，请保留应用数据并检查备份。")

    fun notice(): String? = preferences.getString("notice", null)
    fun setNotice(message: String?) {
        if (!preferences.edit().putString("notice", message).commit()) throw IOException("无法保存原音频恢复提醒。")
    }

    fun acknowledgeNotice() {
        // An unresolved backup must remain visible and must never be discarded.
        if (read() != null) throw OriginalRecoveryRequiredException(notice() ?: "原音频恢复尚待选择，请先保存需要的版本。")
        setNotice(null)
    }

    private fun record(entry: Entry) {
        if (!preferences.edit().putString("stage", entry.stage).putString("target", entry.target)
                .putString("backup", entry.backup).putString("originalHash", entry.originalHash)
                .putString("outputHash", entry.outputHash)
                .putString("originalExportedUri", entry.originalExportedUri)
                .putString("versions", JSONArray().apply { entry.versions.forEach { version ->
                    put(JSONObject().put("id", version.id).put("path", version.path).put("hash", version.hash)
                        .put("exportedUri", version.exportedUri ?: JSONObject.NULL))
                } }.toString()).commit()) throw IOException("无法保存原音频恢复记录。")
    }

    private fun clear(entry: Entry) {
        val files = listOf(backupFile(entry)) + entry.versions.map(::versionFile)
        // Only callers that established each version is safely kept may clear.
        if (!preferences.edit().remove("stage").remove("target").remove("backup")
                .remove("originalHash").remove("outputHash").remove("versions")
                .remove("originalExportedUri").commit()) throw IOException("无法清除原音频恢复记录。")
        files.forEach { it.delete() }
    }

    fun acknowledgeVerified(target: String) {
        read()?.let { if (it.stage == VERIFIED && it.target == target && it.versions.isEmpty()) clear(it) }
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

    fun recoveryTarget(): Uri? = read()?.takeIf { it.stage in setOf(WRITING, CONFLICT, RESTORING, RESTORED) }
        ?.let(::validateRecordedTarget)

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

    /** Startup classifies known bytes only; unknown content is NEVER overwritten. */
    fun recover(): String? {
        val entry = read() ?: return notice()
        // A retained snapshot is never disposable merely because an earlier
        // stage is known-complete. This also covers unusual interrupted export
        // or acknowledgement ordering.
        if (entry.versions.isNotEmpty() && entry.stage in setOf(PREPARED, VERIFIED)) {
            record(entry.copy(stage = CONFLICT))
            return recover()
        }
        when (entry.stage) {
            PREPARED -> {
                setNotice("上次保存原音频在写入前中断，原文件未修改，请重新保存。")
                clear(entry)
            }
            VERIFIED -> {
                setNotice("上次原音频已保存并通过校验，但任务记录可能尚未更新，请重新读取歌曲。位置：${entry.target}")
                clear(entry)
            }
            WRITING, CONFLICT, RESTORING, RESTORED -> {
                val currentHash = currentHash(entry)
                when {
                    entry.versions.isEmpty() && currentHash == entry.outputHash -> {
                        setNotice("上次原音频保存已完成并通过校验，请重新读取歌曲。位置：${entry.target}")
                        clear(entry)
                    }
                    entry.versions.isEmpty() && currentHash == entry.originalHash -> {
                        setNotice("原音频与保存前备份完全一致，已核对原文件未丢失。")
                        clear(entry)
                    }
                    currentHash == null -> setNotice("无法读取当前原文件，未自动覆盖。原始备份已保留；可重新检查权限或导出备份。位置：${entry.target}")
                    else -> {
                        val restored = currentHash == entry.originalHash
                        record(entry.copy(stage = if (restored) RESTORED else CONFLICT))
                        setNotice(if (restored) {
                            "已恢复保存前的原音频。恢复前的不同版本仍安全保留，请导出需要的版本后完成处理。"
                        } else {
                            "检测到原文件出现不同内容，未自动覆盖当前文件。原始备份已保留；请导出需要的版本，或明确选择保留当前版本后恢复备份。"
                        })
                    }
                }
            }
            else -> throw IOException("无法识别原音频恢复记录，请保留应用数据。")
        }
        return notice()
    }

    private fun currentHash(entry: Entry): String? = try { hashTarget(validateRecordedTarget(entry)) } catch (_: Exception) { null }

    private fun versionFile(version: Version): File {
        val file = File(version.path).canonicalFile
        if (file.parentFile != root.canonicalFile || !Regex("^[a-f0-9-]+\\.current$").matches(file.name)) {
            throw IOException("保留版本位置无效，请保留应用数据。")
        }
        return file
    }

    private fun verifiedOriginal(entry: Entry): Boolean = try {
        backupFile(entry).let { it.isFile && hash(it) == entry.originalHash }
    } catch (_: Exception) { false }

    private fun safelyKept(hash: String, exported: String?, liveHash: String?): Boolean {
        if (hash == liveHash) return true
        if (exported == null) return false
        return try {
            val uri = Uri.parse(exported)
            uri.scheme == "content" && context.contentResolver.openInputStream(uri)?.use(::digest) == hash
        } catch (_: Exception) { false }
    }

    fun state(): Map<String, Any?>? {
        val entry = read() ?: return null
        val liveHash = currentHash(entry)
        val versions = mutableListOf<Map<String, Any?>>(linkedMapOf(
            "id" to "original", "label" to "保存前原始备份", "sha256" to entry.originalHash,
            "sizeBytes" to backupFile(entry).length(), "exportedUri" to entry.originalExportedUri,
        ))
        entry.versions.forEachIndexed { index, version -> versions += linkedMapOf(
            "id" to version.id, "label" to "保留的当前版本 ${index + 1}", "sha256" to version.hash,
            "sizeBytes" to versionFile(version).length(), "exportedUri" to version.exportedUri,
        ) }
        if (liveHash != null && liveHash != entry.originalHash && entry.versions.none { it.hash == liveHash }) {
            val target = validateRecordedTarget(entry)
            val size = if (target.scheme == "file") File(target.path!!).length() else try {
                context.contentResolver.openAssetFileDescriptor(target, "r")?.use { it.length.coerceAtLeast(0L) } ?: 0L
            } catch (_: Exception) { 0L }
            versions += linkedMapOf("id" to "current", "label" to "当前原文件", "sha256" to liveHash,
                "sizeBytes" to size, "exportedUri" to null)
        }
        return linkedMapOf(
            "status" to if (liveHash == null) "permissionRequired" else if (liveHash == entry.originalHash) "restored" else "conflict",
            "targetUri" to entry.target,
            "canRestore" to (liveHash != null && liveHash != entry.originalHash && verifiedOriginal(entry)),
            "canFinish" to (safelyKept(entry.originalHash, entry.originalExportedUri, liveHash) &&
                entry.versions.all { safelyKept(it.hash, it.exportedUri, liveHash) }),
            "versions" to versions,
        )
    }

    /** Save every distinct prior live version before a separately confirmed restore. */
    private fun preserveCurrent(entry: Entry): Pair<Entry, Version> {
        val target = validateRecordedTarget(entry)
        val liveHash = hashTarget(target)
        entry.versions.firstOrNull { it.hash == liveHash }?.let { existing ->
            if (hash(versionFile(existing)) != liveHash) throw IOException("已保留版本校验失败，未覆盖原文件。")
            return entry to existing
        }
        val id = UUID.randomUUID().toString()
        val file = File(root, "$id.current")
        var recorded = false
        try {
            readTarget(target).use { input -> FileOutputStream(file).use { output ->
                copyBounded(input, output); output.flush(); output.fd.sync()
            } }
            syncBackupDirectory()
            if (hash(file) != liveHash || hashTarget(target) != liveHash) {
                throw IOException("当前原文件在保留期间发生变化，未覆盖。请重新检查。")
            }
            val version = Version(id, file.path, liveHash)
            val updated = entry.copy(versions = entry.versions + version)
            // On commit failure keep the durable file too: commit(false) has
            // uncertain disk outcome and must never strand a missing snapshot.
            recorded = true
            record(updated)
            return updated to version
        } finally {
            if (!recorded) file.delete()
        }
    }

    fun restoreOriginalBackup(): String? {
        val initial = read() ?: return notice()
        if (!verifiedOriginal(initial)) throw OriginalRecoveryRequiredException("原始备份校验失败，未覆盖当前文件。")
        if (currentHash(initial) == initial.originalHash) {
            record(initial.copy(stage = RESTORED))
            return recover()
        }
        val (preserved, version) = preserveCurrent(initial)
        val target = validateRecordedTarget(preserved)
        if (hashTarget(target) != version.hash) throw OriginalRecoveryRequiredException("当前原文件再次变化，未覆盖；已保留的版本仍在。")
        val restoring = preserved.copy(stage = RESTORING)
        record(restoring)
        try {
            overwrite(target, backupFile(restoring))
            if (hashTarget(target) != restoring.originalHash) throw IOException("恢复后的原音频校验失败。")
            record(restoring.copy(stage = RESTORED))
            setNotice("已恢复保存前的原音频，并完整保留恢复前的不同版本。请导出需要的版本后完成处理。")
            return notice()
        } catch (error: Exception) {
            try { record(restoring.copy(stage = CONFLICT)); setNotice("恢复未完成，原始备份和恢复前版本均已保留，未自动重试覆盖。") }
            catch (_: Exception) { /* never delete either durable copy */ }
            throw OriginalRecoveryRequiredException("恢复未完成，两个版本均已保留，请检查权限或空间后重新选择。", error)
        }
    }

    fun exportVersion(id: String): ExportVersion {
        var entry = read() ?: throw IOException("没有待处理的原音频恢复版本。")
        if (id == "original") {
            if (!verifiedOriginal(entry)) throw IOException("原始备份校验失败，不能导出为完整版本。")
            return ExportVersion(id, backupFile(entry), entry.originalHash)
        }
        val version = if (id == "current") {
            val captured = preserveCurrent(entry)
            entry = captured.first
            captured.second
        } else entry.versions.singleOrNull { it.id == id } ?: throw IOException("此恢复版本已变化，请刷新。")
        val file = versionFile(version)
        if (hash(file) != version.hash) throw IOException("恢复版本校验失败。")
        return ExportVersion(version.id, file, version.hash)
    }

    fun markExported(id: String, uri: Uri) {
        val entry = read() ?: throw IOException("恢复记录已变化，请保留刚导出的副本。")
        record(if (id == "original") entry.copy(originalExportedUri = uri.toString()) else {
            if (entry.versions.none { it.id == id }) throw IOException("恢复版本已变化，请保留刚导出的副本。")
            entry.copy(versions = entry.versions.map { if (it.id == id) it.copy(exportedUri = uri.toString()) else it })
        })
    }

    fun finishRecovery() {
        val entry = read() ?: return
        val liveHash = currentHash(entry)
        if (!safelyKept(entry.originalHash, entry.originalExportedUri, liveHash) ||
            entry.versions.any { !safelyKept(it.hash, it.exportedUri, liveHash) }) {
            throw OriginalRecoveryRequiredException("仍有只保存在应用内的版本，请先导出需要保留的版本。当前原文件未修改。")
        }
        setNotice("恢复处理已完成，当前原文件保持不变，需要的版本已核对保留。")
        clear(entry)
    }

    private fun syncBackupDirectory() {
        for (directory in listOf(root, context.noBackupFilesDir)) {
            val fd = Os.open(directory.path, OsConstants.O_RDONLY, 0)
            try { Os.fsync(fd) } finally { Os.close(fd) }
        }
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
        const val CONFLICT = "conflict"
        const val RESTORING = "restoring"
        const val RESTORED = "restored"
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
