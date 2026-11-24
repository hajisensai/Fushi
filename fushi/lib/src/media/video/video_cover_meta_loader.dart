/// 视频封面来源表（`cover_meta.json`）的整表读取：选集缩略图判定「这一集的封面是
/// 不是用户手动设置的」（[CoverOrigin.isUserChosen]）用。合集选集页与播放器选集
/// 面板共用（拍板 GLMHiavo0y / design-player-episode-rail-stills）。
library;

import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/media/video/scraper/cover_meta_store.dart';
import 'package:fushi_engine/media/video/scraper/scraper_types.dart'
    show CoverMeta;
import 'package:fushi_engine/media/video/video_storage.dart';

/// 读整张封面来源表（bookUid → [CoverMeta]）。读不到只影响「手动封面排在剧照前」
/// 这一条排序（全部按非手动处理，剧照在前），不挡调用方：记一条诊断日志（来源
/// [diagnosticSource]）后返回空表。
Future<Map<String, CoverMeta>> loadVideoCoverMetaByUid(
  String diagnosticSource,
) async {
  try {
    return await CoverMetaStore(await VideoStorage.coversDir()).all();
  } on Object catch (error) {
    ErrorLogService.instance.logDiagnostic(diagnosticSource, error);
    return const <String, CoverMeta>{};
  }
}
