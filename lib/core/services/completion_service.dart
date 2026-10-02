import '../models/app_settings.dart';
import '../models/audio_track.dart';
import '../models/completion_task.dart';
import 'metadata_source.dart';
import 'sources/json_api_client.dart';

class CompletionService {
  CompletionService({List<MetadataSource> sources = const []})
    : sources = List.unmodifiable(sources);

  final List<MetadataSource> sources;

  Future<CompletionTask> preview(AudioTrack track, AppSettings settings) async {
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
    final requested = track.missingFields.intersection(settings.enabledFields);
    if (requested.isEmpty) {
      return result(TaskStatus.skipped, '选定的补全项目没有缺失信息。');
    }
    final available = sources
        .expand((source) => source.supportedFields)
        .toSet();
    final unavailable = requested.difference(available);
    if (requested.intersection(available).isEmpty) {
      return result(
        TaskStatus.waitingForSource,
        '${unavailable.map((field) => field.label).join('、')}的数据源尚未接入。',
      );
    }

    // A preview is deliberately separate from a future approved file write.
    final suggestions = <FieldSuggestion>[];
    final failedSources = <String>[];
    for (final source in sources) {
      final fields = requested.intersection(source.supportedFields);
      if (fields.isEmpty) continue;
      try {
        final candidates = await source
            .lookup(track, Set.unmodifiable(fields))
            .timeout(const Duration(seconds: 45));
        suggestions.addAll(
          candidates
              .map(
                (candidate) => candidate.withChineseTranslation(
                  settings.includeChineseTranslation,
                ),
              )
              .where(
                (candidate) =>
                    fields.contains(candidate.field) &&
                    hasText(candidate.value) &&
                    hasText(candidate.source),
              ),
        );
      } catch (error) {
        failedSources.add(
          error is ApiException
              ? '${source.name}：${error.message}'
              : '${source.name}：查询失败或超时',
        );
      }
    }
    final warnings = <String>[
      if (unavailable.isNotEmpty)
        '${unavailable.map((field) => field.label).join('、')}的数据源尚未接入。',
      ...failedSources,
    ];
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
