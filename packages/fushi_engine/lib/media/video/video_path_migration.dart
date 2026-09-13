/// TODO-1961-d：库里「路径类」列的重映射规则（纯函数，无 IO）。
///
/// 背景：视频入库是**纯引用绝对路径**（`VideoBooks.videoPath`，字幕 sidecar 走
/// `subtitleSource` / `secondarySubtitleSource`）。引擎侧改名 / 移动
/// （TODO-1961-c）之后，磁盘上的东西换地方了，这些列就成了死路径 —— 做种保住了、
/// 库条目却断了。两件事必须**成对**完成，缺一即断，所以引擎成功后立刻用这里的
/// 规则把库改过来。
///
/// 为什么单独抽成纯函数：这里全是「什么该改、什么绝不能改」的判断，是最容易
/// 出错也最该被单测钉死的部分。IO 留给仓库层。
library;

import 'package:path/path.dart' as p;

/// 内嵌字幕轨哨兵前缀（`embedded:<n>`）——不是路径，绝不能当路径重写。
const String kEmbeddedSubtitlePrefix = 'embedded:';

/// 「用户显式关闭字幕」哨兵前缀（`off:`）——同样不是路径。
const String kOffSubtitlePrefix = 'off:';

/// 一个值是否是本地绝对路径（而不是哨兵 / 流媒体 URL / 相对路径）。
///
/// 字幕源列是四态编码（绝对路径 / `embedded:<n>` / `off:` / null），
/// `videoPath` 还可能是 http(s) 流媒体。只有真·本地绝对路径才参与重映射。
bool isRemappableMediaPath(String? value) {
  if (value == null) return false;
  final String trimmed = value.trim();
  if (trimmed.isEmpty) return false;
  if (trimmed.startsWith(kEmbeddedSubtitlePrefix)) return false;
  if (trimmed.startsWith(kOffSubtitlePrefix)) return false;
  // 流媒体书：videoPath 是 http/https，磁盘上没有对应文件。
  final Uri? uri = Uri.tryParse(trimmed);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    return false;
  }
  return p.isAbsolute(trimmed);
}

/// 把 [value] 按 [fromPath] → [toPath] 重映射；不该改时返回 null。
///
/// 覆盖两种情形，它们其实是同一件事（一次路径重映射），所以不分两个函数：
/// - **改名**：[fromPath] 是那个文件本身 → 全等匹配，直接换成 [toPath]；
/// - **移动**：[fromPath] 是旧的内容根 → [value] 落在它里面时，把相对部分接到
///   [toPath] 下面。
///
/// 路径比较一律走 `package:path`（Windows 的大小写不敏感与 `/` `\` 混用由它
/// 负责，别自己写 `startsWith` —— `D:\a` 会误匹配 `D:\ab`）。
String? remapMediaPath(
  String? value, {
  required String fromPath,
  required String toPath,
}) {
  if (!isRemappableMediaPath(value)) return null;
  if (fromPath.trim().isEmpty || toPath.trim().isEmpty) return null;
  final String current = p.normalize(value!.trim());
  final String from = p.normalize(fromPath.trim());
  final String to = p.normalize(toPath.trim());
  if (p.equals(current, from)) return to;
  if (p.isWithin(from, current)) {
    return p.normalize(p.join(to, p.relative(current, from: from)));
  }
  return null;
}

/// 一行视频书在一次重映射里要改的列（全 null = 这行不受影响，别写库）。
class VideoPathRemap {
  const VideoPathRemap({
    this.videoPath,
    this.subtitleSource,
    this.secondarySubtitleSource,
  });

  final String? videoPath;
  final String? subtitleSource;
  final String? secondarySubtitleSource;

  /// 这行是否真有列要改（避免为没变化的行发无谓的 UPDATE）。
  bool get isEmpty =>
      videoPath == null &&
      subtitleSource == null &&
      secondarySubtitleSource == null;
}

/// 算出一行视频书在 [fromPath] → [toPath] 下要改的列。
///
/// 三列各自独立判断：视频被移走了但字幕是内嵌轨（`embedded:0`）时，只改
/// videoPath、不碰字幕列 —— 这正是把哨兵当路径重写会造成的静默损坏。
VideoPathRemap remapVideoBookPaths({
  required String? videoPath,
  required String? subtitleSource,
  required String? secondarySubtitleSource,
  required String fromPath,
  required String toPath,
}) {
  return VideoPathRemap(
    videoPath: remapMediaPath(videoPath, fromPath: fromPath, toPath: toPath),
    subtitleSource:
        remapMediaPath(subtitleSource, fromPath: fromPath, toPath: toPath),
    secondarySubtitleSource: remapMediaPath(secondarySubtitleSource,
        fromPath: fromPath, toPath: toPath),
  );
}
