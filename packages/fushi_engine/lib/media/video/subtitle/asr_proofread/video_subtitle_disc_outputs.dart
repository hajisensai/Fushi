/// 原盘成员（蓝光整卷 / 分集 `.mpls`、DVD title）落在任务根 `disc_out` 下的字幕产物
/// （[videoSubtitleDiscExportDir]）的枚举与回收。
///
/// 原盘的字幕不在盘旁（盘结构写不进 / 不该写），而在 app 自有的任务根里，按成员身份
/// 分目录；多角度 title 每个角度是一个成员路径（`00001.a2.mpls`），各有一个目录。库里
/// 删掉这一行时它们就没人用了：删行的回收尾活经 [deleteVideoSubtitleDiscOutputs]
/// 一并删掉，不然只会在存储页里越积越多。
library;

import 'dart:io';

import 'package:fushi_engine/media/video/bluray/bluray_angle.dart'
    show blurayAnglePath, kBlurayMaxAngles;
import 'package:fushi_engine/media/video/bluray/bluray_source.dart'
    show isBlurayPlaylistPath;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart'
    show videoSubtitleDiscExportDir;
import 'package:path/path.dart' as p;

/// 成员路径 [memberPath] 在 [jobsRoot] 下可能有的全部 `disc_out` 目录：蓝光按全部
/// 角度（0～[kBlurayMaxAngles] - 1）各一个，DVD 一个；不是原盘成员返回空表。纯函数，
/// 不碰文件系统。
List<Directory> videoSubtitleDiscOutputDirs(
  Directory jobsRoot,
  String memberPath,
) {
  if (isBlurayPlaylistPath(memberPath)) {
    return <Directory>[
      for (int angle = 0; angle < kBlurayMaxAngles; angle++)
        ?videoSubtitleDiscExportDir(
          jobsRoot,
          blurayAnglePath(memberPath, angle),
        ),
    ];
  }
  return <Directory>[?videoSubtitleDiscExportDir(jobsRoot, memberPath)];
}

/// 删掉 [memberPaths] 的全部 `disc_out` 产物目录（[videoSubtitleDiscOutputDirs]），
/// [keepMemberPaths] 里的成员（仍被别的库行引用）跳过。逐目录删，一个删不掉不拦其余，
/// 失败的路径原样返回给调用方记日志。
Future<List<(String, Object)>> deleteVideoSubtitleDiscOutputs({
  required Directory jobsRoot,
  required Iterable<String> memberPaths,
  Set<String> keepMemberPaths = const <String>{},
}) async {
  final Set<String> keep = <String>{
    for (final String path in keepMemberPaths) p.normalize(path),
  };
  final List<(String, Object)> failures = <(String, Object)>[];
  for (final String member in memberPaths) {
    if (keep.contains(p.normalize(member))) continue;
    for (final Directory dir in videoSubtitleDiscOutputDirs(jobsRoot, member)) {
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } on FileSystemException catch (error) {
        failures.add((dir.path, error));
      }
    }
  }
  return failures;
}
