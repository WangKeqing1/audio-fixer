# NetEase selected-recording regression

Verified 2026-10-04 using anonymous public metadata endpoints, the production
`HttpJsonApiClient` and `NeteaseLyricsSource`. No authentication, audio upload,
audio download, bulk library inventory or access workaround was used. Live
verification requested metadata only; automated lyric fixtures are synthetic.

## What failed

The screenshot's “未找到匹配” was emitted after a recording had already been
selected. `lookupConfirmed` grouped malformed detail, changed provider identity,
and changed query conditions into one `SourceNoMatch` message.

For 我从草原来, the public search and detail both contain the same recording:

- [354682](https://music.163.com/song?id=354682)
- Title: 我从草原来
- Full artist: 凤凰传奇
- Album: 我从草原来 新歌+精选, album ID 35000
- Duration: 220115 ms

Both actual endpoints use `artists`, `album` and `duration`. An `ar` / `al` /
`dt` schema mismatch was investigated and was **not** observed.

The original artist tag `006.凤凰传奇` was being reapplied when confirming a
candidate found with the filename-derived artist `凤凰传奇`. The provider detail
was consistent; the query's artist check failed. The controller must preserve
the discovery query through selection and retries, instead of replacing it with
the original tags.

## Adapter and query changes

- A zero-padded artist index may be excluded from a query only when the full
  filename independently corroborates both the remaining artist and title.
  This remains an inferred hint requiring recording choice; source tags are
  unchanged. Numeric artist names and conflicting filenames remain intact.
- A complete album download-promotion string with an explicit domain and the
  unambiguous “更多音乐全集下载” form is ignored as a query hint. Ordinary albums,
  bracketed editions and website names alone are preserved.
- Empty selected-ID results report that the selected ID has no returned detail.
  Incomplete/malformed detail is `invalidResponse`; provider errors retain their
  existing transport classification.
- Changed selected ID/title/full artist/album/exact duration is
  `identityConflict`, displayed as “录音信息不一致”. Query-condition conflicts
  separately explain that the returned detail itself is consistent.
- No lyric request follows a failed selected-recording verification. No search
  fallback, automatic recording switch, field approval or file write is added.
- A missing album in a search candidate can be supplied by the same ID's detail
  only after the other selected identity fields agree exactly. An existing
  chosen album must still match; missing detail for that album fails closed.

## Live verification results

The production adapter discovered and explicitly verified these public IDs:

| ID | Artist | Album | Duration | Verified metadata |
| --- | --- | --- | --- | --- |
| 354682 | 凤凰传奇 | 我从草原来 新歌+精选 | 220115 ms | title, artist, album, album artist, 2010, track 1, trusted cover URL |
| [32235934](https://music.163.com/song?id=32235934) | μ's | μ's Best Album Best Live! Collection Ⅱ | 247866 ms | title, artist, album, album artist, 2015, track 3, trusted cover URL |
| [437605605](https://music.163.com/song?id=437605605) | 流田Project | 流's the COVER | 252173 ms | title, artist, album, album artist, 2016, track 6, trusted cover URL |

The latter two share the title きっと青春が聞こえる and both fall within the existing
three-second discovery tolerance for 249443 ms. This does not identify which
recording the local audio is; the user still selects one. Their live search and
detail identity values agree exactly. A returned cover URL is not an image
byte-download verification. No live lyric availability or physical-device
interaction is claimed by this check.

## Regression commands

```sh
flutter test test/netease_identity_regression_test.dart \
  test/netease_recording_discovery_test.dart test/netease_lyrics_source_test.dart \
  test/netease_extended_metadata_test.dart test/track_search_test.dart
flutter test test/source_query_status_ui_test.dart \
  test/source_query_reporting_test.dart test/http_json_api_client_test.dart
```

These groups passed 75 and 73 tests respectively. Identity regression fixtures
retain the observed metadata field shapes and values, covering the three IDs,
absent/incomplete detail, provider failure, exact 1-ms duration changes, full
credit/title/album conflicts, source provenance and no-lyrics-on-conflict.

## Subsequent live lyric acceptance

A bounded follow-through on 2026-10-04 at application commit `1b3f303`
requested only lyrics through the production adapter for the same explicitly
selected IDs. Each made exactly one selected-ID detail call followed by one
lyric call; all six responses had provider code 200.

- 354682: usable original LRC, 990 characters; Chinese-dominant original with
  no separate usable translation
- 32235934: usable original LRC, 921 characters, and provider Chinese LRC,
  765 characters
- 437605605: usable original LRC, 835 characters, and provider Chinese LRC,
  729 characters

Both translations passed the existing inclusion/offset checks. Every result
retained the selected ID as its provenance. No lyric text was printed or
stored in the evidence; only status, format, counts and public endpoint paths
were recorded. This verifies provider availability at that time, not the
identity of any local audio, a future availability guarantee, or a completed
write to the user's file. The later CI-driver commit did not change app sources.
