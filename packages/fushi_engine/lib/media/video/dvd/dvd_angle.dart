// DVD 多角度 title 的「按角度读」成员路径（与蓝光 `bluray_angle.dart` 同一套结构）。
//
// DVD 的角度块（angle block）在 VOB 里交错存放各角度的画面，同一 title 的各角度共用
// 一条时间轴。播放器（libmpv 的 libdvdnav）按当前角度读；抽取侧（ffmpeg 的 `dvdvideo`
// demuxer，经 `DvdFfmpegBackend` / `prepareDvdFfmpegArgs`）要读到同一份画面与音轨，就得
// 把角度交给 `-angle`。
//
// 角度是播放会话的状态，不是库身份：库里的 DVD 标题永远是不带角度的
// `VIDEO_TS/TITLE_nn.dvdtitle`。抽取输入用一条**虚拟的角度成员路径**把角度带下去：
//
//     <盘根>/VIDEO_TS/TITLE_<nn>.a<角度号>.dvdtitle
//     例：…/VIDEO_TS/TITLE_03.a2.dvdtitle   （第 2 个角度，快照 angle = 1，ffmpeg -angle 2）
//
// 角度号 1 起、只写 2～9（DVD-Video 一个 title 最多 9 个角度；第 1 个角度就是不带后缀
// 的成员路径本身——已登记的产物、`disc_out` 目录、回收逻辑对默认角度不变）。它仍以
// `.dvdtitle` 结尾、仍在 `VIDEO_TS/` 下，所以「这是一条 DVD title」的判据、盘根与 title
// 号反推（`dvd_title_path.dart`）、背后真实文件、管线的原盘落点原样成立；ffmpeg 输入改写
// （`parseDvdTitleInput`）按角度号给 `-angle`。

import 'package:fushi_engine/media/video/dvd/dvd_title_path.dart'
    show isDvdTitlePath, kDvdTitlePathExtension;

/// DVD-Video 的角度上限（一个 title 至多 9 个角度，`dvdvideo` 的 `-angle` 取 1～9）。
const int kDvdMaxAngles = 9;

/// 角度成员文件名（去 `.dvdtitle`）的尾巴：`.a` + 角度号 2～9。
final RegExp _angleSuffix = RegExp(r'^(.+)\.a([2-9])$');

/// 角度成员路径拆出来的两半。
typedef DvdTitleAngleRef = ({
  /// 不带角度的 title 成员路径。
  String titlePath,

  /// 角度下标（0 起，与 `disc-navigation-state` 的 `angle` 同口径；ffmpeg `-angle` 是
  /// 它 + 1）；恒 ≥ 1。
  int angleIndex,
});

/// 把角度成员路径拆成「title 成员路径 + 角度下标」；不是角度成员路径返回 null。只做
/// 文本切分，两种分隔符都认，不碰文件系统。
DvdTitleAngleRef? parseDvdTitleAnglePath(String path) {
  if (!isDvdTitlePath(path)) return null;
  final int separator = path.lastIndexOf(RegExp(r'[\\/]'));
  final String name = separator >= 0 ? path.substring(separator + 1) : path;
  final int ext = name.length - kDvdTitlePathExtension.length;
  final Match? match = _angleSuffix.firstMatch(name.substring(0, ext));
  if (match == null) return null;
  return (
    titlePath:
        '${path.substring(0, separator + 1)}${match.group(1)}'
        '${name.substring(ext)}',
    angleIndex: int.parse(match.group(2)!) - 1,
  );
}

/// title 成员路径 [titlePath] 按角度下标 [angleIndex]（0 起）读的抽取路径：角度 0 就是
/// [titlePath] 本身；1～8 得到角度成员路径。[titlePath] 已带角度时先去掉再按新角度拼。
/// 角度越界抛 [RangeError]，不是 DVD title 抛 [ArgumentError]。
String dvdTitleAnglePath(String titlePath, int angleIndex) {
  if (angleIndex < 0 || angleIndex >= kDvdMaxAngles) {
    throw RangeError.range(angleIndex, 0, kDvdMaxAngles - 1, 'angleIndex');
  }
  if (!isDvdTitlePath(titlePath)) {
    throw ArgumentError.value(titlePath, 'titlePath', 'not a DVD title member');
  }
  final String base = dvdTitleAngleBasePath(titlePath);
  if (angleIndex == 0) return base;
  final int dot = base.length - kDvdTitlePathExtension.length;
  return '${base.substring(0, dot)}.a${angleIndex + 1}${base.substring(dot)}';
}

/// 去掉角度后的 title 成员路径（库身份那一条）；不是角度成员路径时原样返回 [path]。
String dvdTitleAngleBasePath(String path) =>
    parseDvdTitleAnglePath(path)?.titlePath ?? path;
