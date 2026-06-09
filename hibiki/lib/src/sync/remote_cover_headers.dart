abstract class RemoteCoverHeadersProvider {
  Map<String, String> get remoteCoverHeaders;
}

Map<String, String>? remoteCoverHeadersFor(Object? client) {
  if (client is! RemoteCoverHeadersProvider) return null;
  final Map<String, String> headers = client.remoteCoverHeaders;
  return headers.isEmpty ? null : headers;
}
