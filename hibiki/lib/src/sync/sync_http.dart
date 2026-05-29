import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

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
