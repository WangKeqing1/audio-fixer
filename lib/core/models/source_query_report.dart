import 'audio_track.dart';

enum SourceQueryOutcome { success, noMatch, unsupported, failed, partial }

/// A typed transport or identity-verification cause, never inferred from text.
enum SourceFailureKind {
  rateLimited,
  serverError,
  timeout,
  network,
  invalidResponse,
  identityConflict,
  accessDenied,
  httpError,
  unknown;

  static SourceFailureKind forStatus(int? status) {
    if (status == 429) return rateLimited;
    if (status != null && status >= 500 && status <= 599) return serverError;
    if (const {301, 401, 403}.contains(status)) return accessDenied;
    return status == null ? unknown : httpError;
  }
}

/// Safe, provider-scoped query information. Does not contain a request URL,
/// response body or headers. Deadlines are absolute so saved results cannot
/// freeze a retry countdown or restart its waiting period.
class SourceQueryReport {
  const SourceQueryReport({
    required this.sourceName,
    required this.outcome,
    required this.message,
    this.requestedFields = const {},
    this.candidateCount = 0,
    this.failureKind,
    this.statusCode,
    this.retryAt,
    this.serverRetryAt,
    this.isLocalCooldown = false,
  });

  final String sourceName;
  final SourceQueryOutcome outcome;
  final String message;
  final Set<AudioField> requestedFields;
  final int candidateCount;
  final SourceFailureKind? failureKind;
  final int? statusCode;
  final DateTime? retryAt;
  final DateTime? serverRetryAt;
  final bool isLocalCooldown;

  bool isCoolingDown(DateTime now) => retryAt?.isAfter(now) ?? false;

  int retrySeconds(DateTime now) => isCoolingDown(now)
      ? (retryAt!.difference(now).inMicroseconds /
                Duration.microsecondsPerSecond)
            .ceil()
      : 0;

  Map<String, Object?> toJson() => {
    'sourceName': sourceName,
    'outcome': outcome.name,
    'message': message,
    'requestedFields': requestedFields.map((field) => field.name).toList(),
    'candidateCount': candidateCount,
    'failureKind': failureKind?.name,
    'statusCode': statusCode,
    'retryAt': retryAt?.toUtc().toIso8601String(),
    'serverRetryAt': serverRetryAt?.toUtc().toIso8601String(),
    'isLocalCooldown': isLocalCooldown,
  };

  factory SourceQueryReport.fromJson(Map<String, dynamic> json) =>
      SourceQueryReport(
        sourceName: json['sourceName'] as String,
        outcome: SourceQueryOutcome.values.byName(json['outcome'] as String),
        message: json['message'] as String,
        requestedFields: Set.unmodifiable(
          (json['requestedFields'] as List? ?? const []).map(
            (field) => AudioField.values.byName(field as String),
          ),
        ),
        candidateCount: json['candidateCount'] as int? ?? 0,
        failureKind: json['failureKind'] == null
            ? null
            : SourceFailureKind.values.byName(json['failureKind'] as String),
        statusCode: json['statusCode'] as int?,
        retryAt: DateTime.tryParse(json['retryAt'] as String? ?? ''),
        serverRetryAt: DateTime.tryParse(
          json['serverRetryAt'] as String? ?? '',
        ),
        isLocalCooldown: json['isLocalCooldown'] as bool? ?? false,
      );
}
