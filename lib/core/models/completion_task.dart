import 'audio_track.dart';
import 'lyrics_content.dart';
import 'recording_candidate.dart';
import 'source_query_report.dart';

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

/// Only adapters that have verified recording identity may opt in. Legacy
/// persisted candidates remain unverified; display prose never grants trust.
enum SuggestionProvenance { unverified, verifiedRecording, manual }

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
    this.machineTranslated = false,
    this.translationNotice,
    this.replaceExisting = false,
    this.provenance = SuggestionProvenance.unverified,
  });

  final AudioField field;
  final String value;
  final String source;
  final String? sourceUrl;
  final String? matchDescription;
  final String? originalLyrics;
  final String? chineseTranslation;
  final bool includeChineseTranslation;
  final bool machineTranslated;
  final String? translationNotice;
  final bool replaceExisting;
  final SuggestionProvenance provenance;

  LyricsContent? get lyricsContent => field == AudioField.lyrics
      ? LyricsContent(
          originalLyrics ?? value,
          chineseTranslation: chineseTranslation,
          machineTranslated: machineTranslated,
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
      machineTranslated: machineTranslated,
      translationNotice: translationNotice,
      replaceExisting: replaceExisting,
      provenance: provenance,
    );
  }

  FieldSuggestion withTranslation({
    String? chineseLyrics,
    bool machineTranslated = false,
    String? notice,
  }) {
    final content = lyricsContent;
    if (content == null) return this;
    return FieldSuggestion(
      field: field,
      value: content.original,
      source: source,
      sourceUrl: sourceUrl,
      matchDescription: matchDescription,
      originalLyrics: content.original,
      chineseTranslation: chineseLyrics,
      machineTranslated: machineTranslated,
      translationNotice: notice,
      includeChineseTranslation: includeChineseTranslation,
      replaceExisting: replaceExisting,
      provenance: provenance,
    ).withChineseTranslation(includeChineseTranslation);
  }

  FieldSuggestion withReplacement(bool replace) {
    if (replace == replaceExisting) return this;
    return FieldSuggestion(
      field: field,
      value: value,
      source: source,
      sourceUrl: sourceUrl,
      matchDescription: matchDescription,
      originalLyrics: originalLyrics,
      chineseTranslation: chineseTranslation,
      includeChineseTranslation: includeChineseTranslation,
      machineTranslated: machineTranslated,
      translationNotice: translationNotice,
      replaceExisting: replace,
      provenance: provenance,
    );
  }

  /// Only the two exact renderings of an existing candidate may be approved.
  /// An edited translation or fabricated source is never an allowed variant.
  bool permits(FieldSuggestion item) =>
      field == item.field &&
      source == item.source &&
      sourceUrl == item.sourceUrl &&
      replaceExisting == item.replaceExisting &&
      provenance == item.provenance &&
      (field != AudioField.lyrics
          ? value == item.value
          : lyricsContent!.original == item.lyricsContent!.original &&
                chineseTranslation == item.chineseTranslation &&
                machineTranslated == item.machineTranslated &&
                translationNotice == item.translationNotice &&
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
    'machineTranslated': machineTranslated,
    'translationNotice': translationNotice,
    'replaceExisting': replaceExisting,
    'provenance': provenance.name,
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
        machineTranslated: json['machineTranslated'] as bool? ?? false,
        translationNotice: json['translationNotice'] as String?,
        replaceExisting: json['replaceExisting'] as bool? ?? false,
        provenance: SuggestionProvenance.values.firstWhere(
          (value) => value.name == json['provenance'],
          orElse: () => SuggestionProvenance.unverified,
        ),
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
    this.reviewSelectionMade = false,
    this.writeError,
    this.isRepair = false,
    this.searchMetadata = const {},
    this.recordingCandidates = const [],
    this.confirmedRecording,
    this.sourceReports = const [],
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

  /// Remembers a deliberate empty/revoked choice, so review defaults cannot
  /// silently re-add candidates the user already decided to leave out.
  final bool reviewSelectionMade;
  final String? writeError;
  final bool isRepair;
  final Map<String, String> searchMetadata;
  final List<RecordingCandidate> recordingCandidates;
  final RecordingCandidate? confirmedRecording;
  final List<SourceQueryReport> sourceReports;
  bool get needsRecordingChoice =>
      recordingCandidates.isNotEmpty && confirmedRecording == null;

  Map<String, Object?> toJson() => {
    'trackId': trackId,
    'trackTitle': trackTitle,
    'createdAt': createdAt.toIso8601String(),
    'status': status.name,
    'message': message,
    'suggestions': suggestions.map((item) => item.toJson()).toList(),
    'exportedCopyUri': exportedCopyUri,
    'queriedFields': queriedFields.map((field) => field.name).toList(),
    'reviewSelectionMade': reviewSelectionMade,
    'approvedSuggestions': approvedSuggestions
        .map((item) => item.toJson())
        .toList(),
    'writeError': writeError,
    'isRepair': isRepair,
    'searchMetadata': searchMetadata,
    'recordingCandidates': recordingCandidates
        .map((item) => item.toJson())
        .toList(),
    'confirmedRecording': confirmedRecording?.toJson(),
    'sourceReports': sourceReports.map((report) => report.toJson()).toList(),
  };

  factory CompletionTask.fromJson(Map<String, dynamic> json) => CompletionTask(
    trackId: json['trackId'] as String,
    trackTitle: json['trackTitle'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    status: TaskStatus.values.byName(json['status'] as String),
    exportedCopyUri: json['exportedCopyUri'] as String?,
    writeError: json['writeError'] as String?,
    isRepair: json['isRepair'] as bool? ?? false,
    searchMetadata: Map<String, String>.from(
      json['searchMetadata'] as Map? ?? const {},
    ),
    recordingCandidates: List.unmodifiable(
      (json['recordingCandidates'] as List? ?? const []).map(
        (item) =>
            RecordingCandidate.fromJson(Map<String, dynamic>.from(item as Map)),
      ),
    ),
    sourceReports: List.unmodifiable(
      (json['sourceReports'] as List? ?? const []).map(
        (item) =>
            SourceQueryReport.fromJson(Map<String, dynamic>.from(item as Map)),
      ),
    ),
    confirmedRecording: json['confirmedRecording'] == null
        ? null
        : RecordingCandidate.fromJson(
            Map<String, dynamic>.from(json['confirmedRecording'] as Map),
          ),
    reviewSelectionMade: json['reviewSelectionMade'] as bool? ?? false,
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
