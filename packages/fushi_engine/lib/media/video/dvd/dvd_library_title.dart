// DVD 特典按扫描导入的规则入库，与蓝光 `ensureBlurayDiscTitlesInLibrary` 的特典分支
// 同一规则：带来源、名字取 `<盘名> - T<nn>`、**不进盘合集**（单片盘进了合集就变成多
// 成员合集）；随后由索引器（`discMemberExtras`）挂到正片作品下。已有的行只补缺
// （来源为空才补），幂等，不动用户改过的标题与进度。

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/media/video/dvd/dvd_disc.dart';
import 'package:fushi_engine/media/video/external_video.dart'
    show normalizeVideoPath;
import 'package:fushi_engine/media/video/video_book_repository.dart';

/// [disc] 上的特典 [titlePaths]（须是 [DvdDisc.extras] 里的成员路径）按扫描导入的
/// 规则入库，返回与入参同序的库行。不在 [DvdDisc.extras] 里的路径被忽略。
Future<List<VideoBookRow>> ensureDvdDiscExtrasInLibrary(
  FushiDatabase db, {
  required DvdDisc disc,
  required List<String> titlePaths,
  int? sourceId,
}) async {
  final Map<String, DvdTitle> extraByPath = <String, DvdTitle>{
    for (final DvdTitle t in disc.extras) normalizeVideoPath(t.titlePath): t,
  };
  final List<String> paths = <String>[
    for (final String path in titlePaths)
      if (extraByPath.containsKey(normalizeVideoPath(path))) path,
  ];
  if (paths.isEmpty) return const <VideoBookRow>[];
  final VideoBookRepository repo = VideoBookRepository(db);
  return db.transaction(() async {
    final List<VideoBookRow> books = await repo.listAll();
    final Map<String, VideoBookRow> byPath = <String, VideoBookRow>{
      for (final VideoBookRow b in books) normalizeVideoPath(b.videoPath): b,
    };
    final Set<String> taken = <String>{
      for (final VideoBookRow b in books) b.bookUid,
    };
    final List<String> uids = <String>[];
    for (final String path in paths) {
      final String key = normalizeVideoPath(path);
      final VideoBookRow? row = byPath[key];
      if (row != null) {
        if (row.sourceId == null && sourceId != null) {
          await repo.assignSourceIfNull(row.bookUid, sourceId);
        }
        uids.add(row.bookUid);
        continue;
      }
      final String uid = coreUniqueVideoBookUid(
        coreSingleVideoBookUid(path),
        taken,
      );
      taken.add(uid);
      await repo.saveVideoBook(
        VideoBooksCompanion(
          bookUid: Value(uid),
          title: Value(extraByPath[key]!.name),
          videoPath: Value(path),
          importedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
        sourceId: sourceId,
      );
      byPath[key] = (await repo.getByBookUid(uid))!;
      uids.add(uid);
    }
    return <VideoBookRow>[
      for (final String uid in uids) (await repo.getByBookUid(uid))!,
    ];
  });
}
