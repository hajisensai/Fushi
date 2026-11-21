// 原盘成员「按角度读」的统一入口：蓝光（`bluray_angle.dart`，`00001.a2.mpls`）与 DVD
// （`dvd_angle.dart`，`TITLE_03.a2.dvdtitle`）同一个形状——成员名后缀 `.a<角度号 2～9>`，
// 角度下标 0 起（与 `disc-navigation-state` 的 `angle` 同口径），第 1 个角度就是不带后缀
// 的成员路径本身。调用方（字幕管线目标、远端定位、disc_out 回收）不必分盘型。

import 'package:fushi_engine/media/video/bluray/bluray_angle.dart'
    show
        BlurayAngleRef,
        blurayAngleBaseMemberPath,
        blurayAnglePath,
        kBlurayMaxAngles,
        parseBlurayAnglePath;
import 'package:fushi_engine/media/video/bluray/bluray_source.dart'
    show isBlurayPlaylistPath;
import 'package:fushi_engine/media/video/dvd/dvd_angle.dart'
    show
        DvdTitleAngleRef,
        dvdTitleAngleBasePath,
        dvdTitleAnglePath,
        kDvdMaxAngles,
        parseDvdTitleAnglePath;
import 'package:fushi_engine/media/video/dvd/dvd_title_path.dart'
    show isDvdTitlePath;

/// 角度成员路径拆出来的两半（蓝光 / DVD 通用）。
typedef DiscAngleRef = ({
  /// 不带角度的成员路径（库身份那一条）。
  String memberPath,

  /// 角度下标（0 起）；恒 ≥ 1。
  int angleIndex,
});

/// [memberPath] 这类原盘成员的角度上限；不是原盘成员为 0。
int discMaxAnglesFor(String memberPath) {
  if (isDvdTitlePath(memberPath)) return kDvdMaxAngles;
  if (isBlurayPlaylistPath(memberPath)) return kBlurayMaxAngles;
  return 0;
}

/// 把蓝光 / DVD 的角度成员路径拆成「成员路径 + 角度下标」；不是角度成员路径返回 null。
DiscAngleRef? parseDiscAnglePath(String path) {
  final DvdTitleAngleRef? dvd = parseDvdTitleAnglePath(path);
  if (dvd != null) {
    return (memberPath: dvd.titlePath, angleIndex: dvd.angleIndex);
  }
  final BlurayAngleRef? bluray = parseBlurayAnglePath(path);
  if (bluray != null) {
    return (memberPath: bluray.memberPath, angleIndex: bluray.angleIndex);
  }
  return null;
}

/// 原盘成员 [memberPath] 按角度下标 [angleIndex]（0 起）读的抽取路径：角度 0 是不带
/// 角度的成员路径本身。角度越界抛 [RangeError]，不是原盘成员抛 [ArgumentError]。
String discAnglePath(String memberPath, int angleIndex) {
  if (isDvdTitlePath(memberPath)) {
    return dvdTitleAnglePath(memberPath, angleIndex);
  }
  if (isBlurayPlaylistPath(memberPath)) {
    return blurayAnglePath(memberPath, angleIndex);
  }
  throw ArgumentError.value(memberPath, 'memberPath', 'not a disc member');
}

/// 去掉角度后的成员路径；不是角度成员路径时原样返回 [path]。
String discAngleBaseMemberPath(String path) =>
    dvdTitleAngleBasePath(blurayAngleBaseMemberPath(path));
