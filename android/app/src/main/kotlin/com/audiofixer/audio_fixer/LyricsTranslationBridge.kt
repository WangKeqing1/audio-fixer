package com.audiofixer.audio_fixer

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.google.android.gms.tasks.Task
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.common.MlKit
import com.google.mlkit.common.MlKitException
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.nl.languageid.LanguageIdentification
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.TranslateRemoteModel
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.Translator
import com.google.mlkit.nl.translate.TranslatorOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.Closeable
import java.util.concurrent.Executor

/**
 * Explicit-download, on-device lyric translation. Flutter owns consent, source
 * selection, LRC timing, provenance, and candidate review. This bridge never
 * logs or persists lyric text, and translating never starts a model download.
 *
 * No ML Kit client/model manager is obtained by constructing this bridge. The
 * caller must show the SDK privacy disclosure before invoking these methods.
 */
class LyricsTranslationBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val mainExecutor = Executor { mainHandler.post(it) }
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val pending = mutableSetOf<PendingReply>()
    private val downloads = mutableMapOf<String, Task<Void>>()
    private var inference: PendingReply? = null
    private var disposed = false

    init {
        channel.setMethodCallHandler(::onMethodCall)
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        // Reply before removing the handler, so live Dart callers do not hang.
        pending.toList().forEach { it.error("DISPOSED", "Translation bridge was closed.") }
        channel.setMethodCallHandler(null)
        downloads.clear()
        // ML Kit's download Task has no cancellation API. Already-authorized
        // OS-managed Wi-Fi downloads may finish after this Activity is closed.
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.error("DISPOSED", "Translation bridge was closed.", null)
            return
        }
        val timeout = when (call.method) {
            "identifyLanguage", "modelStatus", "openInfoLink" -> STATUS_TIMEOUT_MS
            "downloadModels" -> DOWNLOAD_TIMEOUT_MS
            "translateLines" -> TRANSLATION_TIMEOUT_MS
            else -> {
                result.notImplemented()
                return
            }
        }
        if (pending.size >= MAX_PENDING_REQUESTS) {
            result.error("BUSY", "Too many translation requests are pending.", null)
            return
        }
        val failureCode = when (call.method) {
            "identifyLanguage" -> "IDENTIFICATION_FAILED"
            "modelStatus" -> "MODEL_STATUS_FAILED"
            "downloadModels" -> "DOWNLOAD_FAILED"
            "openInfoLink" -> "LINK_UNAVAILABLE"
            else -> "TRANSLATION_FAILED"
        }
        val reply = PendingReply(result, timeout, failureCode)
        pending.add(reply)
        reply.guard {
            val arguments = call.arguments as? Map<*, *>
                ?: throw BridgeException("INVALID_ARGUMENT", "Expected method arguments.")
            when (call.method) {
                "identifyLanguage" -> identifyLanguage(arguments, reply)
                "modelStatus" -> readStatus(sourceLanguage(arguments), reply) { reply.success(it) }
                "downloadModels" -> downloadModels(sourceLanguage(arguments), reply)
                "translateLines" -> translateLines(sourceLanguage(arguments), readLines(arguments), reply)
                "openInfoLink" -> openInfoLink(arguments, reply)
            }
        }
    }

    private fun identifyLanguage(arguments: Map<*, *>, reply: PendingReply) {
        val text = arguments["text"] as? String
            ?: throw BridgeException("INVALID_ARGUMENT", "text must be a string.")
        if (text.length > MAX_TOTAL_CHARACTERS) {
            throw BridgeException("INVALID_ARGUMENT", "Language sample is too long.")
        }
        if (text.isBlank()) {
            reply.success("und")
            return
        }
        claimInference(reply)
        ensureMlKitInitialized()
        val identifier = LanguageIdentification.getClient()
        reply.client = identifier
        // The bundled model uses the SDK's default confidence threshold (0.5).
        // This identifies the entire sample, not each language in mixed text.
        identifier.identifyLanguage(text).addOnCompleteListener(mainExecutor) { task ->
            reply.guard {
                if (task.isSuccessful) reply.success(task.result ?: "und")
                else reply.error("IDENTIFICATION_FAILED", "Could not identify the lyric language.")
            }
        }
    }

    private fun openInfoLink(arguments: Map<*, *>, reply: PendingReply) {
        val url = arguments["url"] as? String
        if (url !in INFO_LINKS) {
            throw BridgeException("INVALID_ARGUMENT", "This information link is not allowed.")
        }
        // Invoked only by a Flutter user action. No arbitrary URL, extras,
        // model initialization, or lyric content crosses this boundary.
        activity.startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE),
        )
        reply.success(null)
    }

    private fun ensureMlKitInitialized() {
        if (mlKitInitialized) return
        // The default provider is removed using Google's documented manifest
        // configuration. Only an opted-in SDK operation reaches this call.
        // https://developers.google.com/android/reference/com/google/mlkit/common/MlKit
        MlKit.initialize(activity.applicationContext)
        mlKitInitialized = true
    }

    private fun sourceLanguage(arguments: Map<*, *>): String {
        val tag = arguments["sourceLanguage"] as? String
            ?: throw BridgeException("INVALID_ARGUMENT", "sourceLanguage must be a language tag.")
        if (tag.length > 35 || !LANGUAGE_TAG.matches(tag)) {
            throw BridgeException("UNSUPPORTED_LANGUAGE", "This source language is not supported.")
        }
        val language = TranslateLanguage.fromLanguageTag(tag)
        if (language == null || language == TranslateLanguage.CHINESE) {
            throw BridgeException("UNSUPPORTED_LANGUAGE", "A supported non-Chinese source language is required.")
        }
        return language
    }

    private fun readLines(arguments: Map<*, *>): List<String> {
        val raw = arguments["lines"] as? List<*>
            ?: throw BridgeException("INVALID_ARGUMENT", "lines must be a list of strings.")
        if (raw.size > MAX_INPUT_LINES || raw.any { it !is String }) {
            throw BridgeException("INVALID_ARGUMENT", "Too many lines or invalid line data.")
        }
        val lines = raw.map { it as String }
        if (lines.any { it.length > MAX_LINE_CHARACTERS }) {
            throw BridgeException("INVALID_ARGUMENT", "An individual lyric line is too long.")
        }
        val unique = lines.toSet()
        if (unique.size > MAX_UNIQUE_LINES || unique.sumOf { it.length } > MAX_TOTAL_CHARACTERS) {
            throw BridgeException("INVALID_ARGUMENT", "Lyrics exceed the on-device translation limit.")
        }
        return lines
    }

    private fun requiredModels(source: String): Set<String> =
        // English is built in, and must not be made into a TranslateRemoteModel:
        // https://developers.google.com/android/reference/com/google/mlkit/nl/translate/TranslateRemoteModel
        setOf(source, TranslateLanguage.CHINESE).filterTo(linkedSetOf()) {
            it != TranslateLanguage.ENGLISH
        }

    private fun readStatus(source: String, reply: PendingReply, onReady: (Map<String, Any>) -> Unit) {
        ensureMlKitInitialized()
        RemoteModelManager.getInstance()
            .getDownloadedModels(TranslateRemoteModel::class.java)
            .addOnCompleteListener(mainExecutor) { task ->
                reply.guard {
                    if (!task.isSuccessful) {
                        reply.error("MODEL_STATUS_FAILED", "Could not inspect translation models.")
                        return@guard
                    }
                    val downloaded = task.result.map { it.language }.toSet()
                    val missing = requiredModels(source) - downloaded
                    onReady(
                        mapOf(
                            "sourceLanguage" to source,
                            "ready" to missing.isEmpty(),
                            "missingModels" to missing.sorted(),
                            "downloadedModels" to downloaded.sorted(),
                        ),
                    )
                }
            }
    }

    private fun downloadModels(source: String, reply: PendingReply) {
        readStatus(source, reply) { status ->
            if (status["ready"] == true) {
                reply.success(status)
                return@readStatus
            }
            @Suppress("UNCHECKED_CAST")
            val missing = status["missingModels"] as List<String>
            val newCount = missing.count { it !in downloads }
            if (downloads.size + newCount > MAX_ACTIVE_DOWNLOADS) {
                reply.error("BUSY", "Other language models are still downloading.")
                return@readStatus
            }
            val tasks = missing.map { language ->
                downloads[language] ?: startDownload(language)
            }
            Tasks.whenAll(tasks).addOnCompleteListener(mainExecutor) { task ->
                reply.guard {
                    if (!task.isSuccessful) {
                        reply.error("DOWNLOAD_FAILED", "Model download failed. Check Wi-Fi and available storage.")
                        return@guard
                    }
                    // Verify actual persisted state rather than assuming a
                    // successful Task means all requested models are available.
                    readStatus(source, reply) { updated ->
                        if (updated["ready"] == true) reply.success(updated)
                        else reply.error("DOWNLOAD_FAILED", "Required models are still unavailable.", updated)
                    }
                }
            }
        }
    }

    private fun startDownload(language: String): Task<Void> {
        val model = TranslateRemoteModel.Builder(language).build()
        val conditions = DownloadConditions.Builder().requireWifi().build()
        val task = RemoteModelManager.getInstance().download(model, conditions)
        downloads[language] = task
        task.addOnCompleteListener(mainExecutor) {
            if (downloads[language] === task) downloads.remove(language)
        }
        return task
    }

    private fun translateLines(source: String, lines: List<String>, reply: PendingReply) {
        if (lines.isEmpty()) {
            reply.success(emptyList<String>())
            return
        }
        claimInference(reply)
        readStatus(source, reply) { status ->
            if (status["ready"] != true) {
                reply.error("MODELS_MISSING", "Download the required language models first.", status)
                return@readStatus
            }
            val translator = Translation.getClient(
                TranslatorOptions.Builder()
                    .setSourceLanguage(source)
                    .setTargetLanguage(TranslateLanguage.CHINESE)
                    .build(),
            )
            reply.client = translator
            val translated = mutableMapOf<String, String>()
            val unique = lines.distinct()
            translateNext(translator, unique, 0, translated, reply) {
                reply.success(lines.map { translated.getValue(it) })
            }
        }
    }

    private fun translateNext(
        translator: Translator,
        unique: List<String>,
        index: Int,
        translated: MutableMap<String, String>,
        reply: PendingReply,
        onComplete: () -> Unit,
    ) {
        if (!reply.active) return
        // Preserve blank input verbatim without submitting it to ML Kit.
        var next = index
        while (next < unique.size && unique[next].isBlank()) {
            translated[unique[next]] = unique[next]
            next++
        }
        if (next == unique.size) {
            onComplete()
            return
        }
        val current = next
        val line = unique[current]
        // Strictly one local inference at a time. Never call downloadModelIfNeeded here.
        translator.translate(line).addOnCompleteListener(mainExecutor) { task ->
            reply.guard {
                if (!task.isSuccessful) {
                    val code = if ((task.exception as? MlKitException)?.errorCode == MlKitException.NOT_FOUND) {
                        "MODELS_MISSING"
                    } else {
                        "TRANSLATION_FAILED"
                    }
                    reply.error(code, "Could not translate these lyrics on this device.")
                    return@guard
                }
                val value = task.result
                if (value.isNullOrBlank()) {
                    reply.error("TRANSLATION_FAILED", "Translation returned an empty lyric line.")
                    return@guard
                }
                translated[line] = value
                translateNext(translator, unique, current + 1, translated, reply, onComplete)
            }
        }
    }

    private fun claimInference(reply: PendingReply) {
        if (inference != null) {
            throw BridgeException("BUSY", "Another language operation is still running.")
        }
        inference = reply
    }

    /** All operations and SDK completions run on the main executor. */
    private inner class PendingReply(
        private val delegate: MethodChannel.Result,
        timeout: Long,
        private val failureCode: String,
    ) {
        private var completed = false
        var client: Closeable? = null
        val active: Boolean get() = !completed && !disposed
        private val timeoutAction = Runnable {
            error(
                "TIMEOUT",
                if (failureCode == "DOWNLOAD_FAILED") {
                    "Model download timed out. An already-started Wi-Fi download may still finish."
                } else {
                    "The on-device language operation timed out."
                },
            )
        }

        init {
            mainHandler.postDelayed(timeoutAction, timeout)
        }

        fun guard(action: () -> Unit) {
            if (!active) return
            try {
                action()
            } catch (failure: BridgeException) {
                error(failure.code, failure.message)
            } catch (_: Exception) {
                // SDK exception messages can include input. Do not return or
                // log them, even on a failure path.
                error(failureCode, "The on-device language operation failed.")
            }
        }

        fun success(value: Any?) = finish { delegate.success(value) }

        fun error(code: String, message: String, details: Any? = null) =
            finish { delegate.error(code, message, details) }

        private fun finish(send: () -> Unit) {
            if (completed) return
            completed = true
            mainHandler.removeCallbacks(timeoutAction)
            pending.remove(this)
            if (inference === this) inference = null
            runCatching { client?.close() }
            client = null
            // An engine can detach while its Activity is closing. A late SDK
            // callback must never double-reply or crash the host Activity.
            runCatching(send)
        }
    }

    private class BridgeException(val code: String, override val message: String) : Exception(message)

    private companion object {
        private const val CHANNEL_NAME = "audio_fixer/lyrics_translation"
        private const val MAX_PENDING_REQUESTS = 16
        private const val MAX_ACTIVE_DOWNLOADS = 4
        private const val MAX_INPUT_LINES = 1000
        private const val MAX_UNIQUE_LINES = 300
        private const val MAX_LINE_CHARACTERS = 2000
        private const val MAX_TOTAL_CHARACTERS = 20000
        private const val STATUS_TIMEOUT_MS = 15000L
        private const val TRANSLATION_TIMEOUT_MS = 120000L
        private const val DOWNLOAD_TIMEOUT_MS = 300000L
        private val LANGUAGE_TAG = Regex("[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*")
        private var mlKitInitialized = false
        private val INFO_LINKS = setOf(
            "https://developers.google.com/ml-kit/terms",
            "https://developers.google.com/ml-kit/android-data-disclosure",
            "https://developers.google.com/ml-kit/language/translation",
            "https://translate.google.com/",
        )
    }
}
