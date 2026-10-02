# Lyrics sources and network behavior

Verified 2026-10-02. Audio Fixer retrieves public metadata and lyrics only. It does not upload local audio, download music, impersonate browsers, use login cookies, rotate identities, solve source challenges, or bypass access restrictions.

## LRCLIB

Official documentation: <https://lrclib.net/docs>

The published API supports `/api/get` and `/api/search`, requires an identifying client header, sequential requests with a 200–500 ms gap, and honoring `Retry-After` on 429 responses. Audio Fixer identifies itself with its project URL and leaves 400 ms after completion before another request to the same provider. Title, artist, album and known duration are checked locally; title-only matches and equal-evidence conflicting lyric texts are rejected.

The current Lyricsfile draft <https://github.com/tranxuanthang/lyricsfile/blob/main/SPECIFICATION.md> does not define a translation field. Audio Fixer does not invent one or label a plain lyric as translated.

## NetEase Cloud Music: experimental anonymous source

Direct public read endpoints observed working without authentication:

- `https://music.163.com/api/search/get?s=<title artist>&type=1&limit=20&offset=0`
- `https://music.163.com/api/song/lyric?id=<matched id>&lv=-1&tv=-1`
- Song provenance: `https://music.163.com/song?id=<matched id>`

This is **not** the official authenticated OpenAPI, and is not a promised stable service. The UI labels it “网易云音乐（实验性）”. The official developer route described at <https://github.com/NetEase/skills> requires developer registration, appId/privateKey and authorization; those credentials are not bundled or requested by this app.

During low-volume verification, searching 红豆 / 王菲 returned recording IDs 299936, 299757 and 298986 with distinct album/duration metadata. A lyric read returned both `lrc.lyric` and `tlyric.lyric`; a Chinese original's translation field contained only empty timestamps, demonstrating why field presence alone cannot mean a translation exists. Searching Yesterday / The Beatles returned distinct remastered and 2023-mix recordings, demonstrating why version markers must not be discarded. A final live test through the production Dart adapter matched 红豆 to 299936 (872 original characters, no usable translation); a direct read for Yesterday (Remastered), ID 4337372, returned 938 original and 409 Chinese-translation characters. No complete copyrighted lyrics were retained in repository fixtures. Production matching requires title and primary/joined artist identity plus duration within three seconds when known. Without a duration, an exact album is required. Equal-evidence different song IDs are rejected, and at most one lyric read follows each search.

Primary access/terms references reviewed:

- <https://music.163.com/robots.txt>: the generic user-agent section disallowed a gift-receive page at verification; training crawler rules are separate. This is not a license grant.
- <https://music.163.com/html/web2/service.html>: general software/service restrictions include unauthorized copying and derivative/interoperable services. Applicability to anonymous public reads is not documented by the endpoint. Successful responses do **not** establish an official license, guarantee, or commercial redistribution right.
- <https://developer.music.163.com/st/developer/>: official developer platform. A supported commercial integration should obtain the provider's required authorization and applicable rights.

If anonymous access is denied or the format changes, the source surfaces an error and other providers remain usable. There is no login, proxy, signature spoofing, DRM, or alternate-endpoint bypass. No Sogou API was implemented because no current primary-source lyrics API contract was verified.

## Chinese translation

“附加中文翻译” defaults on, can be turned off in Settings, and can be overridden per lyric candidate before approval/export/save. Only provider-supplied Chinese translation is currently supported. No whole lyric is sent to a machine-translation service, no paid translator is configured, and translation coverage is not guaranteed.

Original and translation are stored separately in candidate records and previewed separately with provider attribution. Timestamp-only, empty, placeholder, identical, or non-Chinese translation payloads are not called translated. Missing translation is visibly reported; the original remains available. Chinese-dominant originals are identified conservatively (kana/Hangul exclude that classification).

When both languages have compatible LRC offsets, saving interleaves the provider's exact timestamps, labels Chinese lines `【中文】`, and never aligns by row number or manufactures time values. Untimed lyrics use separately labeled original/translation sections. Conflicting LRC offset tags disable translated saving with an explicit preview-only warning, preserving the original unchanged rather than silently shifting either timeline. Existing audio lyrics are never overwritten by this feature.

## Request budget and local cache

The production client is constructed once and uses the app-private `source-cache` directory. Exact URI responses are deduplicated while in flight and cached (24 hours for success; 10 minutes for 404/empty search). Cache is bounded to 256 entries and 4 MiB. Query punctuation and precise durations remain part of request identity. The cache stores public JSON and query metadata, never audio bytes, cookies or credentials.

Requests are serialized per provider. MusicBrainz and NetEase have a conservative 1.1-second completion gap; other providers use 400 ms. Independent providers do not block each other. Redirects enter the destination host's queue and remain restricted to the allowlist. 429/503 (including NetEase JSON status), transient failures and Retry-After trigger cooldown/backoff; no automatic retry loops exist. Cooldowns persist across restarts. Repeating a query or connection check reuses cached data and cannot bypass cooldown. A connection-check cache hit establishes recent availability rather than forcing new traffic.

## Verification

Unit tests use synthetic lyrics (no copyrighted songs are checked into fixtures):

- `http_json_api_client_test.dart`: identical-request coalescing, host separation, completion spacing, restart persistence, TTL and cache bounds, 404/empty handling, Retry-After dates/seconds, backoff, malformed values, redirects and denial
- `netease_lyrics_source_test.dart`: exact Chinese matching, wrong artist/version/duration, missing identity, ambiguity, placeholders, denied anonymous access, default bilingual rendering and opt-out
- `lyrics_content_test.dart`: distinct language data, timestamp preservation, offset mismatch, availability and approved-rendering integrity
- `lyrics_translation_ui_test.dart`: preview opt-out exports exact original-only content; old settings migrate default-on
- `track_search_test.dart`: Chinese filename separators and existing identity protections

Network verification is intentionally small; it is not a catalog-coverage benchmark. Endpoint uptime, every song's translation, physical-device networks, and provider rights are not guaranteed by these tests.
