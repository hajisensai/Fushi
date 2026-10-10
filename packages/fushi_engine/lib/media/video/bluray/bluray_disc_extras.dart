import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/bluray/bluray_disc.dart';
import 'package:fushi_engine/media/video/bluray/bluray_playlist.dart';
import 'package:fushi_engine/media/video/bluray/bluray_source.dart';
import 'package:fushi_engine/media/video/external_video.dart'
    show normalizeVideoPath;

/// 盘上一条标题短于正片这个比例，就是这张盘的特典（制作特辑、PV、菜单里的花絮），
/// 不是独立作品，也不是剧集。
///
/// 依据与 [kBlurayRelativeTitleFloor] 同一组观察：剧集盘 / MV 盘各条目彼此同一量级
/// （最短的也有最长那条的一半以上），电影盘的花絮远短于正片。扫描的 0.15 是「值不
/// 值得进库」，这里的 0.5 是「是不是与正片同级的内容」——31 分钟的制作特辑对 143 分钟
/// 的正片值得进库，但绝不是那部电影本身。
const double kBlurayExtraRelativeDuration = 0.5;

/// [disc] 上哪些播放列表是特典：MPLS 号 → 是。正片锚点取扫描选出的主标题
/// （[BlurayTitle.isMainFeature]，已排除 play-all 超集）。
Set<String> blurayExtraPlaylistIds(BlurayDisc disc) {
  int anchor = 0;
  for (final BlurayTitle title in disc.titles) {
    if (title.isMainFeature && title.playlist.durationTicks > anchor) {
      anchor = title.playlist.durationTicks;
    }
  }
  if (anchor <= 0) return const <String>{};
  final int floor = (anchor * kBlurayExtraRelativeDuration).round();
  return <String>{
    for (final BlurayPlaylist playlist in disc.playlists)
      if (playlist.durationTicks < floor) playlist.id,
  };
}

/// [videoPaths] 里属于蓝光盘特典的那些：归一路径 → 同盘正片的 `.mpls` 路径。
///
/// 特典不按自己的标题去识别——盘名就是正片的片名，拿它去搜只会把 31 分钟的特辑
/// 认成整部电影。它们与 NCOP / 预告同样处理：不进刮削计划，挂到正片的作品下当附件。
Future<Map<String, String>> blurayDiscExtras(
  Iterable<String> videoPaths,
) async {
  final Map<String, List<String>> byRoot = <String, List<String>>{};
  final Map<String, String> rootPath = <String, String>{};
  for (final String path in videoPaths) {
    if (!isBlurayPlaylistPath(path)) continue;
    final String? root = blurayDiscRootForPlaylistPath(path);
    if (root == null) continue;
    final String key = normalizeVideoPath(root);
    rootPath.putIfAbsent(key, () => root);
    byRoot.putIfAbsent(key, () => <String>[]).add(path);
  }
  final Map<String, String> result = <String, String>{};
  for (final MapEntry<String, List<String>> entry in byRoot.entries) {
    final BlurayDisc? disc = await readBlurayDisc(rootPath[entry.key]!);
    if (disc == null) continue;
    final Set<String> extras = blurayExtraPlaylistIds(disc);
    if (extras.isEmpty) continue;
    final String main = disc.titles
        .firstWhere((BlurayTitle title) => title.isMainFeature)
        .playlistPath;
    for (final String path in entry.value) {
      if (extras.contains(p.basenameWithoutExtension(path))) {
        result[normalizeVideoPath(path)] = main;
      }
    }
  }
  return result;
}
