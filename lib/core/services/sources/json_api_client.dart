abstract interface class JsonApiClient {
  /// Returns decoded JSON, or null for an HTTP 404. Other HTTP/network errors
  /// throw ApiException. Implementations must throttle requests per host.
  Future<Object?> getJson(Uri uri);
}

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}
