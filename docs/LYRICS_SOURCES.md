# Lyrics sources and network behavior

Source reads verified 2026-10-02; NetEase song-detail metadata verified 2026-10-03. Audio Fixer retrieves public metadata, cover art and lyrics only. It does not upload local audio, download music, impersonate browsers, use login cookies, rotate identities, solve source challenges, or bypass access restrictions.

## LRCLIB

Official documentation: <https://lrclib.net/docs>

The published API supports `/api/get` and `/api/search`, requires an identifying client header, sequential requests with a 200–500 ms gap, and honoring `Retry-After` on 429 responses. Audio Fixer identifies itself with its project URL and leaves 400 ms after completion before another request to the same provider. Title, artist, album and known duration are checked locally; title-only matches and equal-evidence conflicting lyric texts are rejected.

The current Lyricsfile draft <https://github.com/tranxuanthang/lyricsfile/blob/main/SPECIFICATION.md> does not define a translation field. Audio Fixer does not invent one or label a plain lyric as translated.

## NetEase Cloud Music: experimental anonymous source

Direct public read endpoints observed working without authentication:

- `https://music.163.com/api/search/get?s=<title artist>&type=1&limit=20&offset=0`
- `https://music.163.com/api/song/detail?ids=[<matched id>]`
- `https://music.163.com/api/song/lyric?id=<matched id>&lv=-1&tv=-1`
- Song provenance: `https://music.163.com/song?id=<matched id>`

This is **not** the official authenticated OpenAPI, and is not a promised stable service. The UI labels it “网易云音乐（实验性）”. The official developer route described at <https://github.com/NetEase/skills> requires developer registration, appId/privateKey and authorization; those credentials are not bundled or requested by this app.

During low-volume verification, searching 红豆 / 王菲 returned recording IDs 299936, 299757 and 298986 with distinct album/duration metadata. A lyric read returned both `lrc.lyric` and `tlyric.lyric`; a Chinese original's translation field contained only empty timestamps, demonstrating why field presence alone cannot mean a translation exists. Searching Yesterday / The Beatles returned distinct remastered and 2023-mix recordings, demonstrating why version markers must not be discarded. A final live test through the production Dart adapter matched 红豆 to 299936 (872 original characters, no usable translation); a direct read for Yesterday (Remastered), ID 4337372, returned 938 original and 409 Chinese-translation characters. No complete copyrighted lyrics were retained in repository fixtures. Production matching requires title and primary/joined artist identity plus duration within three seconds when known. Without a duration, an exact album is required. Equal-evidence different song IDs are rejected, and at most one lyric read follows each search.

The same adapter also supplies title, full artist credit, album and cover candidates. Metadata/cover requests fetch exactly one detail record for the selected ID and recheck ID, title, all artist credits, duration and the search result's album identity before offering fields. An observed detail read for ID 299936 returned 红豆 / 王菲 / 唱游, duration 256026 ms, and an album `picUrl` on `p1.music.126.net`. No composer, lyricist, year or other extended credit is inferred from album publication dates or unrelated fields. The class retains its original `NeteaseLyricsSource` name for compatibility.

Only requested endpoints are read: metadata/cover-only queries never request lyrics, and lyric-only queries never request detail or image bytes. Cover candidates must be HTTPS URLs on the exact hosts `p1.music.126.net`, `p2.music.126.net`, `p3.music.126.net`, or `p4.music.126.net`, with port 443, no credentials/query/fragment, and a static `/<asset key>/<numeric image ID>.jpg|jpeg|png` path. HTTP URLs are rejected, not upgraded. Every image-download redirect must pass the same trusted-address validation; image format and the 10 MiB byte limit are checked before use. A returned URL alone does not establish that its image download will succeed.

If one requested endpoint yields no lyrics, independently verified metadata remains available. If a detail payload fails local identity/format checks or lyrics fail after metadata verification, available fields remain reviewable with an explicit source warning; unmatched detail values are never used as fallback. Access denial, provider failure codes and active cooldowns stop further provider requests. The shared client applies its normal deduplication, cache and throttling to the detail endpoint as well.

Primary access/terms references reviewed:

- <https://music.163.com/robots.txt>: the generic user-agent section disallowed a gift-receive page at verification; training crawler rules are separate. This is not a license grant.
- <https://music.163.com/html/web2/service.html>: general software/service restrictions include unauthorized copying and derivative/interoperable services. Applicability to anonymous public reads is not documented by the endpoint. Successful responses do **not** establish an official license, guarantee, or commercial redistribution right.
- <https://developer.music.163.com/st/developer/>: official developer platform. A supported commercial integration should obtain the provider's required authorization and applicable rights.

If anonymous access is denied or the format changes, the source surfaces an error and other providers remain usable. There is no login, proxy, signature spoofing, DRM, or alternate-endpoint bypass. No Sogou API was implemented because no current primary-source lyrics API contract was verified.

## Chinese translation

“附加中文翻译” defaults on, can be turned off in Settings, and can be overridden per lyric candidate before approval/export/save. Provider-supplied Chinese translation is preferred. When no provider translation is available, users can enable Google Translate / ML Kit on-device machine translation. No whole lyric is sent to a cloud translation service, no paid translator is configured, and translation coverage/quality is not guaranteed.

Original and translation are stored separately in candidate records and previewed separately with provider attribution. Timestamp-only, empty, placeholder, identical, or non-Chinese translation payloads are not called translated. Missing translation is visibly reported; the original remains available. Chinese-dominant originals are identified conservatively (kana/Hangul exclude that classification).

When both languages have compatible LRC offsets, saving interleaves the provider's exact timestamps, labels Chinese lines `【中文】`, and never aligns by row number or manufactures time values. Untimed lyrics use separately labeled original/translation sections. Conflicting LRC offset tags disable translated saving with an explicit preview-only warning, preserving the original unchanged rather than silently shifting either timeline. Ordinary missing-field completion does not overwrite existing lyrics; explicit tag repair requires reviewing and approving a replacement separately.

## On-device machine translation fallback

The global Chinese-translation preference defaults on. SDK activation is separately opt-in: first use explains Google's SDK data collection; each model download requires a separate user action listing the required languages and approximate size. English is built into ML Kit, so English→Chinese downloads the Chinese model only; other supported languages generally need the source and Chinese models, around 30 MB each. Downloads require Wi-Fi. An authorized OS-managed download can finish after leaving the screen or after a timeout because the SDK provides no cancellation API. Failure never turns into a cloud translation or repeated automatic download.

- SDK: `com.google.mlkit:translate:17.0.3`; bundled `com.google.mlkit:language-id:17.0.6` (about 900 KB), Android API 23+. The app's existing minimum is API 24.
- Official APIs: <https://developers.google.com/ml-kit/language/translation/android> and <https://developers.google.com/ml-kit/language/identification/android>
- Supported lazy initialization: <https://developers.google.com/android/reference/com/google/mlkit/common/MlKit>. The default ML Kit provider is removed as documented and the public `MlKit.initialize` runs only on an opted-in SDK channel operation. Viewing help links does not initialize ML Kit.
- Privacy: <https://developers.google.com/ml-kit/terms> and <https://developers.google.com/ml-kit/android-data-disclosure>. Input/output text is processed on-device. The SDK sends device/application information, installation identifiers, language configuration, performance/usage and feature-size metrics to Google. Enabling this SDK does not mean zero network traffic; the app describes that distinction before activation and in Settings.
- Model storage/install behavior: <https://developers.google.com/ml-kit/tips/installation-paths>. Models live in app-specific storage and require initial connectivity; subsequent supported inference can run offline. Availability on a specific physical device/network is not guaranteed by a mock test.
- Quality: <https://developers.google.com/ml-kit/language/translation>. Models target casual/simple translation. Non-English pairs can route through English; lyrics, metaphor and mixed-language material require human review.
- Attribution: <https://developers.google.com/ml-kit/language/translation/translation-terms> and <https://docs.cloud.google.com/translate/attribution>. The unchanged official badge is bundled for offline display, alongside machine translation; provenance is in `assets/google_translate/README.md`. Actions are attributed to Google Translate, and Settings/candidate views provide the disclaimer and help links. No Google endorsement is implied.

The SDK and models are governed by ML Kit/Google API terms, rather than the Apache license of code samples. Integration uses normal Gradle dependencies and implicit SDK terms; it does not create an account, API key, billing plan, or accept a separate explicit agreement dialog.

Automatic fallback uses already-downloaded models only, after opt-in, and preserves provider translations in preference to machine output. Source lyrics, machine-translation provenance and output are stored separately. The translation service identifies the source language, rejects uncertain/unsupported input and enhanced word-timed LRC it cannot preserve, translates unique text rows locally, and retains exact original LRC stamps/offsets. Additional translated line breaks are reported as untimed continuation lines rather than assigned fabricated times. Machine output is clearly labeled in both preview and saved lyric text. Global/per-song opt-out remains available; existing approved payloads are not silently rewritten.

Translation work is deduplicated and cached privately by exact input/engine signature, bounded to 256 results and 4 MiB. Missing-model/error states are not cached as successful translations. On model-download success the candidate is queried again into a new review step; nothing is automatically saved.

## Request budget and local cache

The production client is constructed once and uses the app-private `source-cache` directory. Exact URI responses are deduplicated while in flight and cached (24 hours for success; 10 minutes for 404/empty search). Cache is bounded to 256 entries and 4 MiB. Query punctuation and precise durations remain part of request identity. The cache stores public JSON and query metadata, never audio bytes, cookies or credentials.

Requests are serialized per provider. MusicBrainz and NetEase have a conservative 1.1-second completion gap; other providers use 400 ms. Independent providers do not block each other. Redirects enter the destination host's queue and remain restricted to the allowlist. 429/503 (including NetEase JSON status), transient failures and Retry-After trigger cooldown/backoff; no automatic retry loops exist. Cooldowns persist across restarts. Repeating a query or connection check reuses cached data and cannot bypass cooldown. A connection-check cache hit establishes recent availability rather than forcing new traffic.

## Verification

Unit tests use synthetic lyrics (no copyrighted songs are checked into fixtures):

- `http_json_api_client_test.dart`: identical-request coalescing, host separation, completion spacing, restart persistence, TTL and cache bounds, 404/empty handling, Retry-After dates/seconds, backoff, malformed values, redirects and denial
- `netease_lyrics_source_test.dart`: exact Chinese matching, wrong artist/version/duration, missing identity, ambiguity, placeholders, denied anonymous access, default bilingual rendering and opt-out
- `lyrics_content_test.dart`: distinct language data, timestamp preservation, offset mismatch, availability and approved-rendering integrity
- `lyrics_translation_ui_test.dart`: preview opt-out exports exact original-only content; old settings migrate default-on
- `lyrics_translation_service_test.dart`: native-channel contract, no automatic downloads, missing/unsupported states, LRC integrity, in-flight deduplication and restart cache bounds
- `on_device_translation_flow_test.dart`: no SDK calls before opt-in or after opt-out, provider priority, actual download consent and review-only machine candidates
- `track_search_test.dart`: Chinese filename separators and existing identity protections

Network verification is intentionally small; it is not a catalog-coverage benchmark. Endpoint uptime, every song's translation, physical-device networks, and provider rights are not guaranteed by these tests.
