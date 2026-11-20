/// 系统 / 垃圾条目的**唯一**判据：回收站、系统卷信息、NAS / macOS 的索引与缩略图
/// 目录，以及 macOS AppleDouble 资源叉文件。
///
/// 来源库扫描（app `isSourceScanJunkPath`）、漫画卷归组的 `dart:io` 入口
/// （`planMangaFoldersInDirectory`，无头服务端库扫描与导入命令都走它）、页图枚举
/// （`enumerateMangaPages`）都问这里。此前三处各写一份：扫描器认 `@eaDir` 不认
/// `__MACOSX`，页图枚举只认这两个，卷归组一个都不认——同一棵 NAS 目录树在 app 上
/// 归出 N 卷，在服务端多出一卷 `@eaDir/<页名>/` 的缩略图「卷」（BUG-4907 同根因）。
library;

/// 目录名（小写比较）整棵不扫。里面的文件要么是别的东西的残骸（回收站里的
/// `$Rxxxx.mkv`），要么根本不是内容（群晖 `@eaDir/<页名>/SYNOPHOTO_THUMB_*.jpg`
/// 每页一张缩略图；macOS 压缩包解开的 `__MACOSX/` 资源叉残渣）。
const Set<String> kSystemJunkDirectoryNames = <String>{
  r'$recycle.bin',
  'recycler',
  'system volume information',
  '@eadir',
  '#recycle',
  '@recycle',
  '@recently-snapshot',
  '__macosx',
  '.trash',
  '.trashes',
  '.spotlight-v100',
  '.fseventsd',
  '.temporaryitems',
  '.documentrevisions-v100',
  'lost+found',
};

/// 目录名 [name]（单段，不含分隔符）是不是系统 / 垃圾目录：在
/// [kSystemJunkDirectoryNames] 里（不分大小写），或是 Linux 的 `.Trash-<uid>`。
///
/// 不一刀切丢所有 `.` 开头的名字（`.hidden/` 里放媒体是合法用法）。
bool isSystemJunkDirectoryName(String name) {
  final String lower = name.toLowerCase();
  return kSystemJunkDirectoryNames.contains(lower) ||
      lower.startsWith('.trash-');
}

/// 文件名 [name]（单段）是不是 macOS AppleDouble 资源叉（`._001.jpg`）：macOS 往
/// exFAT / SMB / WebDAV 盘上写的伴生文件，与正片同名同扩展名，内容却不是。
bool isAppleDoubleFileName(String name) => name.startsWith('._');
