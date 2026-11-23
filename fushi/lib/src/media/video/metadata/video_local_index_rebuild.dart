import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/metadata/video_source_metadata_indexer.dart';

/// 对全部视频来源各跑一遍本地索引（[VideoSourceMetadataIndexer]）：给还没有规范
/// 作品的合集 / 散片建本地作品，把 NCOP / NCED / PV / `SPs` 目录这类本地特典挂到
/// 父作品下。返回这一轮有没有真的写库。
///
/// 两处调用：启动回填（HomePage），以及「清除全部刮削记录」提交之后——清理删掉全部
/// 规范作品，本地特典绑定随外键级联一起没了；不立刻重建，系列墙上特典就各自成卡，
/// 直到下次启动或重扫才归回系列（反馈 fUW6_kx9Rw）。索引本身是幂等的，什么都没变时
/// 零写入。单个来源失败只记日志、不挡其余来源；下次启动回填会再跑一遍。
Future<bool> reindexLocalVideoSources(
  FushiDatabase database, {
  required String logSource,
}) async {
  final List<MediaSourceRow> sources = await database.getMediaSourcesByKind(
    'video',
  );
  final VideoSourceMetadataIndexer indexer = VideoSourceMetadataIndexer(
    database,
  );
  bool changed = false;
  for (final MediaSourceRow source in sources) {
    try {
      if (await indexer.index(source)) changed = true;
    } on Object catch (error, stackTrace) {
      ErrorLogService.instance.log(
        '$logSource.${source.id}',
        error,
        stackTrace,
      );
    }
  }
  return changed;
}
