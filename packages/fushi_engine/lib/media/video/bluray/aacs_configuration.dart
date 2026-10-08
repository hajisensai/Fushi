import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Uses the shared app/headless proxy policy; tests may override or disable it.
Future<http.Client> Function()? aacsHttpClientFactory = () async =>
    createAppHttpIoClient();

/// Explicit local configuration is authoritative, including a missing match.
String? aacsKeyDbPathOverride;

/// 测试用：替换平台标准 KEYDB 位置（真实位置在用户目录下，测试既不能写也
/// 不该读到开发机上的真实文件）。
@visibleForTesting
List<String>? aacsStandardConfigurationsForTesting;

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

/// 只约束**下载来**的压缩包解出的大小（不可信网络输入防解压炸弹）；
/// 本地 KEYDB 走流式扫描，不设大小上限。
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
    final io.File file = io.File(override);
    if (!await file.exists()) {
      throw const AacsConfigurationException(
        AacsConfigurationError.missingConfiguration,
      );
    }
    final Uint8List? key;
    try {
      key = await _scanKeyDb(file, discId);
    } on io.FileSystemException {
      // 显式指定的文件是唯一权威来源：读不了就是配置本身坏了。
      throw const AacsConfigurationException(
        AacsConfigurationError.invalidConfiguration,
      );
    }
    if (key == null) {
      throw const AacsConfigurationException(
        AacsConfigurationError.discNotMatched,
      );
    }
    return (unitKeyFile: unitBytes, volumeUniqueKey: key);
  }

  final io.Directory support = await enginePaths.supportRootDirectory();
  final io.File cache = io.File(p.join(support.path, 'aacs', 'keydb.cfg'));
  bool sawUnreadable = false;
  for (final String candidate in [..._standardConfigurations(), cache.path]) {
    final io.File file = io.File(candidate);
    try {
      if (!await file.exists()) continue;
      final Uint8List? key = await _scanKeyDb(file, discId);
      if (key != null) return (unitKeyFile: unitBytes, volumeUniqueKey: key);
    } on io.FileSystemException {
      // 回退链上的一个候选读不了（ACL 拒读、IO 错误）只说明这一处不可用，
      // 不代表配置无效：继续问下一个候选、应用缓存，最后才下载。
      sawUnreadable = true;
    }
  }
  if (aacsHttpClientFactory == null) {
    throw AacsConfigurationException(
      sawUnreadable
          ? AacsConfigurationError.invalidConfiguration
          : AacsConfigurationError.missingConfiguration,
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
  final List<String>? forTesting = aacsStandardConfigurationsForTesting;
  if (forTesting != null) return forTesting;
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

/// 一行 KEYDB 条目：`<discId> = <title> | … | V | <VUK> …`。KEYDB 的条目从不跨行，
/// 所以逐行匹配与整文件多行匹配等价。
final RegExp _keyDbEntry = RegExp(
  r'^\s*(?:0x)?([0-9a-f]{40})\s*=.*?\|\s*V\s*\|\s*(?:0x)?([0-9a-f]{32})(?=\s|\||$)',
  caseSensitive: false,
);

/// 在本地 KEYDB 里逐行流式找本盘的 VUK。
///
/// 完整版 KEYDB 可达上百 MB：整读进内存再正则，既让内存随文件大小涨，又逼出
/// 「超过上限就判配置无效」这条人为边界——它会把合法的完整库当坏文件，并截断
/// 后面的缓存 / 下载回退。流式扫描的内存与文件大小无关，命中即停。
/// 读不了（权限 / IO 错误）照实抛 [io.FileSystemException]，由调用方按来源定性。
///
/// 用 [io.RandomAccessFile] 分块读而不是 `openRead()`：实测 Windows 上被别的句柄
/// 字节锁住的文件（errno 33），`openRead()` 的流既不报错也不结束、句柄一直占着，
/// 播放就挂死在这里；`read()` 则如实抛 [io.FileSystemException]。
Future<Uint8List?> _scanKeyDb(io.File file, String discId) async {
  final io.RandomAccessFile handle = await file.open();
  try {
    // Latin-1 一字节一字符：块边界切不坏字符，只需把末尾半行留到下一块。
    String carry = '';
    while (true) {
      final Uint8List chunk = await handle.read(_keyDbScanChunkBytes);
      if (chunk.isEmpty) return _findKeyInText(carry, discId);
      final String text = carry + latin1.decode(chunk);
      final int lastBreak = text.lastIndexOf('\n');
      final Uint8List? key = lastBreak < 0
          ? null
          : _findKeyInText(text.substring(0, lastBreak), discId);
      if (key != null) return key;
      carry = text.substring(lastBreak + 1);
      // 没有换行的超长残段不可能是一条 KEYDB 条目（例如误放的二进制文件），
      // 丢掉它，内存才真的与文件大小无关。
      if (carry.length > _keyDbScanChunkBytes) carry = '';
    }
  } finally {
    await handle.close();
  }
}

const int _keyDbScanChunkBytes = 1024 * 1024;

Uint8List? _findKey(Uint8List bytes, String discId) =>
    _findKeyInText(latin1.decode(bytes), discId);

// Latin-1 preserves ASCII syntax even when provider titles use legacy bytes.
//
// 先在小写副本里做原生子串搜索找盘 ID，只对命中的那一行跑正则：逐行正则在上百
// MB 的完整库上要跑几十秒到几分钟（CI 上 65 MiB 实测超过 2 分钟），而本函数在制卡
// 时跑在 UI isolate 上。Latin-1 字符的小写映射不改长度，副本下标可直接用于原文。
Uint8List? _findKeyInText(String text, String discId) {
  final String lower = text.toLowerCase();
  int from = 0;
  while (true) {
    final int hit = lower.indexOf(discId, from);
    if (hit < 0) return null;
    final int start = lower.lastIndexOf('\n', hit) + 1;
    int end = lower.indexOf('\n', hit);
    if (end < 0) end = lower.length;
    final Uint8List? key = _matchKeyDbLine(text.substring(start, end), discId);
    if (key != null) return key;
    from = end;
  }
}

Uint8List? _matchKeyDbLine(String line, String discId) {
  final RegExpMatch? match = _keyDbEntry.firstMatch(line);
  if (match == null || match.group(1)!.toLowerCase() != discId) return null;
  final String hex = match.group(2)!;
  return Uint8List.fromList([
    for (int index = 0; index < 32; index += 2)
      int.parse(hex.substring(index, index + 2), radix: 16),
  ]);
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
