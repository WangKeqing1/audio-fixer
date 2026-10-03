import 'dart:async';

import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/models/recording_candidate.dart';
import 'package:audio_fixer/core/models/source_query_report.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/metadata_source.dart';
import 'package:audio_fixer/core/services/sources/json_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _Source implements MetadataSource {
  _Source(
    this.name,
    this.supportedFields, {
    this.result = const [],
    this.error,
  });
  @override
  final String name;
  @override
  final Set<AudioField> supportedFields;
  final List<FieldSuggestion> result;
  final Object? error;
  var calls = 0;

  @override
  Future<List<FieldSuggestion>> lookup(
    AudioTrack track,
    Set<AudioField> fields,
  ) async {
    calls++;
    if (error case final error?) throw error;
    return result;
  }
}

class _Discovery extends _Source implements RecordingDiscoverySource {
  _Discovery(super.name, super.supportedFields, {super.result, super.error});
  @override
  Future<DiscoveryResult> discover(AudioTrack track) async {
    calls++;
    if (error case final error?) throw error;
    return DiscoveryResult(candidates: [_recording(name)]);
  }

  @override
  Future<List<FieldSuggestion>> lookupConfirmed(
    AudioTrack track,
    RecordingCandidate recording,
    Set<AudioField> fields,
  ) => lookup(track, fields);
}

RecordingCandidate _recording(String source) => RecordingCandidate(
  sourceName: source,
  sourceId: 'test:123',
  sourceUrl: 'https://music.163.com/song?id=123',
  title: '测试歌曲',
  artist: '测试歌手',
  album: '专辑',
  durationMs: 120000,
  matchDescription: '用户确认的同一录音',
);

void main() {
  test(
    'healthy, empty, unsupported and failed providers have independent reports',
    () async {
      final until = DateTime.utc(2026, 1, 1, 0, 1);
      final limited = _Source(
        'LRCLIB',
        {AudioField.lyrics},
        error: ApiException(
          '数据源限制请求。',
          statusCode: 429,
          retryAfter: until,
          serverRetryAfter: until,
          isLocalCooldown: true,
        ),
      );
      final healthy = _Source(
        'NetEase',
        {AudioField.lyrics},
        result: const [
          FieldSuggestion(
            field: AudioField.lyrics,
            value: '已核实的歌词',
            source: 'NetEase',
          ),
        ],
      );
      final empty = _Source('MusicBrainz', {AudioField.album});
      final unsupported = _Source('Cover Art Archive', {AudioField.artwork});
      final result =
          await CompletionService(
            sources: [limited, healthy, empty, unsupported],
          ).preview(
            fixtureTrack(),
            const AppSettings(),
            requestedFields: {AudioField.lyrics, AudioField.album},
          );
      expect(result.status, TaskStatus.needsReview);
      expect(result.suggestions.single.source, 'NetEase');
      final reports = {
        for (final report in result.sourceReports) report.sourceName: report,
      };
      expect(reports['LRCLIB']!.outcome, SourceQueryOutcome.failed);
      expect(reports['LRCLIB']!.failureKind, SourceFailureKind.rateLimited);
      expect(reports['LRCLIB']!.retryAt, until);
      expect(reports['LRCLIB']!.serverRetryAt, until);
      expect(reports['LRCLIB']!.isLocalCooldown, isTrue);
      expect(reports['NetEase']!.outcome, SourceQueryOutcome.success);
      expect(reports['NetEase']!.candidateCount, 1);
      expect(reports['MusicBrainz']!.outcome, SourceQueryOutcome.noMatch);
      expect(
        reports['Cover Art Archive']!.outcome,
        SourceQueryOutcome.unsupported,
      );
      expect(unsupported.calls, 0);
      expect(result.message, isNot(contains('可能是来源未提供')));
    },
  );

  for (final error in [
    TimeoutException('do not expose raw URL or query'),
    const FormatException('<html>private response</html>'),
    Exception('internal private details'),
  ]) {
    test(
      '${error.runtimeType} is a failed lookup with sanitized diagnostics',
      () async {
        final result =
            await CompletionService(
              sources: [
                _Source('Source', {AudioField.lyrics}, error: error),
              ],
            ).preview(
              fixtureTrack(),
              const AppSettings(),
              requestedFields: {AudioField.lyrics},
            );
        expect(result.status, TaskStatus.failed);
        final report = result.sourceReports.single;
        expect(report.outcome, SourceQueryOutcome.failed);
        expect(
          report.failureKind,
          error is TimeoutException
              ? SourceFailureKind.timeout
              : error is FormatException
              ? SourceFailureKind.invalidResponse
              : SourceFailureKind.unknown,
        );
        expect(report.message, isNot(contains('private')));
        expect(report.message, isNot(contains('未找到')));
      },
    );
  }

  test(
    'partial endpoint failure retains candidates and exact retry metadata',
    () async {
      final until = DateTime.utc(2026, 1, 1, 0, 1);
      final result =
          await CompletionService(
            sources: [
              _Source(
                'NetEase',
                {AudioField.album, AudioField.lyrics},
                error: PartialSourceException(
                  const [
                    FieldSuggestion(
                      field: AudioField.album,
                      value: '同版本专辑',
                      source: 'NetEase',
                    ),
                  ],
                  '歌词连接超时，专辑资料仍可确认。',
                  cause: ApiException(
                    '连接超时。',
                    kind: SourceFailureKind.timeout,
                    retryAfter: until,
                  ),
                ),
              ),
            ],
          ).preview(
            fixtureTrack(),
            const AppSettings(),
            requestedFields: {AudioField.album, AudioField.lyrics},
          );
      expect(result.status, TaskStatus.needsReview);
      expect(result.suggestions.single.field, AudioField.album);
      expect(result.sourceReports.single.outcome, SourceQueryOutcome.partial);
      expect(result.sourceReports.single.candidateCount, 1);
      expect(
        result.sourceReports.single.failureKind,
        SourceFailureKind.timeout,
      );
      expect(result.sourceReports.single.retryAt, until);
    },
  );

  test(
    'recording discovery keeps another source candidates after a source fails',
    () async {
      final result = await CompletionService(
        sources: [
          _Discovery('Unavailable', {
            AudioField.lyrics,
          }, error: const ApiException('请求限制。', statusCode: 429)),
          _Discovery('NetEase', {AudioField.lyrics}),
          _Source('LRCLIB', {AudioField.lyrics}),
        ],
      ).discoverRecordings(fixtureTrack());
      expect(result.candidates.single.sourceName, 'NetEase');
      expect(result.hasFailures, isTrue);
      final reports = {
        for (final report in result.sourceReports) report.sourceName: report,
      };
      expect(
        reports['Unavailable']!.failureKind,
        SourceFailureKind.rateLimited,
      );
      expect(reports['NetEase']!.candidateCount, 1);
      expect(reports['LRCLIB']!.outcome, SourceQueryOutcome.unsupported);
    },
  );

  test('bounded discovery only visits requested providers and omits skipped reports', () async {
    final selected = _Discovery('NetEase', {AudioField.lyrics});
    final limited = _Discovery('Limited', {
      AudioField.lyrics,
    }, error: const ApiException('请求限制。', statusCode: 429));
    final result = await CompletionService(
      sources: [
        selected,
        limited,
        _Source('LRCLIB', {AudioField.lyrics}),
      ],
    ).discoverRecordings(fixtureTrack(), sourceNames: {'NetEase'});
    expect(selected.calls, 1);
    expect(limited.calls, 0);
    expect(result.sourceReports.single.sourceName, 'NetEase');
    expect(result.candidates.single.sourceName, 'NetEase');
    expect(result.hasFailures, isFalse);
  });

  test('cover dependency failure identifies MusicBrainz rather than blaming cover host', () async {
    final result =
        await CompletionService(
          sources: [
            _Source(
              'Cover Art Archive',
              {AudioField.artwork},
              error: const ApiException(
                '服务暂不可用。',
                statusCode: 503,
                provider: 'musicbrainz.org',
              ),
            ),
          ],
        ).preview(
          fixtureTrack(),
          const AppSettings(),
          requestedFields: {AudioField.artwork},
        );
    expect(result.sourceReports.single.message, contains('依赖来源 MusicBrainz'));
  });

  test('confirmed recording remains source-locked despite other successful provider', () async {
    final other = _Source(
      'Other',
      {AudioField.lyrics},
      result: const [
        FieldSuggestion(
          field: AudioField.lyrics,
          value: 'Wrong provider',
          source: 'Other',
        ),
      ],
    );
    final selected = _Discovery(
      'NetEase',
      {AudioField.lyrics},
      result: const [
        FieldSuggestion(
          field: AudioField.lyrics,
          value: 'Wrong recording',
          source: 'NetEase',
          sourceUrl: 'https://music.163.com/song?id=456',
        ),
      ],
    );
    final result = await CompletionService(sources: [other, selected]).preview(
      fixtureTrack(),
      const AppSettings(),
      requestedFields: {AudioField.lyrics},
      confirmedRecording: _recording('NetEase'),
    );
    expect(other.calls, 0);
    expect(result.suggestions, isEmpty);
    expect(result.sourceReports.single.sourceName, 'NetEase');
    expect(result.sourceReports.single.candidateCount, 0);
  });

  test(
    'absolute report deadline survives task persistence and expires with time',
    () {
      final now = DateTime.utc(2026);
      final task = CompletionTask(
        trackId: '1',
        trackTitle: 'fixture',
        createdAt: now,
        status: TaskStatus.failed,
        message: 'Source failure',
        sourceReports: [
          SourceQueryReport(
            sourceName: 'LRCLIB',
            requestedFields: {AudioField.lyrics},
            outcome: SourceQueryOutcome.failed,
            message: '请求限制。',
            statusCode: 429,
            failureKind: SourceFailureKind.rateLimited,
            retryAt: now.add(const Duration(seconds: 60)),
            serverRetryAt: now.add(const Duration(seconds: 45)),
            isLocalCooldown: true,
          ),
        ],
      );
      final restored = CompletionTask.fromJson(task.toJson());
      final report = restored.sourceReports.single;
      expect(report.retrySeconds(now.add(const Duration(seconds: 8))), 52);
      expect(
        report.retrySeconds(now.add(const Duration(milliseconds: 59999))),
        1,
      );
      expect(report.retrySeconds(now.add(const Duration(seconds: 60))), 0);
      expect(
        report.isCoolingDown(now.add(const Duration(seconds: 60))),
        isFalse,
      );
      expect(report.toJson(), task.sourceReports.single.toJson());
      final old = task.toJson()..remove('sourceReports');
      expect(CompletionTask.fromJson(old).sourceReports, isEmpty);
    },
  );
}
