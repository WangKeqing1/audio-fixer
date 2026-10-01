import 'audio_track.dart';

enum TaskStatus {
  waitingForSource('等待数据源'),
  needsReview('候选待确认'),
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
  });

  final AudioField field;
  final String value;
  final String source;
  final String? sourceUrl;
  final String? matchDescription;

  Map<String, Object?> toJson() => {
    'field': field.name,
    'value': value,
    'source': source,
    'sourceUrl': sourceUrl,
    'matchDescription': matchDescription,
  };

  factory FieldSuggestion.fromJson(Map<String, dynamic> json) =>
      FieldSuggestion(
        field: AudioField.values.byName(json['field'] as String),
        value: json['value'] as String,
        source: json['source'] as String,
        sourceUrl: json['sourceUrl'] as String?,
        matchDescription: json['matchDescription'] as String?,
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
  });

  final String trackId;
  final String trackTitle;
  final DateTime createdAt;
  final TaskStatus status;
  final String message;
  final List<FieldSuggestion> suggestions;

  Map<String, Object?> toJson() => {
    'trackId': trackId,
    'trackTitle': trackTitle,
    'createdAt': createdAt.toIso8601String(),
    'status': status.name,
    'message': message,
    'suggestions': suggestions.map((item) => item.toJson()).toList(),
  };

  factory CompletionTask.fromJson(Map<String, dynamic> json) => CompletionTask(
    trackId: json['trackId'] as String,
    trackTitle: json['trackTitle'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    status: TaskStatus.values.byName(json['status'] as String),
    message: json['message'] as String,
    suggestions: (json['suggestions'] as List)
        .map((item) => FieldSuggestion.fromJson(item as Map<String, dynamic>))
        .toList(),
  );
}
