import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi/src/models/woff2_decoder.dart';

/// [clearVerticalBaselineFlag] 的结果：下发的字节与（WOFF2 解码成 sfnt 时的）新 MIME。
typedef VerticalBaselineFontResult = ({Uint8List data, String? mime});

/// 阅读器字体请求用的 [clearVerticalBaselineFlag] 缓存（BUG-3420）。
///
/// WebView 每次请求字体（每章、每个 `@font-face`、每次重排）都会走到这里。改正前每次
/// 都在 UI isolate 上同步跑：WOFF2 每次整包 Brotli 解码 + glyf 重建；带这一位的 sfnt
/// 每次整份复制 + 整文件校验和（CJK 字体动辄 5–20MB）。现在：
/// - 按字体身份（[keyFor]：规范路径 + 大小 + 修改时间）缓存结论，同一字体只处理一次；
///   并发的同一字体请求共用同一个 Future。
/// - 先在当前 isolate 只读表目录（O(表数)）判断要不要改：不带这一位的 sfnt / TTC / WOFF
///   原样返回，不进后台；只有带这一位的、以及只能解码后才知道的 WOFF2，才交给后台
///   isolate（[Isolate.run]，入参复制一次、结果经 `Isolate.exit` 零拷贝带回）。
/// - 只有真改过的字体才在缓存里持有字节，按条数与总字节封顶，先进先出（命中会续期）。
class VerticalBaselineFontCache {
  VerticalBaselineFontCache({
    Future<VerticalBaselineFontResult> Function(Uint8List data)? patcher,
    this.maxEntries = 128,
    this.maxPatchedBytes = 96 * 1024 * 1024,
  }) : _patcher = patcher ?? _patchInBackground;

  /// 缓存的字体条数上限（含不需要改的字体，它们只占一个标记）。
  final int maxEntries;

  /// 缓存里改过的字体字节总量上限。
  final int maxPatchedBytes;

  final Future<VerticalBaselineFontResult> Function(Uint8List data) _patcher;
  final LinkedHashMap<String, Future<_CachedFont>> _entries =
      LinkedHashMap<String, Future<_CachedFont>>();
  final Map<String, int> _patchedBytes = <String, int>{};
  int _totalPatchedBytes = 0;

  /// 字体身份：同一路径的文件被替换（大小或修改时间变化）就是另一个字体。
  static String keyFor(String path, FileStat stat) =>
      '$path|${stat.size}|${stat.modified.microsecondsSinceEpoch}';

  /// 当前缓存的条数（测试用）。
  int get length => _entries.length;

  /// [data] 是 [key] 对应文件的当前字节。命中时不再解析；不需要改的字体原样返回 [data]。
  Future<VerticalBaselineFontResult> resolve({
    required String key,
    required Uint8List data,
  }) async {
    Future<_CachedFont>? entry = _entries.remove(key);
    if (entry != null) {
      _entries[key] = entry; // 续期
    } else {
      entry = _load(key, data);
      _entries[key] = entry;
      _evictEntries();
    }
    final _CachedFont cached;
    try {
      cached = await entry;
    } catch (_) {
      // 失败不留缓存，下次请求重试；异常照常抛给调用方。在这里按 identity 删，而不是在
      // [_load] 里删：[_load] 在第一个 await 之前同步失败时，它的清理会早于上面的登记。
      if (identical(_entries[key], entry)) _entries.remove(key);
      rethrow;
    }
    final Uint8List? patched = cached.data;
    if (patched == null) return (data: data, mime: null);
    return (data: patched, mime: cached.mime);
  }

  Future<_CachedFont> _load(String key, Uint8List data) async {
    if (!_mayCarryVerticalBaselineFlag(data)) return const _CachedFont.clean();
    final VerticalBaselineFontResult result = await _patcher(data);
    if (identical(result.data, data)) return const _CachedFont.clean();
    if (_entries.containsKey(key)) {
      _patchedBytes[key] = result.data.length;
      _totalPatchedBytes += result.data.length;
      _evictBytes(keep: key);
    }
    return _CachedFont(result.data, result.mime);
  }

  void _drop(String key) {
    _entries.remove(key);
    final int? bytes = _patchedBytes.remove(key);
    if (bytes != null) _totalPatchedBytes -= bytes;
  }

  void _evictEntries() {
    while (_entries.length > maxEntries) {
      _drop(_entries.keys.first);
    }
  }

  void _evictBytes({required String keep}) {
    for (final String key in _entries.keys.toList()) {
      if (_totalPatchedBytes <= maxPatchedBytes) return;
      if (key != keep && _patchedBytes.containsKey(key)) _drop(key);
    }
  }

  /// 清空（测试用）。
  void clear() {
    _entries.clear();
    _patchedBytes.clear();
    _totalPatchedBytes = 0;
  }
}

/// 阅读器 WebView 字体请求共用的缓存实例。
final VerticalBaselineFontCache readerVerticalBaselineFontCache =
    VerticalBaselineFontCache();

Future<VerticalBaselineFontResult> _patchInBackground(Uint8List data) =>
    Isolate.run<VerticalBaselineFontResult>(
      () => clearVerticalBaselineFlag(data),
      debugName: 'clearVerticalBaselineFlag',
    );

class _CachedFont {
  const _CachedFont(this.data, this.mime);
  const _CachedFont.clean() : data = null, mime = null;

  /// 改过的字节；null = 不需要改，原样下发。
  final Uint8List? data;
  final String? mime;
}

/// 只读表目录判断 [clearVerticalBaselineFlag] 会不会改这份字体（WOFF2 要解码才知道，算会）。
/// 与 [clearVerticalBaselineFlag] 的判据一一对应：这里返回 false 时那边必然原样返回。
bool _mayCarryVerticalBaselineFlag(Uint8List data) {
  if (data.length < 12) return false;
  final ByteData bytes = ByteData.sublistView(data);
  final int tag = bytes.getUint32(0);
  if (tag == _wOF2) return true;
  if (tag == _ttcf) {
    final int count = bytes.getUint32(8);
    for (int i = 0; i < count; i++) {
      final int at = 12 + i * 4;
      if (at + 4 > data.length) break;
      if (_sfntHeadFlagSet(bytes, data.length, bytes.getUint32(at))) {
        return true;
      }
    }
    return false;
  }
  if (tag == _wOFF) {
    if (data.length < 44) return false;
    final int numTables = bytes.getUint16(12);
    for (int i = 0; i < numTables; i++) {
      final int rec = 44 + i * 20;
      if (rec + 20 > data.length) return false;
      if (bytes.getUint32(rec) != _head) continue;
      final int offset = bytes.getUint32(rec + 4);
      final int compLength = bytes.getUint32(rec + 8);
      final int origLength = bytes.getUint32(rec + 12);
      if (compLength != origLength || origLength < 54) return false;
      if (offset + origLength > data.length) return false;
      return bytes.getUint16(offset + 16) & _flagBit != 0;
    }
    return false;
  }
  if (tag == 0x00010000 || tag == _otto || tag == _true) {
    return _sfntHeadFlagSet(bytes, data.length, 0);
  }
  return false;
}

bool _sfntHeadFlagSet(ByteData src, int length, int start) {
  if (start + 12 > length) return false;
  final int numTables = src.getUint16(start + 4);
  for (int i = 0; i < numTables; i++) {
    final int rec = start + 12 + i * 16;
    if (rec + 16 > length) return false;
    if (src.getUint32(rec) != _head) continue;
    final int offset = src.getUint32(rec + 8);
    final int headLength = src.getUint32(rec + 12);
    if (headLength < 54 || offset + headLength > length) return false;
    return src.getUint16(offset + 16) & _flagBit != 0;
  }
  return false;
}

/// 阅读器加载字体前清掉 `head.flags` 的第 5 位（「x = 0 是竖排基线」）。
///
/// OpenType 规定这一位表示字形按竖排画、x 坐标 0 就是竖排基线。Apple 的 CoreText（iOS /
/// macOS 的 WKWebView）照它办：竖排直立字形不再按字宽左移半个字居中；DirectWrite、
/// FreeType（Windows / Android / Linux）都不看这一位。M PLUS Rounded 1c（字体目录里的推荐
/// 字体）是普通横排字形（x 从 0 画到 1000），却错设了这一位——Apple 上竖排整列字形偏出
/// 自己的行盒半个字（+0.5em，Mac WKWebView 实测，清掉这一位后为 0；给正常字体设上这一位
/// 同样偏 +0.5em），高亮窄条、选区、光标都对不上字，其它平台正常。清掉它让 Apple 与
/// 其它平台画法一致：真按 x = 0 画竖排字形的字体本来就只在 Apple 上画对，三个引擎里有
/// 两个不认这一位。
///
/// 支持 sfnt（TrueType / CFF）、TTC（逐个子字体）、WOFF（head 未压缩时就地改）与 WOFF2
/// （只有确实带这一位时才解码成 sfnt 下发）。没设这一位或解析不了时原样返回、不复制。
/// 改动后同步更新 head 的表目录校验和与 `checkSumAdjustment`。
({Uint8List data, String? mime}) clearVerticalBaselineFlag(Uint8List data) {
  if (data.length < 12) return (data: data, mime: null);
  final ByteData bytes = ByteData.sublistView(data);
  final int tag = bytes.getUint32(0);
  if (tag == _ttcf) {
    final Uint8List? out = _patchCollection(data);
    return (data: out ?? data, mime: null);
  }
  if (tag == _wOFF) {
    final Uint8List? out = _patchWoff(data);
    return (data: out ?? data, mime: null);
  }
  if (tag == _wOF2) {
    // WOFF2 的 head 永远在压缩流里，只能解码后看；没设这一位就原样下发 WOFF2。
    final Uint8List? sfnt = Woff2Decoder.toSfnt(data);
    if (sfnt == null) return (data: data, mime: null);
    final Uint8List? out = _patchSfnt(sfnt, 0, wholeFontChecksum: true);
    if (out == null) return (data: data, mime: null);
    final bool cff = ByteData.sublistView(out).getUint32(0) == _otto;
    return (data: out, mime: cff ? 'font/otf' : 'font/ttf');
  }
  if (tag == 0x00010000 || tag == _otto || tag == _true) {
    final Uint8List? out = _patchSfnt(data, 0, wholeFontChecksum: true);
    return (data: out ?? data, mime: null);
  }
  return (data: data, mime: null);
}

const int _flagBit = 1 << 5;
const int _head = 0x68656164; // 'head'
const int _ttcf = 0x74746366; // 'ttcf'
const int _wOFF = 0x774F4646; // 'wOFF'
const int _wOF2 = 0x774F4632; // 'wOF2'
const int _otto = 0x4F54544F; // 'OTTO'
const int _true = 0x74727565; // 'true'

/// 单个 sfnt（从 [start] 开始的表目录）。需要改时返回副本，否则 null。
Uint8List? _patchSfnt(
  Uint8List data,
  int start, {
  required bool wholeFontChecksum,
  Uint8List? into,
}) {
  final ByteData src = ByteData.sublistView(data);
  if (start + 12 > data.length) return null;
  final int numTables = src.getUint16(start + 4);
  for (int i = 0; i < numTables; i++) {
    final int rec = start + 12 + i * 16;
    if (rec + 16 > data.length) return null;
    if (src.getUint32(rec) != _head) continue;
    final int offset = src.getUint32(rec + 8);
    final int length = src.getUint32(rec + 12);
    if (length < 54 || offset + length > data.length) return null;
    final int flags = src.getUint16(offset + 16);
    if (flags & _flagBit == 0) return null;
    final Uint8List out = into ?? Uint8List.fromList(data);
    final ByteData dst = ByteData.sublistView(out);
    dst.setUint16(offset + 16, flags & ~_flagBit);
    if (wholeFontChecksum) dst.setUint32(offset + 8, 0);
    dst.setUint32(
      rec + 4,
      _tableChecksum(out, offset, length, headTable: true),
    );
    if (wholeFontChecksum) {
      final int sum = _tableChecksum(out, 0, out.length, headTable: false);
      dst.setUint32(offset + 8, (0xB1B0AFBA - sum) & 0xFFFFFFFF);
    }
    return out;
  }
  return null;
}

/// TTC：逐个子字体改（子字体可能共用同一张 head 表，改过就不再改）。
Uint8List? _patchCollection(Uint8List data) {
  final ByteData src = ByteData.sublistView(data);
  if (data.length < 12) return null;
  final int count = src.getUint32(8);
  Uint8List? out;
  for (int i = 0; i < count; i++) {
    final int at = 12 + i * 4;
    if (at + 4 > data.length) break;
    final Uint8List? patched = _patchSfnt(
      out ?? data,
      src.getUint32(at),
      wholeFontChecksum: false,
      into: out,
    );
    if (patched != null) out = patched;
  }
  return out;
}

/// WOFF 1：head 表没压缩（compLength == origLength）时就地改并更新 origChecksum；
/// 压缩了就原样返回（WOFF 1 下这种 head 极少见）。
Uint8List? _patchWoff(Uint8List data) {
  final ByteData src = ByteData.sublistView(data);
  if (data.length < 44) return null;
  final int numTables = src.getUint16(12);
  for (int i = 0; i < numTables; i++) {
    final int rec = 44 + i * 20;
    if (rec + 20 > data.length) return null;
    if (src.getUint32(rec) != _head) continue;
    final int offset = src.getUint32(rec + 4);
    final int compLength = src.getUint32(rec + 8);
    final int origLength = src.getUint32(rec + 12);
    if (compLength != origLength || origLength < 54) return null;
    if (offset + origLength > data.length) return null;
    final int flags = src.getUint16(offset + 16);
    if (flags & _flagBit == 0) return null;
    final Uint8List out = Uint8List.fromList(data);
    final ByteData dst = ByteData.sublistView(out);
    dst.setUint16(offset + 16, flags & ~_flagBit);
    dst.setUint32(
      rec + 16,
      _tableChecksum(out, offset, origLength, headTable: true),
    );
    return out;
  }
  return null;
}

/// OpenType 表校验和：按大端 uint32 求和（不足 4 字节补 0）。head 表计算时
/// `checkSumAdjustment`（偏移 8）按 0 算。
int _tableChecksum(
  Uint8List data,
  int offset,
  int length, {
  required bool headTable,
}) {
  int sum = 0;
  final int end = offset + length;
  for (int i = offset; i < end; i += 4) {
    int word = 0;
    for (int k = 0; k < 4; k++) {
      word = (word << 8) | (i + k < end ? data[i + k] : 0);
    }
    if (headTable && i - offset == 8) word = 0;
    sum = (sum + word) & 0xFFFFFFFF;
  }
  return sum;
}
