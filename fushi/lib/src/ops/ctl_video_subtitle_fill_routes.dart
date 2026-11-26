import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/subtitle/library_subtitle_fill.dart'
    show LibrarySubtitleFillOptions;
import 'package:fushi_engine/media/video/subtitle/subtitle_language_preference.dart'
    show normalizeSubtitleLanguageCode;

import 'package:fushi/src/media/video/subtitle/library_subtitle_fill_controller.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/op_context.dart';

/// 整库补字幕的控制通道路由（CLI：`fushi_cli video sub-fill`）。
///
/// - `POST subtitle-fill`：起一个任务（全库 / 一个合集 / 点名的几集），立即返回任务
///   id；`wait=true` 时等跑完再回整份报告；
/// - `GET subtitle-fill`：最近一次任务的进度与报告；
/// - `POST subtitle-fill-undo`：按落盘报告撤销一次任务（删新写的文件、还原选择）。
List<CtlRoute> buildVideoSubtitleFillCtlRoutes(OpContext context) {
  AppModel appModel() => context.appModel;
  final CtlVideoSubtitleFillHandlers handlers = CtlVideoSubtitleFillHandlers(
    controller: () => librarySubtitleFillController(appModel()),
    database: () => appModel().database,
    videoModuleEnabled: () =>
        appModel().moduleVisibility.isEnabled(ModuleId.video),
  );
  return <CtlRoute>[
    CtlRoute.post(kCtlVideoSubtitleFillPath, handlers.start),
    CtlRoute.get(kCtlVideoSubtitleFillPath, handlers.status),
    CtlRoute.post(kCtlVideoSubtitleFillUndoPath, handlers.undo),
  ];
}

const String kCtlVideoSubtitleFillPath = '/api/admin/video/subtitle-fill';
const String kCtlVideoSubtitleFillUndoPath =
    '/api/admin/video/subtitle-fill-undo';

/// `bookUids` 参数：字符串数组原样认（bookUid 取自文件名，本身可以带逗号），
/// 字符串按逗号切（CLI 手输的简写）；空 = 没给。
List<String>? subtitleFillBookUidsParam(Object? raw) {
  if (raw == null) return null;
  final Iterable<Object?> parts = switch (raw) {
    final List<Object?> list => list,
    final String text => text.split(','),
    _ => throw const CtlFailure.badRequest('bookUids 要么是字符串数组，要么是逗号分隔串'),
  };
  final List<String> out = <String>[
    for (final Object? part in parts)
      if (part is String && part.trim().isNotEmpty) part.trim(),
  ];
  return out.isEmpty ? null : out;
}

/// 路由处理器（依赖全部注入）。
class CtlVideoSubtitleFillHandlers {
  CtlVideoSubtitleFillHandlers({
    required this.controller,
    required this.database,
    required this.videoModuleEnabled,
  });

  final LibrarySubtitleFillController Function() controller;
  final FushiDatabase Function() database;
  final bool Function() videoModuleEnabled;

  void _requireVideoModule() {
    if (!videoModuleEnabled()) {
      throw const CtlFailure.rejected('「视频」模块已关闭（设置 › 功能模块）');
    }
  }

  Future<Object?> start(CtlCall call) async {
    _requireVideoModule();
    final String? language = normalizeSubtitleLanguageCode(
      call.requireString('language'),
    );
    if (language == null) {
      throw const CtlFailure.badRequest('language 认不出（ja / zh / en …）');
    }
    final List<String>? bookUids = await _scope(call);
    final LibrarySubtitleFillJob job;
    try {
      job = await controller().start(
        LibrarySubtitleFillOptions(
          language: language,
          allowGenerate: call.optBool('generate') ?? true,
          allowOcr: call.optBool('ocr') ?? true,
          allowDownload: call.optBool('download') ?? true,
          retimeDiscDownloads: call.optBool('retime') ?? true,
          dryRun: call.optBool('dryRun') ?? false,
        ),
        bookUids: bookUids,
      );
    } on LibrarySubtitleFillBusy catch (busy) {
      throw CtlFailure.conflict(
        '已有补字幕任务在跑：${busy.active.id}（video sub-fill --status 看进度）',
      );
    }
    if (call.optBool('wait') == true) {
      await job.done;
      return job.reportJson();
    }
    return <String, Object?>{...job.summaryJson(), 'videoJob': job.mirror.id};
  }

  /// 范围：`collectionId`（合集成员）或 `bookUids`，都不给 = 全库。
  ///
  /// `bookUids` 收 JSON 字符串数组（原样认，bookUid 取自文件名、本身可以带逗号，
  /// 如 `video/Kamiina Botan, Yoeru Sugata wa …`）或逗号分隔串（CLI 手输的简写）。
  Future<List<String>?> _scope(CtlCall call) async {
    final int? collectionId = call.optInt('collectionId');
    final List<String>? uids = subtitleFillBookUidsParam(
      call.body['bookUids'] ?? call.query['bookUids'],
    );
    if (collectionId != null && uids != null) {
      throw const CtlFailure.badRequest('collectionId 与 bookUids 只能给一个');
    }
    if (uids != null) return uids;
    if (collectionId == null) return null;
    final List<MediaCollectionItemRow> items = await database()
        .getCollectionItems(collectionId);
    return <String>[
      for (final MediaCollectionItemRow i in items)
        if (i.mediaType == 'video') i.entryKey,
    ];
  }

  Future<Object?> status(CtlCall call) async {
    _requireVideoModule();
    final LibrarySubtitleFillJob? job = controller().latest;
    if (job == null) throw const CtlFailure.notFound('这次运行里还没有补字幕任务');
    return <String, Object?>{...job.reportJson(), 'running': job.isRunning};
  }

  Future<Object?> undo(CtlCall call) async {
    _requireVideoModule();
    final String jobId = call.requireString('jobId');
    try {
      return <String, Object?>{
        'jobId': jobId,
        'undone': await controller().undo(jobId),
      };
    } on LibrarySubtitleFillBusy {
      throw const CtlFailure.conflict('这次任务还在跑，先取消（video job cancel）');
    } on Object catch (error) {
      throw CtlFailure.notFound('没有这次任务的报告：$jobId（$error）');
    }
  }
}
