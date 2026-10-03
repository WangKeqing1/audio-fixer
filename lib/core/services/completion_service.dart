import '../models/app_settings.dart';
import '../models/audio_track.dart';
import '../models/completion_task.dart';
import '../models/recording_candidate.dart';
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

  Future<DiscoveryResult> discoverRecordings(AudioTrack track) async {
    if (track.readError != null || !track.detailsLoaded) {
      return DiscoveryResult(
        diagnostics: ['请先成功读取歌曲资料后再查找录音候选。'],
        hasFailures: true,
      );
    }
    final candidates = <RecordingCandidate>[];
    final diagnostics = <String>[];
    var hasFailures = false;
    final discoverySources = sources.whereType<RecordingDiscoverySource>();
    for (final source in sources.where(
      (source) => source is! RecordingDiscoverySource,
    )) {
      diagnostics.add('${source.name}：需要先确认歌手及录音版本，未进行仅凭歌名的查询。');
    }
    if (discoverySources.isEmpty) {
      diagnostics.add('尚未接入支持录音候选发现的数据源。');
    }
    for (final source in discoverySources) {
      try {
        final result = await source
            .discover(track)
            .timeout(const Duration(seconds: 45));
        for (final candidate in result.candidates) {
          if (!candidate.isValid || candidate.sourceName != source.name) {
            hasFailures = true;
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
      } catch (error) {
        hasFailures |= error is! SourceNoMatch;
        diagnostics.add(
          '${source.name}：${error is SourceNoMatch
              ? error.message
              : error is ApiException
              ? error.message
              : '查询失败或超时'}',
        );
      }
    }
    return DiscoveryResult(
      candidates: candidates,
      diagnostics: diagnostics,
      hasFailures: hasFailures,
    );
  }

  Future<CompletionTask> preview(
    AudioTrack track,
    AppSettings settings, {
    Set<AudioField>? requestedFields,
    AudioTrack? searchTrack,
    RecordingCandidate? confirmedRecording,
  }) async {
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
    if (requested.intersection(available).isEmpty) {
      return result(
        confirmedRecording == null
            ? TaskStatus.waitingForSource
            : TaskStatus.noMatch,
        unavailableNotice,
      );
    }

    // A preview is deliberately separate from a future approved file write.
    final suggestions = <FieldSuggestion>[];
    final failedSources = <String>[];
    final sourceNotices = <String>[];
    bool hasRecordingProvenance(FieldSuggestion candidate) =>
        confirmedRecording == null ||
        (candidate.source == confirmedRecording.sourceName &&
            candidate.sourceUrl == confirmedRecording.sourceUrl);
    for (final source in activeSources) {
      final fields = requested.intersection(source.supportedFields);
      if (fields.isEmpty) continue;
      try {
        final operation = confirmedRecording == null
            ? source.lookup(searchTrack ?? track, Set.unmodifiable(fields))
            : (source as RecordingDiscoverySource).lookupConfirmed(
                searchTrack ?? track,
                confirmedRecording,
                Set.unmodifiable(fields),
              );
        final candidates = await operation.timeout(const Duration(seconds: 45));
        suggestions.addAll(
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
              ),
        );
      } catch (error) {
        if (error is SourceNoMatch) {
          sourceNotices.add('${source.name}：${error.message}');
          continue;
        }
        if (error is PartialSourceException) {
          suggestions.addAll(
            error.suggestions
                .map(
                  (candidate) => candidate
                      .withReplacement(false)
                      .withChineseTranslation(
                        settings.includeChineseTranslation,
                      ),
                )
                .where(
                  (candidate) =>
                      fields.contains(candidate.field) &&
                      hasText(candidate.value) &&
                      hasText(candidate.source) &&
                      hasRecordingProvenance(candidate),
                ),
          );
        }
        failedSources.add(
          error is PartialSourceException
              ? '${source.name}：${error.message}'
              : error is ApiException
              ? '${source.name}：${error.message}'
              : '${source.name}：查询失败或超时',
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
    final warnings = <String>[
      if (unavailable.isNotEmpty) unavailableNotice,
      ...failedSources,
      ...sourceNotices,
    ];
    final withoutCandidate = requested
        .intersection(available)
        .difference(suggestions.map((candidate) => candidate.field).toSet());
    if (withoutCandidate.isNotEmpty) {
      warnings.add(
        '${withoutCandidate.map((field) => field.label).join('、')}未获得可靠候选；可能是来源未提供、版本无法确认或查询未完成。保留原资料。',
      );
    }
    final warning = warnings.isEmpty ? '' : ' ${warnings.join('；')}';
    if (suggestions.isEmpty) {
      return failedSources.isEmpty
          ? result(TaskStatus.noMatch, '没有找到可用信息，可以稍后重试。$warning')
          : result(TaskStatus.failed, warning.trim());
    }
    return result(
      TaskStatus.needsReview,
      '已找到候选信息，尚未写入音频。$warning',
      suggestions,
    );
  }
}
