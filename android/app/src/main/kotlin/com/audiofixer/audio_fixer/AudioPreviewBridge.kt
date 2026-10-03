package com.audiofixer.audio_fixer

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.AssetFileDescriptor
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.IOException
import java.util.concurrent.atomic.AtomicLong

/**
 * A foreground-only, single-item local preview. All MediaPlayer calls and
 * callbacks live on one looper. Only MediaStore audio and this app's private
 * files can become a data source; no URI is passed to MediaPlayer's URL loader.
 */
class AudioPreviewBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val playbackThread = HandlerThread("audio-preview").apply { start() }
    private val playbackHandler = Handler(playbackThread.looper)
    private val channel = MethodChannel(messenger, "audio_fixer/audio_preview")
    private val events = EventChannel(messenger, "audio_fixer/audio_preview_events")
    private val audioManager = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
        .build()
    private val generation = AtomicLong(0)
    private var eventSink: EventChannel.EventSink? = null // Main thread only.
    private val pendingReplies = mutableSetOf<PendingReply>() // Main thread only.
    private var receiverRegistered = false
    @Volatile private var disposed = false
    @Volatile private var foreground = false
    @Volatile private var requestedId: Long? = null
    @Volatile private var wantsAudio = false
    // Playback-thread state. An immutable snapshot crosses back to Flutter.
    private var session: Session? = null
    private val unreleasedPlayers = mutableSetOf<MediaPlayer>()
    private var lastState: Map<String, Any?> = stoppedState()

    private class Session(
        val requestId: Long,
        val trackId: String,
        val uri: String,
        val generation: Long,
    ) {
        var player: MediaPlayer? = null
        var prepared = false
        var wantsPlayback = true
        var status = "loading"
        var positionMs = 0L
        var durationMs = 0L
        var errorCode: String? = null
        var seeking = false
        var queuedSeek: Long? = null
        var timeout: Runnable? = null
        var ticker: Runnable? = null
        var focusListener: AudioManager.OnAudioFocusChangeListener? = null
        var focusRequest: AudioFocusRequest? = null
        var hasFocus = false
    }

    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != AudioManager.ACTION_AUDIO_BECOMING_NOISY) return
            wantsAudio = false
            val token = generation.get()
            playbackHandler.post { session?.takeIf { it.generation == token }?.let(::pause) }
        }
    }

    init {
        channel.setMethodCallHandler(::onMethodCall)
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                eventSink = sink
                playbackHandler.post { publish() }
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
                // Losing the UI listener must not leave an invisible player.
                stop()
            }
        })
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(noisyReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            activity.registerReceiver(noisyReceiver, filter)
        }
        receiverRegistered = true
    }

    fun onResume() { foreground = true }

    fun onPause() {
        // This gate changes before the asynchronous release. An in-flight
        // prepare/focus/seek callback can no longer start playback.
        foreground = false
        stop()
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        foreground = false
        wantsAudio = false
        requestedId = null
        generation.incrementAndGet()
        pendingReplies.toList().forEach { it.error("disposed") }
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        eventSink = null
        if (receiverRegistered) {
            activity.unregisterReceiver(noisyReceiver)
            receiverRegistered = false
        }
        playbackHandler.post {
            release(session)
            retryReleases()
            session = null
            playbackThread.quitSafely()
        }
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.error("disposed", "Audio preview is unavailable.", null)
            return
        }
        when (call.method) {
            "play" -> {
                val arguments = call.arguments as? Map<*, *>
                val requestId = (arguments?.get("requestId") as? Number)?.toLong()
                val trackId = arguments?.get("trackId") as? String
                val uri = arguments?.get("uri") as? String
                if (requestId == null || requestId < 1 || trackId.isNullOrBlank() || uri.isNullOrBlank()) {
                    result.error("invalid_argument", "A local audio item is required.", null)
                    return
                }
                if (!foreground) {
                    result.error("backgrounded", "Return to the app to preview audio.", null)
                    return
                }
                val token = if (requestedId == requestId) generation.get() else generation.incrementAndGet()
                requestedId = requestId
                wantsAudio = true
                playbackHandler.post { play(requestId, trackId, uri, token) }
                result.success(null)
            }
            "pause", "seek" -> {
                val arguments = call.arguments as? Map<*, *>
                val requestId = (arguments?.get("requestId") as? Number)?.toLong()
                val position = (arguments?.get("positionMs") as? Number)?.toLong()
                if (requestId == null || (call.method == "seek" && position == null)) {
                    result.error("invalid_argument", "A preview request is required.", null)
                    return
                }
                val token = generation.get()
                if (call.method == "pause" && requestedId == requestId) wantsAudio = false
                playbackHandler.post {
                    val current = session
                    if (current != null && current.requestId == requestId && current.generation == token && isCurrent(current)) {
                        if (call.method == "pause") pause(current) else seek(current, position!!)
                    }
                }
                result.success(null)
            }
            "stop" -> {
                val reply = PendingReply(result)
                // Unlike play/pause/seek, a successful stop is a release barrier
                // which Dart can await before modifying the original audio.
                stop { released ->
                    if (released) reply.success(null) else reply.error("release_failed")
                }
            }
            "getState" -> {
                val reply = PendingReply(result)
                playbackHandler.post {
                    session?.let(::readPosition)
                    val value = session?.let(::state) ?: lastState
                    mainHandler.post { reply.success(value) }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun play(requestId: Long, trackId: String, uri: String, token: Long) {
        if (disposed || !foreground || token != generation.get()) return
        val previous = session
        if (previous != null && previous.requestId == requestId && previous.trackId == trackId &&
            previous.uri == uri && previous.player != null && previous.generation == token) {
            previous.wantsPlayback = true
            when {
                !previous.prepared -> Unit
                previous.status == "completed" -> seek(previous, 0)
                !previous.seeking -> start(previous)
            }
            return
        }
        retryReleases()
        release(previous)
        val current = Session(requestId, trackId, uri, token)
        session = current
        if (unreleasedPlayers.isNotEmpty()) { fail(current, "release_failed"); return }
        publish()
        try {
            val player = MediaPlayer()
            current.player = player
            player.setAudioAttributes(attributes)
            player.setOnPreparedListener {
                if (!isCurrent(current, it)) return@setOnPreparedListener
                current.timeout?.let(playbackHandler::removeCallbacks)
                current.timeout = null
                current.prepared = true
                try { current.durationMs = it.duration.toLong().coerceAtLeast(0) }
                catch (_: RuntimeException) { fail(current, "playback_failed"); return@setOnPreparedListener }
                val target = current.queuedSeek
                current.queuedSeek = null
                if (target != null) seek(current, target)
                else if (wantsAudio && current.wantsPlayback) start(current)
                else { current.status = "paused"; publish() }
            }
            player.setOnCompletionListener {
                if (!isCurrent(current, it)) return@setOnCompletionListener
                current.wantsPlayback = false
                readPosition(current)
                current.status = "completed"
                stopTicker(current)
                abandonFocus(current)
                publish()
            }
            player.setOnSeekCompleteListener {
                if (!isCurrent(current, it)) return@setOnSeekCompleteListener
                current.seeking = false
                val target = current.queuedSeek
                current.queuedSeek = null
                if (target != null) seek(current, target)
                else {
                    readPosition(current)
                    if (wantsAudio && current.wantsPlayback && current.status != "playing") start(current) else publish()
                }
            }
            player.setOnErrorListener { failedPlayer, _, extra ->
                if (isCurrent(current, failedPlayer)) {
                    fail(current, when (extra) {
                        MediaPlayer.MEDIA_ERROR_MALFORMED, MediaPlayer.MEDIA_ERROR_UNSUPPORTED -> "unsupported_format"
                        MediaPlayer.MEDIA_ERROR_IO -> "source_unavailable"
                        MediaPlayer.MEDIA_ERROR_TIMED_OUT -> "preparation_timeout"
                        else -> "playback_failed"
                    })
                }
                true
            }
            setLocalSource(player, uri)
            if (!isCurrent(current) || !foreground) { release(current); return }
            val timeout = Runnable {
                if (isCurrent(current) && !current.prepared) fail(current, "preparation_timeout")
            }
            current.timeout = timeout
            playbackHandler.postDelayed(timeout, 20_000)
            player.prepareAsync()
        } catch (_: SecurityException) {
            fail(current, "permission_denied")
        } catch (_: InvalidSourceException) {
            fail(current, "invalid_source")
        } catch (_: FileNotFoundException) {
            fail(current, "source_unavailable")
        } catch (_: IOException) {
            fail(current, "source_unavailable")
        } catch (_: IllegalArgumentException) {
            fail(current, "unsupported_format")
        } catch (_: RuntimeException) {
            fail(current, "playback_failed")
        }
    }

    private fun setLocalSource(player: MediaPlayer, source: String) {
        val uri = Uri.parse(source)
        when (uri.scheme) {
            "content" -> {
                val segments = uri.pathSegments
                if (uri.authority != MediaStore.AUTHORITY || segments.size != 4 ||
                    segments[1] != "audio" || segments[2] != "media" ||
                    segments[3].toLongOrNull() == null || uri.query != null || uri.fragment != null) {
                    throw InvalidSourceException()
                }
                val descriptor = activity.contentResolver.openAssetFileDescriptor(uri, "r")
                    ?: throw FileNotFoundException()
                descriptor.use {
                    if (it.declaredLength == AssetFileDescriptor.UNKNOWN_LENGTH) player.setDataSource(it.fileDescriptor)
                    else player.setDataSource(it.fileDescriptor, it.startOffset, it.declaredLength)
                }
            }
            null, "file" -> {
                if (uri.query != null || uri.fragment != null || !uri.authority.isNullOrEmpty()) throw InvalidSourceException()
                val path = if (uri.scheme == null) source else uri.path ?: throw InvalidSourceException()
                val file = File(path)
                if (!file.isAbsolute) throw InvalidSourceException()
                val canonical = file.canonicalFile
                val privateRoot = File(activity.applicationInfo.dataDir).canonicalPath + File.separator
                if (!canonical.path.startsWith(privateRoot)) throw InvalidSourceException()
                if (!canonical.isFile || canonical.length() == 0L) throw FileNotFoundException()
                FileInputStream(canonical).use { player.setDataSource(it.fd) }
            }
            else -> throw InvalidSourceException()
        }
    }

    private fun start(current: Session) {
        if (!isCurrent(current) || !foreground || !wantsAudio || !current.wantsPlayback || !current.prepared) return
        try {
            if (!requestFocus(current)) { fail(current, "audio_focus_denied"); return }
            // Focus requests can race an Activity pause or a newer command.
            if (!isCurrent(current) || !foreground || !wantsAudio || !current.wantsPlayback) { abandonFocus(current); return }
            current.player?.start()
            current.status = "playing"
            current.errorCode = null
            publish()
            startTicker(current)
        } catch (_: RuntimeException) { fail(current, "playback_failed") }
    }

    private fun pause(current: Session) {
        if (!isCurrent(current)) return
        current.wantsPlayback = false
        try {
            if (current.prepared && current.status == "playing") current.player?.pause()
            readPosition(current)
            if (current.status != "error" && current.status != "completed") current.status = "paused"
            stopTicker(current)
            abandonFocus(current)
            publish()
        } catch (_: RuntimeException) { fail(current, "playback_failed") }
    }

    private fun seek(current: Session, requestedPosition: Long) {
        if (!isCurrent(current) || current.player == null) return
        val position = requestedPosition.coerceAtLeast(0).let {
            if (current.prepared) it.coerceAtMost(current.durationMs) else it
        }
        if (!current.prepared || current.seeking) { current.queuedSeek = position; return }
        try {
            current.seeking = true
            if (current.status == "completed") current.status = "paused"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) current.player?.seekTo(position, MediaPlayer.SEEK_CLOSEST)
            else {
                @Suppress("DEPRECATION")
                current.player?.seekTo(position.coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
            }
        } catch (_: RuntimeException) { fail(current, "playback_failed") }
    }

    private fun requestFocus(current: Session): Boolean {
        if (current.hasFocus) return true
        lateinit var listener: AudioManager.OnAudioFocusChangeListener
        listener = AudioManager.OnAudioFocusChangeListener { change ->
            // Pre-O AudioManager may deliver on the main looper. Always marshal
            // to our player looper and reject callbacks from abandoned requests.
            playbackHandler.post {
                if (isCurrent(current) && current.focusListener === listener) {
                    when (change) {
                        AudioManager.AUDIOFOCUS_LOSS,
                        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> pause(current)
                        // Gain is ignored. Only a fresh user play resumes.
                    }
                }
            }
        }
        current.focusListener = listener
        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attributes)
                .setWillPauseWhenDucked(true)
                .setAcceptsDelayedFocusGain(false)
                .setOnAudioFocusChangeListener(listener, playbackHandler)
                .build()
            current.focusRequest = request
            audioManager.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        }
        current.hasFocus = granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        return current.hasFocus
    }

    private fun abandonFocus(current: Session) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) current.focusRequest?.let(audioManager::abandonAudioFocusRequest)
            else {
                @Suppress("DEPRECATION")
                current.focusListener?.let(audioManager::abandonAudioFocus)
            }
        } catch (_: RuntimeException) { /* Releasing playback must still finish. */ }
        current.focusRequest = null
        current.focusListener = null
        current.hasFocus = false
    }

    private fun stop(onStopped: ((Boolean) -> Unit)? = null) {
        wantsAudio = false
        requestedId = null
        val token = generation.incrementAndGet()
        playbackHandler.post {
            val previous = session
            retryReleases()
            release(previous)
            session = null
            val released = unreleasedPlayers.isEmpty()
            lastState = stoppedState(previous?.requestId ?: 0, previous?.trackId).let {
                if (released) it else it + mapOf("status" to "error", "errorCode" to "release_failed")
            }
            publish(token)
            if (onStopped != null) mainHandler.post { onStopped(released) }
        }
    }

    private fun fail(current: Session, errorCode: String) {
        if (!isCurrent(current)) { release(current); return }
        current.wantsPlayback = false
        current.errorCode = errorCode
        current.status = "error"
        release(current)
        publish()
    }

    private fun release(current: Session?) {
        if (current == null) return
        current.timeout?.let(playbackHandler::removeCallbacks)
        current.timeout = null
        stopTicker(current)
        abandonFocus(current)
        val player = current.player
        if (current.prepared && current.status == "playing") {
            try { player?.pause() } catch (_: RuntimeException) { }
        }
        current.player = null
        current.prepared = false
        current.seeking = false
        current.queuedSeek = null
        // release() is valid while preparing; stop() is not.
        if (player != null) {
            try { player.release() } catch (_: RuntimeException) { unreleasedPlayers.add(player) }
        }
    }

    private fun retryReleases() {
        for (player in unreleasedPlayers.toList()) {
            try { player.release(); unreleasedPlayers.remove(player) } catch (_: RuntimeException) { }
        }
    }

    private fun startTicker(current: Session) {
        stopTicker(current)
        val ticker = object : Runnable {
            override fun run() {
                if (!isCurrent(current) || current.status != "playing") return
                readPosition(current)
                publish()
                playbackHandler.postDelayed(this, 500)
            }
        }
        current.ticker = ticker
        playbackHandler.postDelayed(ticker, 500)
    }

    private fun stopTicker(current: Session) {
        current.ticker?.let(playbackHandler::removeCallbacks)
        current.ticker = null
    }

    private fun readPosition(current: Session) {
        if (!current.prepared) return
        try { current.positionMs = (current.player?.currentPosition ?: 0).toLong().coerceAtLeast(0) }
        catch (_: RuntimeException) { /* Preserve the last valid position. */ }
    }

    private fun isCurrent(current: Session, player: MediaPlayer? = current.player): Boolean =
        !disposed && session === current && current.generation == generation.get() && current.player === player

    private fun state(current: Session): Map<String, Any?> = mapOf(
        "requestId" to current.requestId, "trackId" to current.trackId,
        "status" to current.status, "positionMs" to current.positionMs,
        "durationMs" to current.durationMs, "errorCode" to current.errorCode,
    )

    private fun publish(token: Long = generation.get()) {
        val value = session?.let(::state) ?: lastState
        lastState = value
        mainHandler.post {
            if (!disposed && token == generation.get()) eventSink?.success(value)
        }
    }

    private fun stoppedState(requestId: Long = 0, trackId: String? = null): Map<String, Any?> = mapOf(
        "requestId" to requestId, "trackId" to trackId, "status" to "stopped",
        "positionMs" to 0L, "durationMs" to 0L, "errorCode" to null,
    )

    private inner class PendingReply(private val result: MethodChannel.Result) {
        private var completed = false
        init { pendingReplies.add(this) }
        fun success(value: Any?) {
            if (completed) return
            completed = true
            pendingReplies.remove(this)
            result.success(value)
        }
        fun error(code: String) {
            if (completed) return
            completed = true
            pendingReplies.remove(this)
            result.error(code, "Audio preview is unavailable.", null)
        }
    }

    private class InvalidSourceException : Exception()
}
