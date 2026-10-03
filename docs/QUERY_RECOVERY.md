# Query diagnostics and recovery

The provider transport already had rate limits and persisted cooldowns, but an old local-cooldown error replaced every original cause with “busy.” A remaining-seconds message therefore did not establish whether the initial response was HTTP 429, HTTP 503, a timeout, a network failure or invalid JSON. Completion results also flattened that error into a single message beside every missing field.

Structured per-provider reports now preserve the outcome, returned candidate count, failure kind, HTTP status when known, the absolute local retry deadline, and the actual server Retry-After deadline when supplied. These reports survive task storage, review, approval and write transitions. An older persisted cooldown without enough evidence remains an unknown failure; the application does not invent an earlier status.

A source failure does not discard independently verified fields from another source. Partial adapter failures retain earlier verified results and attach the transport cause. Exact-query cached responses may still be used during a provider cooldown; queries are never broadened to reuse a cache. No automatic retry starts when a timer expires. The UI counts down from the saved absolute deadline, disables repeat submission when every eligible source is blocked, and keeps unrelated sources and existing candidates accessible. Collapsed rows show concise provider outcomes, while request scope and diagnostic details are available on expansion.

## Conservative query cleanup and recording recovery

A name ending with the complete existing artist credit separated by whitespace can now be split into a title query. Matching is case/spacing insensitive but retains punctuation and word boundaries. The rule does not infer an artist from arbitrary trailing words, remove a partial credit, alter raw tags, discard unknown bracket contents, or drop Live/Remix/version suffixes. A manual query remains available for ambiguous naming.

If a strict lookup produces no usable field candidates, only discovery-capable providers that returned a normal no-match may be queried once for a bounded recording list. Existing artist evidence still participates, failed providers are not immediately retried, and successful field results are not replaced. The user must choose a recording and then approve individual fields. A separate explicit “仅凭歌名查找版本” action can ignore an uncertain artist for discovery while preserving actual tags. That chosen query and provider ID remain pinned through field lookup and retries.

## Public live adapter verification

On 2026-10-03 the actual production NetEase adapter was exercised with the public song “everytime you kissed me,” artist Emily Bindiger, and duration 299.079 seconds. A constructed query title containing the complete artist suffix was normalized first. No audio, file comments, private provider keys or inventory were transmitted.

Normal lookup returned eight fields from [recording 591037](https://music.163.com/song?id=591037): title, artist, album, album artist, year, track number, an allowlisted cover URL, and lyrics with provider Chinese translation. The original English album spelling was reported as unverified; using the provider album spelling returned the same identity with album-match evidence. A cover URL is not a claim that image bytes were downloaded or rendered.

Known-artist discovery returned two recordings, with duration differences of 0.027 and 2.958 seconds. The probe explicitly selected 591037 and verified all eight field suggestions retained that same ID. Four actual HTTP requests, all returning 200, covered normal search, selected song detail, selected lyrics and title-only discovery. The exact-album and confirmed-selection repeats were served by the production cache without additional requests. A separate public LRCLIB clean-title search returned an empty list, and its exact lookup returned 404; normalization is not a promise that every source has the song.

The probe used the existing curl-backed test transport at the cloud network boundary. The Android application retains its ordinary HTTP client. This is live adapter evidence, not installation or device-runtime verification.

Regression tests use synthetic fixtures for provider error isolation, cache and cooldown persistence, server/local deadlines, title cleanup, bounded discovery, selected identity, explicit wider discovery, retries, task serialization and UI interruptions. They do not include a user's private inventory or comments.
