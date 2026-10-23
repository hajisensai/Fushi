/// mokuro 0.1.x 的**旧版产物**（`<卷名>.html` + `_ocr/<卷名>/` 逐页 JSON）识别。
///
/// mokuro 0.2 之前没有 `.mokuro` 文件：对目录 `<父>/<卷名>/` 跑完 mokuro，产物是
///
/// ```text
/// <父>/<卷名>.html              ← 浏览器里看的阅读页（jidoujisho 等阅读器直接吃它）
/// <父>/<卷名>/001.jpg …         ← 原页图，不动
/// <父>/_ocr/<卷名>/001.json …   ← 逐页 OCR 结果（相对卷目录的路径，扩展名换 .json）
/// ```
///
/// 逐页 JSON 的字段（`img_width` / `img_height` / `blocks[box, vertical, font_size,
/// lines_coords, lines]`）与 `.mokuro` 里每一页**完全同构**，只差 `img_path`。所以
/// 「导入旧版产物」不需要第二套解析：把逐页 JSON 按页序拼回一份 `.mokuro` 形状的
/// 文档（`MangaImporter.legacyMokuroJson`），之后与 `.mokuro` 卷走同一条导入管线。
///
/// mokuro 0.2 仍会写 `_ocr/` 缓存，加 `--legacy_html` 时也会写 `.html`——那时同名
/// `.mokuro` 才是这一卷的 manifest，旧版 html 让位（[legacyMokuroHtmlPathsIn]）。
///
/// 本文件只放**判据**：纯路径函数（可传 [p.url] 给远端来源用）+ 一个本地文件系统
/// 探针。真正的读盘拼装在导入器里（它要复用页图宽高探测）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// mokuro 旧版产物里逐页 OCR 结果的目录名（与 `.html` 同级）。
const String kMokuroLegacyOcrDirName = '_ocr';

/// mokuro 旧版阅读页的扩展名（含点、小写）。
const String kMokuroLegacyHtmlExtension = '.html';

/// [path] 是不是一个 `.html`——只看扩展名。它**本身**不说明是 mokuro 产物，
/// 调用方拿它分派前必须已经过 [isLegacyMokuroHtmlVolume] / [legacyMokuroHtmlPathsIn]
/// 之一（导入器与扫描器的 manifest 清单都只会交来过了判据的路径）。
bool isMokuroLegacyHtmlPath(String path, {p.Context? context}) =>
    (context ?? p.context).extension(path).toLowerCase() ==
    kMokuroLegacyHtmlExtension;

/// 旧版产物 [htmlPath] 对应的页图目录 `<父>/<卷名>`。
String legacyMokuroImageDir(String htmlPath, {p.Context? context}) {
  final p.Context ctx = context ?? p.context;
  return ctx.join(
    ctx.dirname(htmlPath),
    ctx.basenameWithoutExtension(htmlPath),
  );
}

/// 旧版产物 [htmlPath] 对应的逐页 OCR 目录 `<父>/_ocr/<卷名>`。
String legacyMokuroOcrDir(String htmlPath, {p.Context? context}) {
  final p.Context ctx = context ?? p.context;
  return ctx.join(
    ctx.dirname(htmlPath),
    kMokuroLegacyOcrDirName,
    ctx.basenameWithoutExtension(htmlPath),
  );
}

/// 页图相对卷目录的路径 [pageRel]（正斜杠）→ 它在 `_ocr/<卷名>/` 下的 JSON 相对路径：
/// 与 mokuro 0.1 一样保留子目录、只把扩展名换成 `.json`。
String legacyMokuroPageJsonRel(String pageRel) =>
    '${p.url.withoutExtension(pageRel.replaceAll('\\', '/'))}.json';

/// 旧版产物的顶层元数据，与 mokuro 0.2 写进 `.mokuro` 的口径一致：`title` = 卷目录
/// 的上级目录名，`volume` = 卷名。这样同一卷用旧版或新版 mokuro 处理，导入后的标题
/// （进而 bookKey 与重复判据）是同一个。
Map<String, Object?> legacyMokuroRoot(String htmlPath, {p.Context? context}) {
  final p.Context ctx = context ?? p.context;
  return <String, Object?>{
    'title': ctx.basename(ctx.dirname(htmlPath)),
    'volume': ctx.basenameWithoutExtension(htmlPath),
  };
}

/// 本地文件系统判据：[path] 是一份 mokuro 旧版产物——`.html`，且同级既有同名页图
/// 目录、又有 `_ocr/<卷名>/`。只做两次 stat，可在选择器回调里同步调用。
bool isLegacyMokuroHtmlVolume(String path) {
  if (!isMokuroLegacyHtmlPath(path)) return false;
  try {
    return File(path).existsSync() &&
        Directory(legacyMokuroImageDir(path)).existsSync() &&
        Directory(legacyMokuroOcrDir(path)).existsSync();
  } catch (_) {
    return false;
  }
}

/// 纯函数：从已枚举的文件路径 [filePaths] 里挑出该当一卷导入的旧版 html。无 IO。
///
/// 判据只看列表本身（远端来源也能用）：`<父>/<卷名>.html` 在列，且列表里有至少一个
/// 文件落在 `<父>/_ocr/<卷名>/` 之下；同级已有 `<卷名>.mokuro` 的让位给它。不看页图
/// 目录在不在——缺图由导入器给出指名道姓的错误，而不是在这里静默把卷丢掉。
List<String> legacyMokuroHtmlPathsIn(
  Iterable<String> filePaths, {
  p.Context? context,
}) {
  final p.Context ctx = context ?? p.context;
  // 判据在规范化路径上算，交回的是调用方给的**原样**路径（远端 href 不能被改写）。
  final List<String> originals = filePaths.toList();
  final List<String> normalized = <String>[
    for (final String path in originals) ctx.normalize(path),
  ];
  final Set<String> mokuroStems = <String>{
    for (final String path in normalized)
      if (ctx.extension(path).toLowerCase() == '.mokuro')
        ctx.withoutExtension(path).toLowerCase(),
  };
  // `_ocr/<卷名>` 目录集合：取每个文件路径里 `_ocr` 段与其后一段。
  final Set<String> ocrVolumeDirs = <String>{};
  for (final String path in normalized) {
    final List<String> segments = ctx.split(path);
    for (int i = 0; i + 2 < segments.length; i++) {
      if (segments[i] != kMokuroLegacyOcrDirName) continue;
      ocrVolumeDirs.add(ctx.joinAll(segments.sublist(0, i + 2)));
    }
  }
  final List<String> result = <String>[];
  for (int i = 0; i < normalized.length; i++) {
    final String path = normalized[i];
    if (!isMokuroLegacyHtmlPath(path, context: ctx)) continue;
    if (!ocrVolumeDirs.contains(legacyMokuroOcrDir(path, context: ctx))) {
      continue;
    }
    if (mokuroStems.contains(ctx.withoutExtension(path).toLowerCase())) {
      continue;
    }
    result.add(originals[i]);
  }
  return result;
}
