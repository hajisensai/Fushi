import 'dart:io';

import 'package:path/path.dart' as p;

/// 一次自愈的统计（日志用）。
class AudiobookRelocationStats {
  int repaired = 0;
  int ambiguous = 0;
  int unresolved = 0;

  bool get isEmpty => repaired == 0 && ambiguous == 0 && unresolved == 0;

  @override
  String toString() =>
      'repaired=$repaired ambiguous=$ambiguous unresolved=$unresolved';
}

/// BUG-1575：把「指向**旧**数据根 / 旧包私有目录」的有声书路径重指到当前
/// `<documents>/audiobooks` 下真实存在的文件。
///
/// 为什么需要它：备份合并导入把行**逐列原样**插进本机库，路径 rebase 只在
/// 「备份 meta 记了源根 **且** 源根前缀与行里的前缀真的对得上」时才生效。跨包名
/// 迁移（hibiki → fushi）踩中过两种漏：一是这侧压根没遍历 `srt_books`（本 BUG 的
/// 根因），二是 meta 记的根名与行里的前缀对不上时 rebase **静默原样返回**（同
/// `BackupService._resolveExtractDirOnDevice` 记的形态）。已经落到用户库里的坏行
/// 无法再靠「改导入代码」修复，只能在读取侧自愈。
///
/// 三条判据，顺序即优先级：
///  1. **原路径在磁盘上存在 → 一律不动**。自愈天然幂等，跑几遍结果一样。
///  2. **只碰 app 自管路径**：路径里必须含 `audiobooks` 这一段。桌面「引用导入」
///     存的是用户自己目录下的原始文件绝对路径，那种断链只能由用户重新定位，
///     按文件名去 audiobooks 根里猜等于指到别的书的同名章节文件上。
///  3. 先**后缀重锚**再**唯一同名**：搬移保留 `<root>` 以下的相对结构，所以
///     `<旧根>/audiobooks/<dir>/01.mp3` → `<当前根>/<dir>/01.mp3` 是确定解，
///     没有歧义；只有它落空才退回全树按 basename 找，且**命中多个就不猜**
///     （宁可让用户手动重定位，也不能指错书）。多本有声书里叫 `01.mp3` 的章节
///     文件遍地都是，只有 basename 一条规则救不了真实用户。
class AudiobookPathRelocator {
  AudiobookPathRelocator({
    required this.audiobooksRoot,
    bool Function(String path)? exists,
    List<String> Function(String root)? listEntries,
  })  : _exists = exists ?? defaultExists,
        _listEntries = listEntries ?? _defaultListEntries;

  /// 数据根内有声书子目录名（`AppPaths.audiobooksDirectory` / `app_model` 的
  /// `audioDatabaseRoot` 同名，两处都是 `<documents>/audiobooks`）。
  static const String rootSegment = 'audiobooks';

  /// 当前设备的 `<documents>/audiobooks` 绝对路径。
  final String audiobooksRoot;

  final bool Function(String path) _exists;
  final List<String> Function(String root) _listEntries;

  /// 全树 basename -> 绝对路径列表，**惰性**构建：所有路径都有效时一次都不扫。
  Map<String, List<String>>? _byBasename;

  final AudiobookRelocationStats stats = AudiobookRelocationStats();

  /// 文件与目录一视同仁（`audio_root` 存的是目录），所以判据是「这个位置上有
  /// 东西」而不是 `File.existsSync`。
  static bool defaultExists(String path) =>
      FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;

  static List<String> _defaultListEntries(String root) {
    final Directory dir = Directory(root);
    if (!dir.existsSync()) return const <String>[];
    return dir
        .listSync(recursive: true, followLinks: false)
        .map((FileSystemEntity e) => e.path)
        .toList();
  }

  /// 分隔符无关地切段：备份来自别的平台时行里可能是 `\`，本机是 `/`（反之亦然）。
  static List<String> segmentsOf(String path) => path
      .split(RegExp(r'[/\\]+'))
      .where((String s) => s.isNotEmpty)
      .toList(growable: false);

  static String? _basenameOf(String path) {
    final List<String> segs = segmentsOf(path);
    return segs.isEmpty ? null : segs.last;
  }

  /// 返回修好的路径；**返回 null 表示保持原值**（原路径有效 / 不是 app 自管路径 /
  /// 无法唯一确定落点）。
  String? relocate(String path) {
    if (path.isEmpty) return null;
    if (_exists(path)) return null;
    final List<String> segs = segmentsOf(path);
    final int anchor = segs.lastIndexOf(rootSegment);
    if (anchor < 0) return null;

    final String? reanchored = _reanchor(segs, anchor);
    if (reanchored != null) {
      stats.repaired++;
      return reanchored;
    }
    final String? byName = _byUniqueBasename(path);
    if (byName != null) {
      stats.repaired++;
      return byName;
    }
    return null;
  }

  /// 从**最后**一个 `audiobooks` 段往前逐个试：把该段之后的相对结构原样挂到当前
  /// 根下。用户目录里恰好也有 `audiobooks` 目录时，靠「候选必须真实存在」兜住。
  String? _reanchor(List<String> segs, int lastAnchor) {
    for (int i = lastAnchor; i >= 0; i--) {
      if (segs[i] != rootSegment) continue;
      final List<String> rest = segs.sublist(i + 1);
      if (rest.isEmpty) continue;
      final String candidate = p.join(audiobooksRoot, p.joinAll(rest));
      if (_exists(candidate)) return candidate;
    }
    return null;
  }

  String? _byUniqueBasename(String path) {
    final String? name = _basenameOf(path);
    if (name == null) return null;
    final Map<String, List<String>> index = _byBasename ??= _buildIndex();
    final List<String>? hits = index[name];
    if (hits == null || hits.isEmpty) {
      stats.unresolved++;
      return null;
    }
    if (hits.length > 1) {
      stats.ambiguous++;
      return null;
    }
    return hits.single;
  }

  Map<String, List<String>> _buildIndex() {
    final Map<String, List<String>> out = <String, List<String>>{};
    for (final String entry in _listEntries(audiobooksRoot)) {
      final String? name = _basenameOf(entry);
      if (name == null) continue;
      (out[name] ??= <String>[]).add(entry);
    }
    return out;
  }
}
