import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/anki/source_review_navigation.dart';
import 'package:fushi/src/media/video/video_resource_check.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/sync/video_remote_host.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptivePageRoute;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';
import 'package:material_ui/material_ui.dart';

/// 手机遥控「点播」的电脑侧装配：列本机视频库、在本机打开某个视频。
///
/// 打开走与卡片回看（`card_source_router.dart`）同一条媒体切换队列：
/// [ExternalMediaNavigation.closeActive] 让正在开的视频页走它自己的退出流程（落进度、
/// 退全屏、上报远端断点）再 push 新页，不会叠出第二个播放器，也不会在旧页写完前把它
/// 摘掉。旧页关不掉（上面压着对话框等）就回 `host_busy`，不硬拆。
///
/// 一切「这次打不开」的判断（行不存在、文件缺失、迁移只读）都排在 closeActive 之前：
/// 打不开就不能先把电脑上正在放的视频关掉。
///
/// 封面（选片清单的预览图）读库页同一份 `video_books.coverPath`；关闭视频
/// （`closeVideo`）与打开走同一条队列和同一个 [ExternalMediaNavigation.closeActive]
/// 退出流程，关不掉同样回 `host_busy`。
VideoRemoteLibrary createVideoRemoteLibrary({
  required FushiDatabase Function() database,
  required GlobalKey<NavigatorState> navigatorKey,
  required Future<void> Function() stopAudiobook,
  required bool Function() isMigrationReadonly,
}) {
  return VideoRemoteLibrary(
    list: () => listVideoRemoteLibrary(database()),
    open: (String bookUid) => ExternalMediaNavigation.instance.navigate(
      () => _open(
        database: database(),
        navigatorKey: navigatorKey,
        stopAudiobook: stopAudiobook,
        isMigrationReadonly: isMigrationReadonly,
        bookUid: bookUid,
      ),
    ),
    cover: (String bookUid) => readVideoRemoteLibraryCover(database(), bookUid),
    close: () => ExternalMediaNavigation.instance.navigate(() async {
      if (!await ExternalMediaNavigation.instance.closeActive()) {
        throw const VideoRemoteException(409, 'host_busy');
      }
    }),
  );
}

/// 选片清单里 [bookUid] 的封面字节；没有封面 / 文件已不在 → null。
Future<Uint8List?> readVideoRemoteLibraryCover(
  FushiDatabase db,
  String bookUid,
) async {
  final VideoBookRow? row = await VideoBookRepository(db).getByBookUid(bookUid);
  final String? path = row?.coverPath;
  if (path == null || path.isEmpty) return null;
  final File file = File(path);
  if (!await file.exists()) return null;
  return file.readAsBytes();
}

/// 点播清单：库页同一份视频行（[VideoBookRepository.listForShelf]），最近播放在前，
/// 从没播过的按入库时间新→旧。属于合集的带上合集名（手机端副标题 / 搜索用）。
Future<List<VideoRemoteLibraryItem>> listVideoRemoteLibrary(
  FushiDatabase db,
) async {
  final VideoBookRepository repo = VideoBookRepository(db);
  final List<VideoBookRow> rows = await repo.listForShelf();
  final Map<String, int> primary = await db.getPrimaryCollectionIdByEntry();
  final Map<int, String> collectionNames = <int, String>{
    for (final MediaCollectionRow row in await repo.getAllMediaCollections())
      row.id: row.name,
  };
  final List<VideoBookRow> sorted = List<VideoBookRow>.of(rows)
    ..sort(compareVideoRemoteLibraryRows);
  return <VideoRemoteLibraryItem>[
    for (final VideoBookRow row in sorted)
      VideoRemoteLibraryItem(
        bookUid: row.bookUid,
        title: row.title,
        collection:
            collectionNames[primary[MediaKind.video.compositeKey(row.bookUid)]],
        positionMs: row.lastPositionMs,
        lastPlayedAt: row.lastPlayedAt,
        hasCover: row.coverPath?.isNotEmpty ?? false,
      ),
  ];
}

/// 点播清单排序：播过的按最近播放新→旧排在前面，没播过的按入库时间新→旧，
/// 同刻按标题。
int compareVideoRemoteLibraryRows(VideoBookRow a, VideoBookRow b) {
  final int played = (b.lastPlayedAt ?? -1).compareTo(a.lastPlayedAt ?? -1);
  if (played != 0) return played;
  final int imported = (b.importedAt ?? -1).compareTo(a.importedAt ?? -1);
  if (imported != 0) return imported;
  return a.title.compareTo(b.title);
}

Future<void> _open({
  required FushiDatabase database,
  required GlobalKey<NavigatorState> navigatorKey,
  required Future<void> Function() stopAudiobook,
  required bool Function() isMigrationReadonly,
  required String bookUid,
}) async {
  // 迁移只读期间不开新页（新页会写进度），与卡片回看同一口径。
  if (isMigrationReadonly()) {
    throw const VideoRemoteException(409, 'host_busy');
  }
  final VideoBookRepository repo = VideoBookRepository(database);
  final VideoBookRow? row = await repo.getByBookUid(bookUid);
  if (row == null) throw const VideoRemoteException(404, 'video_missing');
  if (await isLocalVideoResourceMissing(row.videoPath)) {
    throw const VideoRemoteException(404, 'video_missing');
  }
  final NavigatorState? navigator = navigatorKey.currentState;
  if (navigator == null) throw const VideoRemoteException(409, 'host_busy');
  await DesktopLookupService.instance.bringMainWindowToFront();
  // 已经在放这一部：只把窗口带到前台，不重开（重开会从断点重新起播）。
  if (ExternalMediaNavigation.instance.activeVideoUid == bookUid) return;
  if (!await ExternalMediaNavigation.instance.closeActive()) {
    throw const VideoRemoteException(409, 'host_busy');
  }
  // 后台有声书要先走完它自己的最后一次落盘，再让视频接管音频。
  await stopAudiobook();
  if (!navigator.mounted) throw const VideoRemoteException(409, 'host_busy');
  // 与库页 / 控制通道打开视频同一口径：属于合集就作为合集一集打开（剧集面板 / 连播）。
  final Map<String, int> primary = await database
      .getPrimaryCollectionIdByEntry();
  if (!navigator.mounted) throw const VideoRemoteException(409, 'host_busy');
  unawaited(
    navigator.push<void>(
      adaptivePageRoute<void>(
        context: navigator.context,
        builder: (_) => VideoFushiPage.neutralized(
          bookUid: row.bookUid,
          repo: repo,
          playlistCollectionId:
              primary[MediaKind.video.compositeKey(row.bookUid)],
        ),
      ),
    ),
  );
}
