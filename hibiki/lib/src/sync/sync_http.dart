import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:hibiki/src/sync/sync_backend.dart';

/// Connection-establishment timeout for cloud sync HTTP requests.
const Duration kSyncConnectionTimeout = Duration(seconds: 60);

/// Shared HTTP client for cloud sync backends (OneDrive, Dropbox).
///
/// The 60s timeout applies to **connection establishment only** (DNS + TCP +
/// TLS handshake) via [HttpClient.connectionTimeout]. The response/body
/// transfer is intentionally NOT time-bounded, so large content
/// downloads/uploads run to completion and report progress instead of being
/// aborted on a duration limit.
final http.Client syncHttpClient = IOClient(
  HttpClient()..connectionTimeout = kSyncConnectionTimeout,
);

/// Stream [file] as the body of a pre-configured [request] (headers/content
/// length already set), reporting transfer progress as a 0..1 fraction.
///
/// Uses `sink.addStream`, so a file-read error propagates as a thrown
/// exception instead of being silently dropped (which could truncate the
/// upload or surface as an unhandled async error). The in-flight response
/// future is always awaited so it can never linger as an unhandled future.
Future<http.Response> streamUpload(
  http.StreamedRequest request,
  File file,
  int fileLength,
  void Function(double fraction)? onProgress,
) async {
  final responseFuture = syncHttpClient.send(request);
  var sent = 0;
  Object? pumpError;
  try {
    await request.sink.addStream(file.openRead().map((chunk) {
      sent += chunk.length;
      onProgress?.call(fileLength > 0 ? sent / fileLength : 0);
      return chunk;
    }));
  } catch (e) {
    pumpError = e;
  } finally {
    await request.sink.close();
  }

  final http.StreamedResponse streamed;
  try {
    streamed = await responseFuture;
  } catch (e) {
    throw SyncBackendError('Upload failed: ${pumpError ?? e}');
  }
  if (pumpError != null) {
    throw SyncBackendError('Upload failed reading file: $pumpError');
  }
  return http.Response.fromStream(streamed);
}
