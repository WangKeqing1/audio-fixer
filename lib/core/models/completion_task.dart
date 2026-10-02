import 'audio_track.dart';
import 'lyrics_content.dart';

enum TaskStatus {
  waitingForSource('等待数据源'),
  needsReview('候选待确认'),
  readyToSave('已确认待保存'),
  savedOriginal('已保存原文件'),
  exported('已导出副本'),
  outdated('资料已变化'),
  noMatch('未找到结果'),
  skipped('无需补全'),
  failed('处理失败');

  const TaskStatus(this.label);
  final String label;
}

class FieldSuggestion {
  const FieldSuggestion({
    required this.field,
    required this.value,
    required this.source,
    this.sourceUrl,
    this.matchDescription,
    this.originalLyrics,
    this.chineseTranslation,
    this.includeChineseTranslation = true,
  });

  final AudioField field;
  final String value;
  final String source;
  final String? sourceUrl;
  final String? matchDescription;
  final String? originalLyrics;
  final String? chineseTranslation;
  final bool includeChineseTranslation;

  LyricsContent? get lyricsContent => field == AudioField.lyrics
      ? LyricsContent(
          originalLyrics ?? value,
          chineseTranslation: chineseTranslation,
        )
      : null;

  FieldSuggestion withChineseTranslation(bool include) {
    final content = lyricsContent;
    if (content == null) return this;
    return FieldSuggestion(
      field: field,
      value: content.render(includeTranslation: include),
      source: source,
      sourceUrl: sourceUrl,
      matchDescription: matchDescription,
      originalLyrics: content.original,
      chineseTranslation: chineseTranslation,
      includeChineseTranslation: include,
    );
  }

  /// Only the two exact renderings of an existing candidate may be approved.
  /// An edited translation or fabricated source is never an allowed variant.
  bool permits(FieldSuggestion item) =>
      field == item.field &&
      source == item.source &&
      sourceUrl == item.sourceUrl &&
      (field != AudioField.lyrics
          ? value == item.value
          : lyricsContent!.original == item.lyricsContent!.original &&
                chineseTranslation == item.chineseTranslation &&
                (value == item.value ||
                    (lyricsContent!.hasChineseTranslation &&
                        item.value ==
                            lyricsContent!.render(
                              includeTranslation:
                                  item.includeChineseTranslation,
                            ))));

  Map<String, Object?> toJson() => {
    'field': field.name,
    'value': value,
    'source': source,
    'sourceUrl': sourceUrl,
    'matchDescription': matchDescription,
    'originalLyrics': originalLyrics,
    'chineseTranslation': chineseTranslation,
    'includeChineseTranslation': includeChineseTranslation,
  };

  factory FieldSuggestion.fromJson(Map<String, dynamic> json) =>
      FieldSuggestion(
        field: AudioField.values.byName(json['field'] as String),
        value: json['value'] as String,
        source: json['source'] as String,
        sourceUrl: json['sourceUrl'] as String?,
        matchDescription: json['matchDescription'] as String?,
        originalLyrics: json['originalLyrics'] as String?,
        chineseTranslation: json['chineseTranslation'] as String?,
        includeChineseTranslation:
            json['includeChineseTranslation'] as bool? ?? true,
      );
}

class CompletionTask {
  const CompletionTask({
    required this.trackId,
    required this.trackTitle,
    required this.createdAt,
    required this.status,
    required this.message,
    this.suggestions = const [],
    this.exportedCopyUri,
    this.queriedFields = const {},
    this.approvedSuggestions = const [],
    this.writeError,
  });

  final String trackId;
  final String trackTitle;
  final DateTime createdAt;
  final TaskStatus status;
  final String message;
  final List<FieldSuggestion> suggestions;
  final String? exportedCopyUri;
  final Set<AudioField> queriedFields;
  final List<FieldSuggestion> approvedSuggestions;
  final String? writeError;

  Map<String, Object?> toJson() => {
    'trackId': trackId,
    'trackTitle': trackTitle,
    'createdAt': createdAt.toIso8601String(),
    'status': status.name,
    'message': message,
    'suggestions': suggestions.map((item) => item.toJson()).toList(),
    'exportedCopyUri': exportedCopyUri,
    'queriedFields': queriedFields.map((field) => field.name).toList(),
    'approvedSuggestions': approvedSuggestions
        .map((item) => item.toJson())
        .toList(),
    'writeError': writeError,
  };

  factory CompletionTask.fromJson(Map<String, dynamic> json) => CompletionTask(
    trackId: json['trackId'] as String,
    trackTitle: json['trackTitle'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    status: TaskStatus.values.byName(json['status'] as String),
    exportedCopyUri: json['exportedCopyUri'] as String?,
    writeError: json['writeError'] as String?,
    approvedSuggestions: (json['approvedSuggestions'] as List? ?? const [])
        .map((item) => FieldSuggestion.fromJson(item as Map<String, dynamic>))
        .toList(),
    queriedFields: (json['queriedFields'] as List? ?? const [])
        .map((field) => AudioField.values.byName(field as String))
        .toSet(),
    message: json['message'] as String,
    suggestions: (json['suggestions'] as List)
        .map((item) => FieldSuggestion.fromJson(item as Map<String, dynamic>))
        .toList(),
  );
}
