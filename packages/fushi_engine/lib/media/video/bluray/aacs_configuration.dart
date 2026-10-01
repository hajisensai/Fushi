import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Uses the shared app/headless proxy policy; tests may override or disable it.
Future<http.Client> Function()? aacsHttpClientFactory = () async =>
    createAppHttpIoClient();

/// Explicit local configuration is authoritative, including a missing match.
String? aacsKeyDbPathOverride;

/// The database provider documented by LibreELEC's Blu-ray playback guide.
/// Its fv_download.php?reduced endpoint redirects to this same-host archive.
const String aacsConfigurationDownloadUrl =
    'https://fvonline-db.bplaced.net/export/keydb_red.zip';

enum AacsConfigurationError {
  missingConfiguration,
  networkFailure,
  unsupportedDisc,
  discNotMatched,
  invalidConfiguration,
}

class AacsConfigurationException implements Exception {
  const AacsConfigurationException(this.code);
  final AacsConfigurationError code;

  @override
  String toString() => 'AacsConfigurationException(${code.name})';
}

const int _maxConfigurationBytes = 64 * 1024 * 1024;
const int _maxDownloadBytes = 24 * 1024 * 1024;
final Map<String, Future<Uint8List>> _downloads = {};
final Map<String, DateTime> _downloadedAt = {};

/// Loads only an exact disc-ID VUK; titles never establish identity.
Future<({Uint8List unitKeyFile, Uint8List volumeUniqueKey})>
loadAacsConfiguration(String discRoot) async {
  if (await io.Directory(p.join(discRoot, 'AACS2')).exists() ||
      await io.Directory(p.join(discRoot, 'BDSVM')).exists()) {
    throw const AacsConfigurationException(
      AacsConfigurationError.unsupportedDisc,
    );
  }
  final io.File unitFile = io.File(p.join(discRoot, 'AACS', 'Unit_Key_RO.inf'));
  final Uint8List unitBytes;
  try {
    if (!await unitFile.exists() ||
        await unitFile.length() < 16 ||
        await unitFile.length() > 1024 * 1024) {
      throw const AacsConfigurationException(
        AacsConfigurationError.unsupportedDisc,
      );
    }
    unitBytes = await unitFile.readAsBytes();
  } on io.FileSystemException {
    throw const AacsConfigurationException(
      AacsConfigurationError.unsupportedDisc,
    );
  }
  final String discId = sha1.convert(unitBytes).toString();
  final String? override = aacsKeyDbPathOverride;
  if (override != null) {
    final Uint8List? key = await _readMatch(io.File(override), discId);
    if (key == null) {
      throw AacsConfigurationException(
        await io.File(override).exists()
            ? AacsConfigurationError.discNotMatched
            : AacsConfigurationError.missingConfiguration,
      );
    }
    return (unitKeyFile: unitBytes, volumeUniqueKey: key);
  }

  final io.Directory support = await enginePaths.supportRootDirectory();
  final io.File cache = io.File(p.join(support.path, 'aacs', 'keydb.cfg'));
  for (final String candidate in [..._standardConfigurations(), cache.path]) {
    final Uint8List? key = await _readMatch(io.File(candidate), discId);
    if (key != null) return (unitKeyFile: unitBytes, volumeUniqueKey: key);
  }
  if (aacsHttpClientFactory == null) {
    throw const AacsConfigurationException(
      AacsConfigurationError.missingConfiguration,
    );
  }
  // Avoid repeatedly downloading for discs absent from a freshly fetched DB.
  final DateTime? fetchedAt = _downloadedAt[cache.path];
  if (fetchedAt != null &&
      DateTime.now().difference(fetchedAt) < const Duration(hours: 6)) {
    throw const AacsConfigurationException(
      AacsConfigurationError.discNotMatched,
    );
  }
  final Future<Uint8List> download = _downloads.putIfAbsent(
    cache.path,
    () => _downloadConfiguration(cache),
  );
  final Uint8List database;
  try {
    database = await download;
  } finally {
    if (identical(_downloads[cache.path], download)) {
      _downloads.remove(cache.path);
    }
  }
  final Uint8List? key = _findKey(database, discId);
  if (key == null) {
    throw const AacsConfigurationException(
      AacsConfigurationError.discNotMatched,
    );
  }
  return (unitKeyFile: unitBytes, volumeUniqueKey: key);
}

List<String> _standardConfigurations() {
  final Map<String, String> env = io.Platform.environment;
  final List<String> roots = [];
  if (io.Platform.isWindows) {
    for (final String name in ['APPDATA', 'PROGRAMDATA']) {
      final String? root = env[name];
      if (root != null && root.isNotEmpty) roots.add(p.join(root, 'aacs'));
    }
  } else if (!io.Platform.isAndroid && !io.Platform.isIOS) {
    final String? home = env['HOME'];
    final String? xdg = env['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.isNotEmpty) roots.add(p.join(xdg, 'aacs'));
    if (home != null && home.isNotEmpty) {
      roots.add(p.join(home, '.config', 'aacs'));
      if (io.Platform.isMacOS) {
        roots.add(p.join(home, 'Library', 'Preferences', 'aacs'));
      }
    }
  }
  return [
    for (final String root in roots)
      for (final String name in ['KEYDB.cfg', 'keydb.cfg']) p.join(root, name),
  ];
}

Future<Uint8List?> _readMatch(io.File file, String discId) async {
  try {
    if (!await file.exists()) return null;
    if (await file.length() > _maxConfigurationBytes) {
      throw const AacsConfigurationException(
        AacsConfigurationError.invalidConfiguration,
      );
    }
    return _findKey(await file.readAsBytes(), discId);
  } on io.FileSystemException {
    throw const AacsConfigurationException(
      AacsConfigurationError.invalidConfiguration,
    );
  }
}

Uint8List? _findKey(Uint8List bytes, String discId) {
  // Latin-1 preserves ASCII syntax even when provider titles use legacy bytes.
  final RegExp entry = RegExp(
    r'^\s*(?:0x)?([0-9a-f]{40})\s*=.*?\|\s*V\s*\|\s*(?:0x)?([0-9a-f]{32})(?=\s|\||$)',
    caseSensitive: false,
    multiLine: true,
  );
  for (final RegExpMatch match in entry.allMatches(latin1.decode(bytes))) {
    if (match.group(1)!.toLowerCase() != discId) continue;
    final String hex = match.group(2)!;
    return Uint8List.fromList([
      for (int index = 0; index < 32; index += 2)
        int.parse(hex.substring(index, index + 2), radix: 16),
    ]);
  }
  return null;
}

Future<Uint8List> _downloadConfiguration(io.File cache) async {
  http.Client? client;
  io.File? temporary;
  try {
    client = await aacsHttpClientFactory!();
    final http.Request request = http.Request(
      'GET',
      Uri.parse(aacsConfigurationDownloadUrl),
    )..followRedirects = false;
    final http.StreamedResponse response = await client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200 ||
        (response.contentLength ?? 0) > _maxDownloadBytes) {
      throw const AacsConfigurationException(
        AacsConfigurationError.networkFailure,
      );
    }
    final Uint8List zip = await _boundedBytes(
      response.stream,
      _maxDownloadBytes,
    ).timeout(const Duration(minutes: 2));
    final Uint8List database = await _extractDatabase(zip);
    await cache.parent.create(recursive: true);
    temporary = io.File(
      '${cache.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temporary.writeAsBytes(database, flush: true);
    await temporary.rename(cache.path);
    _downloadedAt[cache.path] = DateTime.now();
    return database;
  } on AacsConfigurationException {
    rethrow;
  } catch (_) {
    // Never include response/configuration content or exception payloads.
    throw const AacsConfigurationException(
      AacsConfigurationError.networkFailure,
    );
  } finally {
    client?.close();
    if (temporary != null && await temporary.exists()) {
      await temporary.delete();
    }
  }
}

Future<Uint8List> _boundedBytes(Stream<List<int>> source, int limit) async {
  final BytesBuilder builder = BytesBuilder(copy: false);
  await for (final List<int> chunk in source) {
    if (builder.length + chunk.length > limit) {
      throw const AacsConfigurationException(
        AacsConfigurationError.invalidConfiguration,
      );
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Future<Uint8List> _extractDatabase(Uint8List bytes) async {
  try {
    // Bound entry counts before archive parses/allocates central-directory
    // objects. This provider publishes a single ordinary (non-ZIP64) file.
    final ByteData zipHeader = ByteData.sublistView(bytes);
    int endRecord = -1;
    for (
      int offset = bytes.length - 22;
      offset >= 0 && offset >= bytes.length - 65557;
      offset--
    ) {
      if (zipHeader.getUint32(offset, Endian.little) == 0x06054b50 &&
          offset + 22 + zipHeader.getUint16(offset + 20, Endian.little) ==
              bytes.length) {
        endRecord = offset;
        break;
      }
    }
    if (endRecord < 0 ||
        zipHeader.getUint16(endRecord + 4, Endian.little) != 0 ||
        zipHeader.getUint16(endRecord + 6, Endian.little) != 0 ||
        zipHeader.getUint16(endRecord + 8, Endian.little) != 1 ||
        zipHeader.getUint16(endRecord + 10, Endian.little) != 1 ||
        zipHeader.getUint32(endRecord + 12, Endian.little) > 65536 ||
        zipHeader.getUint32(endRecord + 16, Endian.little) > endRecord) {
      throw const FormatException();
    }
    final ZipDirectory directory = ZipDirectory.read(InputStream(bytes));
    if (directory.fileHeaders.length != 1) {
      throw const FormatException();
    }
    final ZipFileHeader header = directory.fileHeaders.single;
    final ZipFile file = header.file!;
    if (header.filename.toLowerCase() != 'keydb.cfg' ||
        file.filename.toLowerCase() != 'keydb.cfg' ||
        (header.externalFileAttributes! >> 16 & 0xf000) == 0xa000 ||
        (header.generalPurposeBitFlag & 1) != 0 ||
        (file.flags & 1) != 0 ||
        header.uncompressedSize! <= 0 ||
        header.uncompressedSize! > _maxConfigurationBytes ||
        header.uncompressedSize! > bytes.length * 100 ||
        ![0, 8].contains(file.compressionMethod)) {
      throw const FormatException();
    }
    final Uint8List compressed = file.rawContent!.toUint8List();
    final Stream<List<int>> raw = Stream<List<int>>.value(compressed);
    final Uint8List decoded = await _boundedBytes(
      file.compressionMethod == 8
          ? raw.transform(io.ZLibDecoder(raw: true))
          : raw,
      _maxConfigurationBytes,
    );
    if (decoded.length != header.uncompressedSize ||
        getCrc32(decoded) != header.crc32) {
      throw const FormatException();
    }
    // Reject HTML error pages and unrelated payloads even inside a valid ZIP.
    if (!RegExp(
      r'^\s*(?:0x)?[0-9a-fA-F]{40}\s*=',
      multiLine: true,
    ).hasMatch(latin1.decode(decoded))) {
      throw const FormatException();
    }
    return decoded;
  } catch (_) {
    throw const AacsConfigurationException(
      AacsConfigurationError.invalidConfiguration,
    );
  }
}
