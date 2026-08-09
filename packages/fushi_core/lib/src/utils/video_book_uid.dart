/// 视频条目跨设备稳定 bookUid 派生（单一真相源，在 fushi_core 内，供 v38 拆集迁移
/// 与 app 导入路径共用）。
///
/// 与书的身份哲学（`bookKey = sanitizeTtuFilename(title)`）对齐：**只取文件名（去
/// 扩展名）经 [sanitizeTtuFilename] 派生**，不含目录/绝对路径，换机器/移动文件夹身份
/// 不变、跨设备同步可对齐。同名碰撞由 [coreUniqueVideoBookUid] 加后缀去重，而非把
/// 完整绝对路径哈希进身份。
///
/// app 层 `video_import_dialog.dart` 的 `singleVideoBookUid` / `playlistBookUid` /
/// `uniqueVideoBookUid` 与本文件逐字节等价（守卫见 `video_book_uid_core_parity_test`）。
library;

import 'ttu_sanitize.dart';

/// 取路径最后一段并去扩展名，**同时把 `/` 和 `\` 都当分隔符**（与宿主平台无关）。
///
/// `p.basenameWithoutExtension` 只认宿主平台分隔符——在 Linux/macOS 上不会把 Windows
/// 路径的 `\` 当分隔符，破坏「同一文件名跨不同绝对路径/机器得相同 bookUid」的不变量。
/// 这里两种分隔符都认，保证 `D:\a\E01.mkv` 与 `/home/u/E01.mkv` 在任何平台派生出 `E01`。
String _crossPlatformBasenameWithoutExtension(String path) {
  final int sep = path.lastIndexOf(RegExp(r'[\\/]'));
  final String name = sep >= 0 ? path.substring(sep + 1) : path;
  final int dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// 单个视频文件 → `video/<sanitize(文件名去扩展名)>`。
String coreSingleVideoBookUid(String videoPath) =>
    'video/${sanitizeTtuFilename(_crossPlatformBasenameWithoutExtension(videoPath))}';

/// m3u8 播放列表文件 → `video/playlist/<sanitize(文件名去扩展名)>`。
String corePlaylistBookUid(String m3u8Path) =>
    'video/playlist/${sanitizeTtuFilename(_crossPlatformBasenameWithoutExtension(m3u8Path))}';

/// 同名去重：若 [base] 已在 [existingKeys] 中，返回首个空位的加后缀变体
/// （`base (2)` / `base (3)`...）；否则原样返回。纯函数，无回调静默加后缀
/// （照搬 EpubImporter 策略），保证「本地不出现两个同 book_uid 视频」不变量。
String coreUniqueVideoBookUid(String base, Set<String> existingKeys) {
  if (!existingKeys.contains(base)) return base;
  for (int i = 2;; i++) {
    final String candidate = '$base ($i)';
    if (!existingKeys.contains(candidate)) return candidate;
  }
}
