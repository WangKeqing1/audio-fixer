# Title-only recording discovery

A missing artist used to make the NetEase and LRCLIB adapters return before any HTTP request. A song existing at a provider could therefore be reported as having no information. The normal identity matcher is intentionally still strict; the app now uses a separate recording-choice step when artist metadata is absent.

The automatic repair flow reads one NetEase title search page, checks exact title or provider-supplied alias plus version and duration evidence, and displays at most five possible recordings. No candidate is selected automatically, including the one with the smallest duration difference. The choice is persisted independently of field suggestions and approvals. The user must confirm an artist/album version, then separately review the retrieved fields before saving.

Confirmed lookup fetches only the selected provider ID. It revalidates title, complete artist credit, album and exact provider duration against the stored choice, and checks the original local title/duration evidence. If a title was matched through a provider alias, the detail must still supply that alias; otherwise lookup declines without fetching lyrics. Metadata, cover and lyrics retain the same source URL. An unrelated source is not used to silently fill fields from another edition.

Current failed-query and translation retries keep the selected ID. A stale or already-saved task starts a fresh query and discards the old choice. Adjusted query terms and selected fields remain intact when rediscovering from a current version-choice page. Cancellation, duplicate taps, newer routes, exclusions and changed tasks cannot approve fields or start a stale choice.

## Public live reproduction

Verified on 2026-10-03 using the public query 極楽浄土, no artist/album, and duration 218.828 seconds. No file comments, private provider keys, audio bytes or inventory were sent.

The old production adapters made zero requests for NetEase and LRCLIB. Independent public title-only reads succeeded: NetEase reported 302 results, returning 20 on the first page; LRCLIB returned 20 results. The MusicBrainz production query received HTTP 200 HTML “Site Unavailable” in this cloud environment, correctly surfaced as a response-format error rather than a successful no-match.

The new production NetEase adapter retained five choices from that first page: 14 were rejected by title/version and one by duration. The choices had song IDs 411907897, 1311758713, 446875490, 1407263626 and 1453972379. Several GARNiDELiA releases have nearly identical durations, so this is evidence of discoverable choices, not evidence of which album any local file belongs to.

For this probe only, the test explicitly selected [recording 411907897](https://music.163.com/song?id=411907897). The adapter then requested only that ID's detail and lyric endpoints. It returned eight fields: title, artist, album, album artist, year, track number, cover URL and lyrics. All fields retained that recording's source URL. Lyrics were 989 characters; their contents were not printed or committed. A returned cover URL is not proof of a successful image-byte download.

The live Dart probe used the existing curl-backed transport to pass the cloud's network boundary after direct Dart networking timed out. The shipped Android app still uses its normal HTTP client, not curl. This probe verifies parsing, request selection and provenance, not installed Android runtime behavior.

## Regression coverage

Tests cover bounded title-only requests, no implicit choice or field fetch, exact and alias/version matching, missing alias evidence, malformed/conflicting IDs, source failures, cache/cooldown, selected-ID exclusivity, task persistence, stale/forged choices, batch discovery, instrumental scope, translation retry, changed-query preservation, cancellation, repeated taps, late routes and narrow/large-text layouts. Fixtures contain synthetic data and no raw user inventory or private comments.
