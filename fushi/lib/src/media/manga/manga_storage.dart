import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi/src/epub/epub_storage.dart';
import 'package:fushi/src/utils/misc/safe_file_name.dart';

/// 漫画导入失败时抛出的领域异常：非法的 Mokuro 文件夹、路径穿越、缺图等。
///
/// 与通用 `Exception` 区分，让导入对话框可以给出可读的错误文案，也让测试能精确断言。
class MangaImportException implements Exception {
  /// 用可读 [message] 构造。
  const MangaImportException(this.message);

  /// 面向用户/日志的错误描述。
  final String message;

  @override
  String toString() => 'MangaImportException: $message';
}

/// 管理 mokuro 漫画的磁盘产物。
///
/// 漫画 = `EpubBooks` 里 `format=='manga'` 的行（第三种「书」），与 PDF 共用同一数据根
/// 惯例（`<documents>/fushi_books/<bookKey>/`）。故书目录规划直接复用 [EpubStorage]，不另
/// 建 `hoshi_manga` 平行根——书架/进度/删除全部零改动复用 EPUB 管线。
///
/// 布局：`<fushi_books>/<bookKey>/`
///   - `images/<保留 img_path 相对子目录结构>`（防跨子目录同名页互相覆盖）
///   - `manga.json`（序列化后的页/框结构，`EpubBooks.epubPath` 列指向此文件名）
///
/// 本类只负责纯路径规划与穿越防护（无平台通道、无 async 探测），便于单测。实际拷贝/写盘/
/// 落库/回滚由 `MangaImporter` 编排。
class MangaStorage {
  MangaStorage._();

  /// 书目录内固定的页/框结构文件名。阅读器按 `extractDir/epubPath` 还原绝对路径，故此名
  /// 必须与写进 `EpubBooks.epubPath` 列的值一致。
  static const String kMangaJsonFileName = 'manga.json';

  /// 书目录内页图的固定子目录名。
  static const String kImagesDirName = 'images';

  /// 新书的书目录（按 [bookKey]）。不存在则创建。与 PDF 同惯例（复用
  /// [EpubStorage.bookDirectory]）。
  static Future<String> bookDirectory(String bookKey) =>
      EpubStorage.bookDirectory(bookKey);

  /// 新书的书目录路径——**不**创建目录。
  static Future<String> bookPath(String bookKey) =>
      EpubStorage.bookPath(bookKey);

  /// 按绝对 [extractDir] 删除书目录（回滚/删书用）。
  static Future<void> deleteBookDir(String extractDir) =>
      EpubStorage.deleteBookDir(extractDir);

  /// 把一个相对 `img_path`（[raw]）逐段 sanitize 成**正斜杠**相对段序列，**保留子目录
  /// 结构**（防跨卷同名页互相覆盖），并剥离冗余的首个 `images/` 段（多数样本 img_path 已带
  /// 该前缀，避免落盘成 `images/images/...`）。
  ///
  /// 防路径穿越（红线）：任一段是 `..` 直接抛 [MangaImportException]——绝不静默丢弃，
  /// 让含穿越的整本导入硬失败。每段把 Windows 非法字符（[windowsUnsafeFileNameChars]，
  /// 段内不可能再含 `\ /`——已按其切分）替换为 `_`；`.` 段与空段丢弃。返回 segments
  /// （非已 join 的路径）让调用方既能 `p.joinAll` 落盘（平台分隔符），又能 `'/'.join`
  /// 写进 manga.json 的 `url`（跨平台正斜杠）。
  static List<String> sanitizeRelSegments(String raw) {
    final List<String> rawSegments = raw.split(RegExp(r'[\\/]+'));
    for (final String s in rawSegments) {
      if (s.trim() == '..') {
        throw MangaImportException('Unsafe manga image path (traversal): $raw');
      }
    }
    final List<String> segments = rawSegments
        .where((String s) => s.isNotEmpty && s != '.')
        .map((String s) => safeWindowsFileName(s).trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    if (segments.isNotEmpty && segments.first.toLowerCase() == kImagesDirName) {
      segments.removeAt(0);
    }
    if (segments.isEmpty) return <String>['image'];
    return segments;
  }

  /// 在 [used]（小写规范化键集合）内为 [segments] 取唯一 destRel：碰撞时给末段（basename）
  /// 插入 ` (2)`/` (3)`… 后缀。返回正斜杠相对路径（含 `images/` 前缀，不含 `..`），并把
  /// 规范化结果记进 [used]。Windows 文件系统大小写不敏感，故用小写键去重。
  static String uniqueDestRel(List<String> segments, Set<String> used) {
    final List<String> base = <String>[kImagesDirName, ...segments];
    String candidate = base.join('/');
    String key = candidate.toLowerCase();
    if (!used.contains(key)) {
      used.add(key);
      return candidate;
    }
    final String last = segments.last;
    final int dot = last.lastIndexOf('.');
    final String stem = dot > 0 ? last.substring(0, dot) : last;
    final String ext = dot > 0 ? last.substring(dot) : '';
    final List<String> prefix = <String>[
      kImagesDirName,
      ...segments.sublist(0, segments.length - 1),
    ];
    for (int i = 2;; i++) {
      candidate = <String>[...prefix, '$stem ($i)$ext'].join('/');
      key = candidate.toLowerCase();
      if (!used.contains(key)) {
        used.add(key);
        return candidate;
      }
    }
  }

  /// 把 [destRel]（正斜杠、含 `images/` 前缀）解析成 [bookDir] 下的平台分隔符绝对
  /// [File]。用于落盘与封面定位。
  static File destFile(String bookDir, String destRel) =>
      File(p.joinAll(<String>[bookDir, ...destRel.split('/')]));

  /// 书目录（`extractDir`）下的页图根：`<bookDir>/images`。
  ///
  /// 阅读器算的是 `dirname(extractDir/epubPath)/images`，而 `epubPath` 恒是书目录
  /// 直属的 [kMangaJsonFileName]，两者等价。互联 host 供图时也必须落在这个根内。
  static Directory imagesDirectory(String bookDir) =>
      Directory(p.join(bookDir, kImagesDirName));

  /// `manga.json` 里的 `url` → 相对 [imagesDirectory] 的正斜杠路径。
  ///
  /// 本仓两种存量写法都要吃：本仓导入器写的是含 `images/` 前缀的相对路径，旧版
  /// `.mokuro` 直接写 `foo.jpg`。
  static String pageRelativePath(String storedUrl) {
    String normalized = storedUrl.replaceAll(r'\', '/');
    while (normalized.startsWith('./')) {
      normalized = normalized.substring(2);
    }
    if (normalized.toLowerCase().startsWith('$kImagesDirName/')) {
      return normalized.substring(kImagesDirName.length + 1);
    }
    return normalized;
  }

  /// 纯路径解析 + 穿越守卫：[relative] 在 [imagesRoot] 内解析到**存在的**文件时返回
  /// 规范绝对路径（保留磁盘真实大小写），越界或缺文件一律 null。
  ///
  /// BUG-1221 的两种路径形式必须并存：越界判定用 `p.canonicalize`（Windows 上整体
  /// 小写化，`../` 逃逸不会被大小写差异绕过），返回值用 `p.absolute` + `p.normalize`
  /// （同样绝对化并折叠 `.`/`..`，但保留大小写——返回值会流出本次读取，被制卡当作
  /// Anki 封面源路径，小写化会让大小写敏感平台上 `existsSync` 直接 false）。
  ///
  /// 归位到本层（原先是阅读器 widget 的静态方法）是因为互联 host 供图必须用**同一条**
  /// 穿越守卫：安全边界靠复制粘贴维持，抄漏一处就是真漏洞。
  static String? resolvePageFilePath(String imagesRoot, String relative) {
    final String decoded = Uri.decodeComponent(relative);
    final String joined = p.join(imagesRoot, decoded);
    if (!p.isWithin(p.canonicalize(imagesRoot), p.canonicalize(joined))) {
      return null;
    }
    final String filePath = p.normalize(p.absolute(joined));
    if (!File(filePath).existsSync()) return null;
    return filePath;
  }
}
