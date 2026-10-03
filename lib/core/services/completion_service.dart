import 'dart:async';

import '../models/app_settings.dart';
import '../models/audio_track.dart';
import '../models/completion_task.dart';
import '../models/recording_candidate.dart';
import '../models/source_query_report.dart';
import 'metadata_source.dart';
import 'lyrics_translation_service.dart';
import 'sources/json_api_client.dart';

class CompletionService {
  CompletionService({List<MetadataSource> sources = const [], this.translator})
    : sources = List.unmodifiable(sources);

  final List<MetadataSource> sources;
  final LyricsTranslator? translator;

  /// Source capability, not a promise that a particular recording has a value.
  Set<AudioField> get availableFields =>
      Set.unmodifiable(sources.expand((source) => source.supportedFields));

  Future<DiscoveryResult> discoverRecordings(
    AudioTrack track, {
    Set<String>? sourceNames,
  }) async {
    if (track.readError != null || !track.detailsLoaded) {
      return DiscoveryResult(
        diagnostics: ['请先成功读取歌曲资料后再查找录音候选。'],
        hasFailures: true,
      );
    }
    final candidates = <RecordingCandidate>[];
    final diagnostics = <String>[];
    final reports = <SourceQueryReport>[];
    var hasFailures = false;
    final selectedSources = sourceNames == null
        ? sources
        : sources.where((source) => sourceNames.contains(source.name));
    final discoverySources = selectedSources
        .whereType<RecordingDiscoverySource>();
    for (final source in selectedSources.where(
      (source) => source is! RecordingDiscoverySource,
    )) {
      const message = '需要先确认歌手及录音版本，未进行仅凭歌名的查询。';
      diagnostics.add('${source.name}：$message');
      reports.add(
        SourceQueryReport(
          sourceName: source.name,
          outcome: SourceQueryOutcome.unsupported,
          message: message,
        ),
      );
    }
    if (discoverySources.isEmpty) {
      diagnostics.add('尚未接入支持录音候选发现的数据源。');
    }
    for (final source in discoverySources) {
      try {
        final result = await source
            .discover(track)
            .timeout(const Duration(seconds: 45));
        final previousCount = candidates.length;
        var invalidCandidates = false;
        for (final candidate in result.candidates) {
          if (!candidate.isValid || candidate.sourceName != source.name) {
            hasFailures = true;
            invalidCandidates = true;
            diagnostics.add('${source.name}：已忽略来源或格式无效的录音候选。');
            continue;
          }
          if (!candidates.any((item) => item.sameIdentity(candidate))) {
            candidates.add(candidate);
          }
        }
        diagnostics.addAll(
          result.diagnostics.map((message) => '${source.name}：$message'),
        );
        hasFailures |= result.hasFailures;
        final count = candidates.length - previousCount;
        reports.add(
          SourceQueryReport(
            sourceName: source.name,
            outcome: result.hasFailures || invalidCandidates
                ? (count > 0
                      ? SourceQueryOutcome.partial
                      : SourceQueryOutcome.failed)
                : (count > 0
                      ? SourceQueryOutcome.success
                      : SourceQueryOutcome.noMatch),
            message: invalidCandidates
                ? '来源返回了身份或格式无效的录音，已忽略；保留 $count 个可靠候选。'
                : result.diagnostics.isNotEmpty
                ? result.diagnostics.join('；')
                : result.hasFailures
                ? '来源查询未完成，保留 $count 个可靠候选。'
                : count > 0
                ? '找到 $count 个待确认录音。'
                : '查询完成，未找到可确认的录音。',
            candidateCount: count,
            failureKind: invalidCandidates
                ? SourceFailureKind.invalidResponse
                : null,
          ),
        );
      } catch (error) {
        hasFailures |= error is! SourceNoMatch;
        final report = _failureReport(source.name, const {}, error);
        reports.add(report);
        diagnostics.add('${source.name}：${report.message}');
      }
    }
    return DiscoveryResult(
      candidates: candidates,
      diagnostics: diagnostics,
      hasFailures: hasFailures,
      sourceReports: reports,
    );
  }

  Future<CompletionTask> preview(
    AudioTrack track,
    AppSettings settings, {
    Set<AudioField>? requestedFields,
    AudioTrack? searchTrack,
    RecordingCandidate? confirmedRecording,
  }) async {
    final reports = <SourceQueryReport>[];
    CompletionTask result(
      TaskStatus status,
      String message, [
      List<FieldSuggestion> suggestions = const [],
    ]) => CompletionTask(
      trackId: track.id,
      trackTitle: track.displayTitle,
      createdAt: DateTime.now(),
      status: status,
      message: message,
      suggestions: suggestions,
      sourceReports: List.unmodifiable(reports),
    );

    if (track.readError != null) {
      return result(TaskStatus.failed, '无法读取已有标签，请先检查音频文件。');
    }
    if (!track.detailsLoaded) {
      if (settings.enabledFields.isEmpty) {
        return result(TaskStatus.skipped, '补全项目已全部关闭。');
      }
      return result(
        sources.isEmpty ? TaskStatus.waitingForSource : TaskStatus.failed,
        sources.isEmpty ? '在线数据源尚未接入，已有标签可在歌曲资料中查看。' : '请先读取歌曲资料后再查询候选。',
      );
    }
    final requested =
        (requestedFields ??
                track.missingFields.intersection(settings.enabledFields))
            .where(
              (field) => !(field == AudioField.lyrics && track.isInstrumental),
            )
            .toSet();
    if (requested.isEmpty) {
      return result(
        TaskStatus.skipped,
        track.isInstrumental && settings.lyrics
            ? '已在本应用设为纯音乐，跳过歌词查询与翻译。其余选定项目没有缺失信息。'
            : '选定的补全项目没有缺失信息。',
      );
    }
    final activeSources = confirmedRecording == null
        ? sources
        : sources
              .where(
                (source) =>
                    source is RecordingDiscoverySource &&
                    source.name == confirmedRecording.sourceName,
              )
              .toList();
    if (confirmedRecording != null &&
        (!confirmedRecording.isValid || activeSources.length != 1)) {
      return result(TaskStatus.failed, '已选录音的来源不可用或身份无效，请重新查找并选择。');
    }
    final available = activeSources
        .expand((source) => source.supportedFields)
        .toSet();
    final unavailable = requested.difference(available);
    final unavailableNotice = confirmedRecording == null
        ? '${unavailable.map((field) => field.label).join('、')}的数据源尚未接入。'
        : '所选版本的来源不提供${unavailable.map((field) => field.label).join('、')}，保留原资料。';
    for (final source in activeSources) {
      if (requested.intersection(source.supportedFields).isEmpty) {
        reports.add(
          SourceQueryReport(
            sourceName: source.name,
            requestedFields: Set.unmodifiable(requested),
            outcome: SourceQueryOutcome.unsupported,
            message: '该来源不支持本次选择的补全项目。',
          ),
        );
      }
    }
    if (requested.intersection(available).isEmpty) {
      return result(
        confirmedRecording == null
            ? TaskStatus.waitingForSource
            : TaskStatus.noMatch,
        unavailableNotice,
      );
    }

    // Each provider owns its result. A failure cannot discard candidates that
    // another provider has independently verified, and a chosen recording is
    // still locked to its exact source identity.
    final suggestions = <FieldSuggestion>[];
    bool hasRecordingProvenance(FieldSuggestion candidate) =>
        confirmedRecording == null ||
        (candidate.source == confirmedRecording.sourceName &&
            candidate.sourceUrl == confirmedRecording.sourceUrl);
    for (final source in activeSources) {
      final fields = requested.intersection(source.supportedFields);
      if (fields.isEmpty) continue;
      List<FieldSuggestion> verified(Iterable<FieldSuggestion> candidates) =>
          candidates
              .map(
                (candidate) => candidate
                    .withReplacement(false)
                    .withChineseTranslation(settings.includeChineseTranslation),
              )
              .where(
                (candidate) =>
                    fields.contains(candidate.field) &&
                    hasText(candidate.value) &&
                    hasText(candidate.source) &&
                    hasRecordingProvenance(candidate),
              )
              .toList();
      try {
        final operation = confirmedRecording == null
            ? source.lookup(searchTrack ?? track, Set.unmodifiable(fields))
            : (source as RecordingDiscoverySource).lookupConfirmed(
                searchTrack ?? track,
                confirmedRecording,
                Set.unmodifiable(fields),
              );
        final candidates = verified(
          await operation.timeout(const Duration(seconds: 45)),
        );
        suggestions.addAll(candidates);
        reports.add(
          SourceQueryReport(
            sourceName: source.name,
            requestedFields: Set.unmodifiable(fields),
            outcome: candidates.isEmpty
                ? SourceQueryOutcome.noMatch
                : SourceQueryOutcome.success,
            message: candidates.isEmpty
                ? '查询完成，未找到可安全采用的同版本资料。'
                : '获得 ${candidates.length} 项候选资料，等待确认。',
            candidateCount: candidates.length,
          ),
        );
      } catch (error) {
        final partial = error is PartialSourceException
            ? verified(error.suggestions)
            : const <FieldSuggestion>[];
        suggestions.addAll(partial);
        reports.add(
          _failureReport(
            source.name,
            fields,
            error,
            candidateCount: partial.length,
          ),
        );
      }
    }
    // Existing provider translations win. Automatic local fallback uses only
    // already-downloaded models after first-use disclosure/enablement.
    if (settings.includeChineseTranslation &&
        settings.onDeviceTranslationEnabled &&
        translator != null &&
        !suggestions.any(
          (candidate) =>
              candidate.lyricsContent?.hasChineseTranslation ?? false,
        )) {
      final index = suggestions.indexWhere(
        (candidate) => candidate.field == AudioField.lyrics,
      );
      if (index >= 0) {
        final candidate = suggestions[index];
        try {
          final translated = await translator!
              .translateIfReady(candidate.lyricsContent!.original)
              .timeout(const Duration(seconds: 45));
          suggestions[index] = candidate
              .withTranslation(
                chineseLyrics: translated.chineseLyrics,
                machineTranslated: translated.available,
                notice: translated.message,
              )
              .withChineseTranslation(settings.includeChineseTranslation);
        } catch (_) {
          suggestions[index] = candidate.withTranslation(
            notice: '本机翻译暂未完成，原歌词可正常使用。',
          );
        }
      }
    }
    final failed = reports
        .where(
          (report) =>
              report.outcome == SourceQueryOutcome.failed ||
              report.outcome == SourceQueryOutcome.partial,
        )
        .toList();
    final warnings = <String>[
      if (unavailable.isNotEmpty) unavailableNotice,
      ...failed.map((report) => '${report.sourceName}：${report.message}'),
      ...reports
          .where((report) => report.outcome == SourceQueryOutcome.noMatch)
          .map((report) => '${report.sourceName}：${report.message}'),
    ];
    final warning = warnings.isEmpty ? '' : ' ${warnings.join('；')}';
    if (suggestions.isEmpty) {
      return failed.isEmpty
          ? result(TaskStatus.noMatch, '查询完成，暂无可采用的候选。$warning')
          : result(TaskStatus.failed, '来源查询未完成，暂无可采用的候选。$warning');
    }
    return result(
      TaskStatus.needsReview,
      '已找到候选信息，尚未写入音频。$warning',
      suggestions,
    );
  }

  SourceQueryReport _failureReport(
    String sourceName,
    Set<AudioField> fields,
    Object error, {
    int candidateCount = 0,
  }) {
    if (error is SourceNoMatch) {
      return SourceQueryReport(
        sourceName: sourceName,
        requestedFields: Set.unmodifiable(fields),
        outcome: SourceQueryOutcome.noMatch,
        message: error.message,
      );
    }
    final cause = error is PartialSourceException ? error.cause : error;
    final api = cause is ApiException ? cause : null;
    final kind =
        api?.failureKind ??
        switch (cause) {
          TimeoutException() => SourceFailureKind.timeout,
          FormatException() => SourceFailureKind.invalidResponse,
          _ => SourceFailureKind.unknown,
        };
    final detail = error is PartialSourceException
        ? error.message
        : api?.message ??
              switch (kind) {
                SourceFailureKind.timeout => '查询超时，未完成资料核对。',
                SourceFailureKind.invalidResponse => '数据源响应格式异常，未获得可用资料。',
                _ => '查询失败，未完成资料核对。',
              };
    final dependency = const {
      'musicbrainz.org': 'MusicBrainz',
      'lrclib.net': 'LRCLIB',
      'coverartarchive.org': 'Cover Art Archive',
      'archive.org': 'Internet Archive',
      'music.163.com': '网易云音乐（实验性）',
    }[api?.provider];
    final message = dependency != null && dependency != sourceName
        ? '依赖来源 $dependency：$detail'
        : detail;
    return SourceQueryReport(
      sourceName: sourceName,
      requestedFields: Set.unmodifiable(fields),
      outcome: candidateCount > 0
          ? SourceQueryOutcome.partial
          : SourceQueryOutcome.failed,
      message: message,
      candidateCount: candidateCount,
      failureKind: kind,
      statusCode: api?.statusCode,
      retryAt: api?.retryAt,
      serverRetryAt: api?.serverRetryAfter,
      isLocalCooldown: api?.isLocalCooldown ?? false,
    );
  }
}
