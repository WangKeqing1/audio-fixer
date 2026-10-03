package com.audiofixer.audio_fixer

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import java.io.File
import java.io.IOException

/** Durable provenance for our new documents only. Never records an original URI. */
internal class ExportRecoveryJournal(context: Context) {
    private val context = context.applicationContext
    private val preferences = this.context.getSharedPreferences(
        "audio_fixer_export_recovery", Context.MODE_PRIVATE,
    )

    data class Entry(val stage: String, val path: String, val target: String?)

    fun read(): Entry? {
        val stage = preferences.getString("stage", null) ?: return null
        val path = preferences.getString("path", null) ?: return null
        return Entry(stage, path, preferences.getString("target", null))
    }

    fun record(stage: String, file: File, target: Uri? = null) {
        if (!preferences.edit().putString("stage", stage).putString("path", file.path)
                .putString("target", target?.toString()).commit()) {
            throw IOException("Unable to save audio export recovery information.")
        }
    }

    fun clear() {
        if (!preferences.edit().remove("stage").remove("path").remove("target").commit()) {
            throw IOException("Unable to clear audio export recovery information.")
        }
    }

    fun notice(): String? = preferences.getString("notice", null)

    fun setNotice(message: String?) {
        if (!preferences.edit().putString("notice", message).commit()) {
            throw IOException("Unable to save audio export recovery notice.")
        }
    }

    fun acknowledgeVerified(target: String) {
        val entry = read() ?: return
        if (entry.stage == VERIFIED && entry.target == target) clear()
    }

    /** A new Activity must not clean up while the old bridge finishes a write. */
    fun <T> exclusively(block: () -> T): T = synchronized(exportLock, block)

    /** Called before a new export or after a process/activity restart. */
    fun recover(): String? = exclusively { recoverLocked() }

    private fun recoverLocked(): String? {
        val entry = read() ?: return notice()
        when (entry.stage) {
            CREATING -> {
                setNotice("上次批量导出在建立新副本时中断，所选文件夹可能留有空白文件，请检查后重试。原音频未修改。文件夹：${entry.target}")
                cleanupTemporary(entry.path)
                clear()
            }
            VERIFIED -> {
                setNotice("上次音频副本已保存并通过校验，但应用在记录结果前中断。任务记录可能尚未更新。保存位置：${entry.target}")
                cleanupTemporary(entry.path)
                clear()
            }
            WRITING -> {
                val target = entry.target?.let(Uri::parse)
                val removed = target != null && deleteNewDocument(target)
                setNotice(if (removed) {
                    "上次音频保存中断，不完整的新副本已移除，请重新导出。原音频未修改。"
                } else {
                    "上次音频保存中断，保存位置可能留有不完整副本，请检查并手动删除后重试。原音频未修改。保存位置：${entry.target ?: "无法确认"}"
                })
                cleanupTemporary(entry.path)
                clear()
            }
            PREPARED -> {
                setNotice("上次导出在系统保存弹窗期间中断，请重新导出。原音频未修改。")
                cleanupTemporary(entry.path)
                // Keep provenance until Android returns the old save dialog.
                record(ABANDONED, File(entry.path))
            }
        }
        return notice()
    }

    /** A recreated Activity can receive a save result without its Dart caller. */
    fun recoverOrphanResult(target: Uri?) = exclusively { recoverOrphanResultLocked(target) }

    private fun recoverOrphanResultLocked(target: Uri?) {
        val entry = read()
        if (target == null) {
            if (entry?.stage == PREPARED || entry?.stage == ABANDONED) {
                cleanupTemporary(entry.path)
                clear()
            }
            return
        }
        if (entry?.stage == VERIFIED && entry.target == target.toString()) {
            recover()
            return
        }
        val hasProvenance = entry != null && (
            entry.stage == PREPARED || entry.stage == ABANDONED ||
                (entry.stage == WRITING && entry.target == target.toString())
            )
        val removed = hasProvenance && deleteNewDocument(target)
        setNotice(if (removed) {
            "应用在系统保存期间中断，未完成的新副本已移除，请重新导出。原音频未修改。"
        } else {
            "应用在系统保存期间中断，所选位置可能留有空白或不完整副本，请检查并手动删除后重试。原音频未修改。保存位置：$target"
        })
        if (hasProvenance) {
            cleanupTemporary(entry!!.path)
            clear()
        }
    }

    fun deleteNewDocument(target: Uri): Boolean = try {
        DocumentsContract.deleteDocument(context.contentResolver, target)
    } catch (_: Exception) {
        false
    }

    /** Delete only exact app-generated files under one bounded export directory. */
    private fun cleanupTemporary(path: String) {
        try {
            val root = File(context.cacheDir, "tagged_exports").canonicalFile
            val file = File(path).canonicalFile
            val directory = file.parentFile ?: return
            if (directory.parentFile != root || !directory.name.startsWith("export_") ||
                file.name !in setOf("tagged.mp3", "tagged.flac", "tagged.m4a", "tagged.mp4")) return
            if (file.isFile) file.delete()
            val staging = File(directory, "${file.name}.tagging").canonicalFile
            if (staging.parentFile == directory && staging.isFile) staging.delete()
            if (directory.list()?.isEmpty() == true) directory.delete()
        } catch (_: Exception) {
            // The app cache can be evicted independently; never touch any other path.
        }
    }

    companion object {
        private val exportLock = Any()
        const val CREATING = "creating"
        const val PREPARED = "prepared"
        const val WRITING = "writing"
        const val VERIFIED = "verified"
        const val ABANDONED = "abandoned"
    }
}
