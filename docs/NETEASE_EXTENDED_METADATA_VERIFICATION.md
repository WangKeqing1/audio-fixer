# NetEase extended metadata verification

Verified on 2026-10-03 using anonymous, read-only HTTPS requests. This is an
experimental public endpoint, not a supported OpenAPI contract or a guarantee
of catalog coverage or redistribution rights.

## Verified detail fields

The existing request
`https://music.163.com/api/song/detail?ids=%5B299936%5D` returned HTTP 200 and
JSON `code: 200`. The selected song was 红豆 / 王菲 / 唱游, song ID `299936`,
album ID `29725`, duration `256026` milliseconds.

Relevant actual response fields:

| Field | Observed value | Adapter treatment |
| --- | --- | --- |
| `album.artists` | One credit, 王菲 (`id: 9621`) | Full album artist credit |
| `album.artist` | Empty name and `id: 0` | Not used as a fallback |
| `album.publishTime` | `907257600000` | Album release year 1998 |
| `no` | `9` | This song's explicit track number |
| `position` | `9` | Not substituted for `no` |
| `disc` | `"1"` | Not offered without verified album context |
| `album.size` | `13` | Only a consistency bound; not a per-disc track total |
| `album.songs` | Empty array | Does not prove full album membership or disc count |

The adapter rechecks the selected song's ID, title, all track artist credits,
duration and album identity against the search result before offering any
detail fields. Extended fields additionally require a positive album ID and
nonempty album name. Album artists come only from a complete nonempty
`album.artists` list; song artist credits are never copied into album artist.
Different equally matched song IDs produce a visible ambiguity warning when
extended album fields are requested.

The year is the selected album's release year, not an inferred original
recording year. Its evidence includes the exact provider `publishTime`
milliseconds. Zero, malformed and out-of-range timestamps are rejected;
negative timestamps can represent valid releases before 1970. Because the
anonymous response does not establish a release-date timezone, timestamps
whose year can change across UTC−12 through UTC+14 are left unresolved with
a warning. No year is guessed from lyrics, a song name or a search snippet.

Track numbers must be positive integers within the writable 1–65535 range.
When a positive integer `album.size` is supplied, a larger track number is
rejected as contradictory. No default track or disc number is manufactured.
Invalid requested fields leave independently verified candidates reviewable
with an explicit warning. Missing fields are omitted.

## Unverified album scope

One exploratory full-album read to
`https://music.163.com/api/album/29725` returned JSON code `-462`. That route
was stopped and was not added to the production URL allowlist. No login,
cookie, browser impersonation, alternate album endpoint, proxy bypass or
retry was used to obtain that album response.

Track totals, disc numbers and disc totals therefore remain unsupported by
this adapter. Genre, composer and freeform comments also remain unsupported:
the inspected detail provides no verified field mapping for them. A lyricist
credit is not a composer credit, and `equalizers` is not a genre field.

## Live adapter result and request budget

A metadata-only query of 红豆 / 王菲 / 唱游 with duration 256026 ms used the
production `NeteaseLyricsSource` and `HttpJsonApiClient`, with a curl transport
that preserved the production User-Agent and Accept headers for this cloud
executor's network. The adapter independently searched and read the existing
song-detail endpoint. Both returned HTTP 200, producing seven candidates:

- Title: 红豆
- Artist: 王菲
- Album: 唱游
- Album artist: 王菲
- Year: 1998
- Track number: 9
- Cover: the provider's validated HTTPS static image URL

Every candidate retained
`https://music.163.com/song?id=299936` as its source. The first lookup issued
two network requests; repeating it returned the same seven candidates with
the total request count still two. No lyrics, image bytes or audio were
downloaded during this check. The new fields introduce no additional endpoint
or request: metadata-only remains search plus one detail, while a requested
lyric adds at most the existing lyric read. The shared bounded HTTP cache,
deduplication, source throttling and cooldown rules continue to apply.

Focused regression tests are in `test/netease_extended_metadata_test.dart`.
They cover album attribution, missing or malformed credits, invalid/zero and
pre-1970 dates, cross-year timezone ambiguity, album identity mismatch,
ambiguous recordings, track number bounds, unsupported fields, request scope
and exact-request cache reuse. Fixtures contain synthetic identities and no
copyrighted lyrics.
