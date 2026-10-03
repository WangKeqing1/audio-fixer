# Local audio preview bridge

The Android preview uses the platform `MediaPlayer` on a dedicated
`HandlerThread`. It adds no SDK dependency, manifest permission, service,
notification or network playback path.

## Flutter contract

MethodChannel: `audio_fixer/audio_preview`

- `play({requestId, trackId, uri})`: `requestId` is a positive integer. A new
  request replaces the active item. The same request, track and URI explicitly
  resumes a paused player or restarts a completed player from zero.
- `pause({requestId})`: pauses that request, including disabling the pending
  start while preparation is in progress. A stale request is ignored.
- `seek({requestId, positionMs})`: seeks that request within its duration.
  Requests during preparation are deferred; rapid seeks retain the latest
  target. Seeking a paused item does not start playback.
- `stop()`: invalidates pending playback immediately and completes only after
  releasing the player. A `release_failed` error means a caller must not proceed
  with a write. An uncertain player is retained for subsequent cleanup attempts
  and prevents another player starting until release succeeds.
- `getState()`: reads a snapshot after earlier queued playback commands.

Play, pause and seek acknowledge command acceptance promptly. Their completion
is reported through EventChannel `audio_fixer/audio_preview_events`. Events and
`getState()` use the same map:

```text
requestId: integer (0 when nothing has been selected)
trackId: string or null
status: loading | playing | paused | completed | error | stopped
positionMs: integer
durationMs: integer (0 while unknown)
errorCode: string or null
```

Position events occur every 500 ms while playing. Error codes include
`invalid_source`, `source_unavailable`, `permission_denied`,
`unsupported_format`, `audio_focus_denied`, `preparation_timeout`,
`playback_failed` and `release_failed`. Invalid command arguments, background
play requests and a disposed bridge return MethodChannel errors. Raw exception
messages, file paths and audio contents are never included in events or logs.

## Playback and write boundaries

Only `content://media/<volume>/audio/media/<id>` and canonical files under the
application's private data directory are accepted. The latter includes existing
imports under `app_flutter`. Files and MediaStore entries are opened read-only
and passed as file descriptors; the bridge never asks MediaPlayer to load a URL.

Each replacement/stop invalidates the prior generation. Player, seek, focus and
prepare callbacks from old sessions cannot start playback or update current
state. A preparation timeout releases the decoder. Playback requests require
the Activity to be resumed; Activity pause, engine cleanup, Activity destruction
and cancellation of the event listener release playback. Returning to the app
does not resume it automatically.

Audio focus must be granted before starting. Permanent/transient focus loss,
duck requests and headphone disconnection pause playback. Focus returning does
not resume it. Focus is abandoned on pause, completion and release.

The Dart controllers share a backend-scoped command queue, event subscription,
monotonic request IDs, release obligation and write lock. Recreating the library
still waits for a previous player's release; disposing an old controller cannot
cancel the new controller's listener or playback. The lock prevents new play
requests and awaits native `stop()` before original save, restore or recovery. Raw native
write/recovery channels do not independently acquire that lock. An integration
test using those channels directly must explicitly await `stop()` first; that
alone does not prove the controller's automatic barrier.

## Verification

The Kotlin compile checks API and type compatibility; it does not prove device
decoding, audio focus delivery or audible output. Native integration tests use
synthetic fixtures for playback, seek, replacement, private-file and MediaStore
sources, interrupted preparation, lifecycle stop and the release/write barrier.
Headset routing and audio focus interruptions additionally need device evidence.

Implementation references:

- [MediaPlayer state and resource management](https://developer.android.com/media/platform/mediaplayer/state-resources)
- [Audio focus](https://developer.android.com/media/optimize/audio-focus)
- [MediaPlayer API](https://developer.android.com/reference/android/media/MediaPlayer)
