import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 视频媒体在磁盘上的「app 拥有」副本目录管理 + 孤儿回收（BUG-276）。
///
/// 布局（均在 `<appDocDir>/` 下）：
///   - `video_covers/<sanitized uid>.jpg` —— 导入时抽帧/自带封面，或用户手动设置
///     的封面。app 拥有，删除视频后必须回收。
///   - `video_subtitles/<basename>` —— 用户手动导入 / 拖入 / Jimaku 下载的外挂字幕
///     （见 [video_hibiki_page] `_importExternalSubtitle` / `_openJimakuDialog`）。
///     app 拥有，仅当无任何视频再引用时回收。
///
/// **绝不**触碰 `VideoBooks.videoPath` / 播放列表里的视频本体路径：那是用户的原始
/// 文件（导入时只存绝对路径、从不复制），删除视频不应删用户的电影源文件。
///
/// 回收策略是 mark-and-sweep 孤儿 GC：以「当前 DB 仍引用的路径集合」为唯一真相，
/// 扫这两个 app 拥有目录，删掉引用集里没有的文件。这样删除路径不需要逐本特例判断
/// 「这个封面/字幕该不该删」（同名字幕可能被覆盖语义复用），也顺带清掉历史遗留的
/// 孤儿（用户报告的 13GB 占用主要是这些从未被回收的副本）。
class VideoStorage {
  const VideoStorage._();

  static const String coversDirName = 'video_covers';
  static const String subtitlesDirName = 'video_subtitles';

  /// 封面目录绝对路径（不创建）。
  static Future<Directory> coversDir() async {
    final Directory docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, coversDirName));
  }

  /// 导入字幕目录绝对路径（不创建）。
  static Future<Directory> subtitlesDir() async {
    final Directory docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, subtitlesDirName));
  }

  /// 删除 app 拥有的封面/字幕目录里、不在 [referencedCoverPaths] /
  /// [referencedSubtitlePaths] 引用集中的孤儿文件。
  ///
  /// [coversDirectory] / [subtitlesDirectory] 缺省取 [coversDir] / [subtitlesDir]
  /// （生产路径）；测试注入临时目录。两个目录任一不存在则跳过（无副本可清）。
  ///
  /// 返回实际删除的文件数（便于诊断 / 测试断言）。
  static Future<int> gcOrphans({
    required Iterable<String> referencedCoverPaths,
    required Iterable<String> referencedSubtitlePaths,
    Directory? coversDirectory,
    Directory? subtitlesDirectory,
  }) async {
    final Directory covers = coversDirectory ?? await coversDir();
    final Directory subtitles = subtitlesDirectory ?? await subtitlesDir();
    final int removedCovers = await _sweepDir(
      dir: covers,
      keep: referencedCoverPaths,
    );
    final int removedSubs = await _sweepDir(
      dir: subtitles,
      keep: referencedSubtitlePaths,
    );
    return removedCovers + removedSubs;
  }

  /// 删 [dir] 里所有不在 [keep]（规范化后）集合中的常规文件，返回删除数。
  ///
  /// 只删常规文件，不递归子目录、不删目录本身——这两个目录是扁平的副本池。
  static Future<int> _sweepDir({
    required Directory dir,
    required Iterable<String> keep,
  }) async {
    if (!await dir.exists()) return 0;
    final Set<String> keepCanon = <String>{
      for (final String path in keep)
        if (path.isNotEmpty) p.canonicalize(path),
    };
    int removed = 0;
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is! File) continue;
      if (keepCanon.contains(p.canonicalize(entity.path))) continue;
      try {
        await entity.delete();
        removed++;
      } catch (_) {
        // 单个文件删除失败（被占用/权限）不应中断整轮 GC：跳过，下次再清。
      }
    }
    return removed;
  }
}
