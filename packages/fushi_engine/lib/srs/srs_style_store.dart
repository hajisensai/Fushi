/// 释义样式去重的落盘一侧：共享样式文件 `_fushi_style_<sha1>.css` 放在 profile 的 SRS 媒体目录
/// （`<support>/srs_media/<profileUid>/`，与 app 的 `SrsMediaStore` 同一个目录），于是：
///
/// - 跨设备：随现有媒体同步走（`srs_media_sync.dart` 把字段里的样式引用算进「被引用的媒体」）；
/// - 备份：随「复习」类别的 `srs_media/` 文件树一起打包 / 恢复；
/// - 读：按文件名缓存正文（内容由文件名的哈希决定、永不改变，缓存不会过期）。
///
/// 表示规则（哪些块换、引用行长什么样、合并时怎样视为同值）在 fushi_srs 的 style_dedup.dart。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;

/// 支持目录下的 SRS 媒体根目录名（与 app 的 `kSrsMediaDirName` 相同）。
const String kSrsStyleMediaDirName = 'srs_media';

/// 一个 profile 的共享样式文件库。
class SrsStyleStore {
  SrsStyleStore(this.root);

  /// [supportRoot] 下某 profile 的媒体目录（不创建）。
  static Directory directoryFor(Directory supportRoot, String profileUid) =>
      Directory(p.join(supportRoot.path, kSrsStyleMediaDirName, profileUid));

  /// 本 profile 的媒体目录。
  final Directory root;

  /// 文件名 → 样式正文（最近用过的若干份；一部词典一份，常见集合只有个位数）。
  final Map<String, String> _cache = <String, String>{};
  static const int _cacheCap = 48;

  void _remember(String name, String css) {
    _cache.remove(name);
    _cache[name] = css;
    if (_cache.length > _cacheCap) _cache.remove(_cache.keys.first);
  }

  /// 落一批样式（文件名 → 正文）。已存在且长度相同的不重写；先写临时文件再改名。
  Future<void> saveAll(Map<String, String> styles) async {
    for (final MapEntry<String, String> e in styles.entries) {
      await save(e.key, e.value);
    }
  }

  Future<void> save(String name, String css) async {
    if (!srsIsStyleMediaName(name)) {
      throw ArgumentError.value(name, 'name', 'not a shared style file name');
    }
    final List<int> bytes = utf8.encode(css);
    final File target = File(p.join(root.path, name));
    if (await target.exists() && await target.length() == bytes.length) {
      _remember(name, css);
      return;
    }
    await root.create(recursive: true);
    final File tmp = File(
      '${target.path}.${Random().nextInt(1 << 30).toRadixString(36)}.tmp',
    );
    await tmp.writeAsBytes(bytes, flush: true);
    try {
      await tmp.rename(target.path);
    } on FileSystemException {
      // 并发写同一内容（Windows 上目标已存在时 rename 失败）：内容一样，留现有的。
      if (await tmp.exists()) await tmp.delete();
      if (!await target.exists()) rethrow;
    }
    _remember(name, css);
  }

  /// 读一份样式；不存在、名字不对或内容与文件名的哈希不符（半截 / 损坏）时为 null。
  Future<String?> load(String name) async {
    final String? hit = _cache[name];
    if (hit != null) {
      _remember(name, hit);
      return hit;
    }
    if (!srsIsStyleMediaName(name)) return null;
    final File f = File(p.join(root.path, name));
    if (!await f.exists()) return null;
    final String css;
    try {
      css = utf8.decode(await f.readAsBytes());
    } on FormatException {
      return null;
    }
    if (srsStyleMediaName(css) != name) return null;
    _remember(name, css);
    return css;
  }

  /// 去重并落盘：返回换成引用后的文本（没有可换的块时原样返回）。
  Future<String> compact(String html) async {
    final SrsStyleDedup d = srsDedupStyles(html);
    if (!d.changed) return html;
    await saveAll(d.styles);
    return d.html;
  }

  /// [expand] 的成批版本（与输入同序）：先收齐全部值引用的样式文件名、每个文件只读一次，再逐值同步展开——
  /// 不按字段各等一次读盘（notesInfo 一次几百条笔记 × 每条十几个字段）。
  Future<List<String>> expandAll(
    List<String> htmls, {
    bool dropMissing = false,
  }) async {
    final Set<String> names = <String>{
      for (final String h in htmls) ...srsStyleRefsIn(h),
    };
    if (names.isEmpty) return htmls;
    final Map<String, String> found = <String, String>{};
    for (final String n in names) {
      final String? css = await load(n);
      if (css != null) found[n] = css;
    }
    return <String>[
      for (final String h in htmls)
        srsExpandStyles(h, (String n) => found[n], dropMissing: dropMissing),
    ];
  }

  /// 展开引用（见 [srsExpandStyles]；[dropMissing] 的取舍在那里说明）。
  Future<String> expand(String html, {bool dropMissing = false}) async {
    final Set<String> names = srsStyleRefsIn(html);
    if (names.isEmpty) return html;
    final Map<String, String> found = <String, String>{};
    for (final String n in names) {
      final String? css = await load(n);
      if (css != null) found[n] = css;
    }
    return srsExpandStyles(
      html,
      (String n) => found[n],
      dropMissing: dropMissing,
    );
  }
}
