import '../../models/source_query_report.dart';

abstract interface class JsonApiClient {
  /// Returns decoded JSON, or null for an HTTP 404. Other HTTP/network errors
  /// throw ApiException. Implementations must throttle requests per provider.
  /// Implementations may reuse exact-query JSON for a bounded time, but must
  /// never broaden a query or retry automatically after a source failure.
  Future<Object?> getJson(Uri uri);
}

class ApiException implements Exception {
  const ApiException(
    this.message, {
    this.statusCode,
    this.retryAfter,
    this.kind,
    this.provider,
    this.serverRetryAfter,
    this.isLocalCooldown = false,
  });
  final String message;
  final int? statusCode;
  final SourceFailureKind? kind;
  final String? provider;
  final DateTime? serverRetryAfter;
  final bool isLocalCooldown;
  SourceFailureKind get failureKind =>
      kind ?? SourceFailureKind.forStatus(statusCode);
  DateTime? get retryAt => retryAfter;

  /// Earliest time a failed provider may be tried again (no automatic retry).
  final DateTime? retryAfter;
  @override
  String toString() => message;
}
