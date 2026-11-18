// 蓝光多角度 title 的「按角度读」成员路径。
//
// 多角度 PlayItem 在 MPLS 里列了每个角度各自的片段（`bluray_playlist.dart` 的
// [BlurayClipRef.angleClipIds]），各角度共用该 PlayItem 的 IN/OUT。播放器（libbluray）
// 按当前角度读对应片段；抽取侧（ffmpeg 经 `prepareBlurayFfmpegArgs` 把 `.mpls` 改写
// 成 concat 清单）要读到同一份画面与音轨，就得知道「按哪个角度」。
//
// 角度是播放会话的状态，不是库身份：库里的蓝光标题永远是不带角度的 `.mpls`（或分集
// 路径）。抽取输入用一条**虚拟的角度成员路径**把角度带下去：
//
//     <盘根>/BDMV/PLAYLIST/<成员名>.a<角度号>.mpls
//     例：…/BDMV/PLAYLIST/00001.a2.mpls      （第 2 个角度，libbluray angle = 1）
//         …/BDMV/PLAYLIST/00001.p03.a2.mpls  （分集路径的第 2 个角度）
//
// 角度号 1 起、只写 2～9（BD 最多 9 个角度；第 1 个角度就是不带后缀的成员路径本身）。
// 它仍以 `.mpls` 结尾、仍在 `PLAYLIST/` 下，所以「这是一条蓝光标题」的判据、盘根反推、
// 管线的原盘落点（`disc_out`）原样成立；读播放列表内容一律走
// `readBlurayMemberPlaylist`（`bluray_source.dart`），它按角度换片段；「背后真实存在
// 的文件」走 [blurayMemberBackingPlaylistPath]。

import 'package:fushi_engine/media/video/bluray/bluray_episode.dart'
    show blurayEpisodeBackingPlaylistPath;
import 'package:fushi_engine/media/video/bluray/bluray_playlist.dart';

/// BD 规范的角度上限（`number_of_angles` ≤ 9）。
const int kBlurayMaxAngles = 9;

/// 角度成员文件名（去 `.mpls`）的尾巴：`.a` + 角度号 2～9。
final RegExp _angleSuffix = RegExp(r'^(.+)\.a([2-9])$');

/// 角度成员路径拆出来的两半。
typedef BlurayAngleRef = ({
  /// 不带角度的成员路径（真实 `.mpls` 或分集路径）。
  String memberPath,

  /// 角度下标（0 起，与 libbluray angle 同口径）；恒 ≥ 1。
  int angleIndex,
});

/// 把角度成员路径拆成「成员路径 + 角度下标」；不是角度成员路径返回 null。只做文本
/// 切分，两种分隔符都认，不碰文件系统。
BlurayAngleRef? parseBlurayAnglePath(String path) {
  final int separator = path.lastIndexOf(RegExp(r'[\\/]'));
  final String name = separator >= 0 ? path.substring(separator + 1) : path;
  if (!name.toLowerCase().endsWith('.mpls')) return null;
  final Match? match = _angleSuffix.firstMatch(
    name.substring(0, name.length - 5),
  );
  if (match == null) return null;
  return (
    memberPath:
        '${path.substring(0, separator + 1)}${match.group(1)}'
        '${name.substring(name.length - 5)}',
    angleIndex: int.parse(match.group(2)!) - 1,
  );
}

/// 成员路径 [memberPath] 按角度下标 [angleIndex]（0 起）读的抽取路径：角度 0 就是
/// [memberPath] 本身；1～8 得到角度成员路径。[memberPath] 已带角度时先去掉再按新角度
/// 拼。角度越界抛 [RangeError]。
String blurayAnglePath(String memberPath, int angleIndex) {
  if (angleIndex < 0 || angleIndex >= kBlurayMaxAngles) {
    throw RangeError.range(angleIndex, 0, kBlurayMaxAngles - 1, 'angleIndex');
  }
  final String base = blurayAngleBaseMemberPath(memberPath);
  if (!base.toLowerCase().endsWith('.mpls')) {
    throw ArgumentError.value(memberPath, 'memberPath', 'not a .mpls member');
  }
  if (angleIndex == 0) return base;
  final int dot = base.length - 5; // '.mpls'
  return '${base.substring(0, dot)}.a${angleIndex + 1}${base.substring(dot)}';
}

/// 去掉角度后的成员路径（库身份那一条）；不是角度成员路径时原样返回 [path]。
String blurayAngleBaseMemberPath(String path) =>
    parseBlurayAnglePath(path)?.memberPath ?? path;

/// 蓝光成员路径（整卷 / 分集 / 带角度）背后真实存在的 `.mpls`；不是这些虚拟路径时
/// 原样返回 [path]。
String blurayMemberBackingPlaylistPath(String path) =>
    blurayEpisodeBackingPlaylistPath(blurayAngleBaseMemberPath(path));

/// [playlist] 按角度下标 [angleIndex]（0 起）播放时的片段序列：多角度 PlayItem 换成该
/// 角度的片段，IN/OUT、章节、流表不变；PlayItem 的角度数不够时用它的第 1 个角度（与
/// libbluray 一致）。角度 0 原样返回。
BlurayPlaylist blurayPlaylistForAngle(BlurayPlaylist playlist, int angleIndex) {
  if (angleIndex == 0) return playlist;
  return BlurayPlaylist(
    id: '${playlist.id}.a${angleIndex + 1}',
    clips: List<BlurayClipRef>.unmodifiable(<BlurayClipRef>[
      for (final BlurayClipRef clip in playlist.clips)
        BlurayClipRef(
          clipId: clip.clipIdForAngle(angleIndex),
          inTimeTicks: clip.inTimeTicks,
          outTimeTicks: clip.outTimeTicks,
        ),
    ]),
    chapters: playlist.chapters,
    streams: playlist.streams,
    playbackType: playlist.playbackType,
  );
}
