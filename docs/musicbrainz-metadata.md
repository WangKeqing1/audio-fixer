# MusicBrainz extended metadata

The adapter advertises fields it knows how to query, not fields guaranteed to
exist for every song. It never invents a genre, composer, date, edition, or
sequence number. Comment is intentionally unsupported: a provider annotation
or recording disambiguation is not the user's file comment.

## Fields and evidence

| Field | Actual provider evidence |
| --- | --- |
| Album artist | The complete release artist-credit phrase, including join phrases |
| Year | A valid release date's year; never the recording's first-release-date |
| Genre | Positive-voted names in `genres`, first on the exact recording, then on verified releases; free-form tags and artist genres are not used |
| Track number | `position` of the exact recording's track in its medium; printed vinyl numbers such as B2 are not parsed as integers |
| Track total | `track-count` of that medium, not the sum across discs |
| Disc number | The containing medium's `position` |
| Disc total | The complete release's medium count |
| Composer | Recording performance → work → backward composer relationship, using `target-credit` where supplied, otherwise the linked artist's name |

A lyricist, writer, arranger, performer, or direct recording artist relationship
is not substituted for a composer relationship. A medley with a missing work's
composer credits supplies no partial composer list.

## Identity and editions

Recording search still requires exact normalized title, primary artist credit
or provider-supplied primary artist alias, and known duration within five
seconds. Featured artist names or aliases alone are insufficient. Distinct
recording identities remain ambiguous. Explicit version qualifiers in titles
are retained; common variants in recording disambiguation (live, acoustic,
instrumental, karaoke, remix, demo) cannot silently identify a plain title.

Extended release fields use a browse by the matched recording ID, requesting
complete tracklists. When the local album is known, only its exact normalized
title is considered. Without a local album, all returned releases must identify
one album. Editions must belong to one release group and have the same album
title; a single concrete release is also sufficient. Every selected release
must actually contain the matched recording with compatible title, primary
artist, and duration. Unrelated album releases do not supply metadata.

Each field must be present and identical in every surviving edition. Conflicting
years do not suppress an independently consistent album artist. No earliest,
first, official-status-ranked, or UUID-ranked edition is selected. A repeated
recording on a release has unknown sequence numbers. Incomplete or inconsistent
tracklists cannot supply sequence numbers or totals.

The existing album/cover match also no longer arbitrarily chooses an edition
from multiple candidates: a shared album identity may provide the album name
and release-group cover path, with no concrete release selected.

## Requests and failure handling

- Core-only lookup performs the existing shared recording search
- Genre/composer add at most one recording detail request with
  `artist-credits genres work-rels work-level-rels artist-rels`
- Release fields, or genre fallback, add at most three release browse requests
  with `recordings artist-credits release-groups genres`, `recording=<MBID>`,
  `limit=100`, and offsets advanced by the actual response length
- MusicBrainz caps browse responses by track volume, so a page may contain fewer
  releases than its requested limit. All pages must be observed before release
  field consensus is usable. Changed totals, repeated editions, malformed
  offsets, or unobserved pages cannot establish consensus
- Three-page exhaustion reports explicitly that edition data remains uncertain
- All requests go through the shared JsonApiClient, preserving the existing
  bounded HTTP cache, in-flight deduplication, cooldown, and 1.1-second
  MusicBrainz inter-request delay
- A 40-second adapter budget starts before search and ends before the caller's
  45-second limit. Each added request needs 14 seconds remaining. Endpoint
  waits use the remaining budget. Timeouts and endpoint failures preserve
  verified independent suggestions through PartialSourceException
- JsonApiClient cannot cancel an already queued/in-flight request. A budget
  failure prevents this adapter from starting any further endpoint or page

## Verification

Focused tests cover all eight extended fields, provenance, multiple editions,
multidisc totals, wrong albums/recordings, primary and guest aliases, absent
fields, invalid dates, repeated recordings, truncated pages/tracklists, composer
roles, endpoint failures, retries, HTTP cache/rate-budget reuse, and stopping
before the source deadline while retaining safe fields.

On 2026-10-03, the real adapter was also run with the public example
Coldplay / Yellow / Parachutes / 266 seconds. The environment returned HTML
"Site Unavailable" with HTTP 200 instead of MusicBrainz JSON; the adapter
correctly reported a response-format failure after 8.741 seconds. This is a
verified failed live check, not evidence of successful live metadata coverage.
No lyrics or local audio were transmitted or logged by this probe.

## Official schema references

- [MusicBrainz API: includes, genres, relationships, and browse pagination](https://musicbrainz.org/doc/MusicBrainz_API)
- [MusicBrainz API JSON examples: releases, media, tracks, and nested work relationships](https://musicbrainz.org/doc/MusicBrainz_API/Examples)
- [Performance relationship: recording to work](https://musicbrainz.org/relationship/a3005666-a872-32c3-ad06-98af558e99b0)
- [Composer relationship: artist to work](https://musicbrainz.org/relationship/d59d99ea-23d4-4a80-b066-edca32ee158f)
