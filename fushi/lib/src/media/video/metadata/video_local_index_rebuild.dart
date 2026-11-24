import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_scope.dart';
import 'package:fushi_engine/media/video/metadata/video_source_metadata_indexer.dart';

/// 对全部本机视频刮削范围各跑一遍本地索引（[VideoSourceMetadataIndexer]）：给还没有
/// 规范作品的合集 / 散片建本地作品，把 NCOP / NCED / PV / `SPs` 目录这类本地特典挂到
/// 父作品下。返回这一轮有没有真的写库。
///
/// 范围与刮削链同一份（[localVideoScrapeScopes]）：已登记的本机视频来源，加上无来源
/// 范围——「导入文件夹（仅此一次）」扫完删掉临时行后的视频就落在那里，修前只遍历
/// 来源行，它们永远没有本地作品与特典绑定（BUG-5418）。
///
/// 两处调用：启动回填（HomePage），以及「清除全部刮削记录」提交之后——清理删掉全部
/// 规范作品，本地特典绑定随外键级联一起没了；不立刻重建，系列墙上特典就各自成卡，
/// 直到下次启动或重扫才归回系列（反馈 fUW6_kx9Rw）。索引本身是幂等的，什么都没变时
/// 零写入。单个范围失败只记日志、不挡其余范围；下次启动回填会再跑一遍。
Future<bool> reindexLocalVideoSources(
  FushiDatabase database, {
  required String logSource,
}) async {
  bool changed = false;
  for (final SourceLibraryRow scope in await localVideoScrapeScopes(database)) {
    if (await indexLocalVideoScope(database, scope, logSource: logSource)) {
      changed = true;
    }
  }
  return changed;
}

/// 对一个刮削范围 [scope] 跑本地索引；失败只记日志（`<logSource>.<范围 id>`）、返回
/// false。「导入文件夹（仅此一次）」删掉临时行后对无来源范围调它（BUG-5418）。
Future<bool> indexLocalVideoScope(
  FushiDatabase database,
  SourceLibraryRow scope, {
  required String logSource,
}) async {
  try {
    return await VideoSourceMetadataIndexer(database).index(scope);
  } on Object catch (error, stackTrace) {
    ErrorLogService.instance.log('$logSource.${scope.id}', error, stackTrace);
    return false;
  }
}
