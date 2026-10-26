import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart' show NavigatorState;
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/disc/disc_format.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';

import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/video/disc/disc_session_entry.dart';
import 'package:fushi/src/media/video/disc/disc_session_launcher.dart';
import 'package:fushi/src/media/video/disc/disc_session_remote.dart';
import 'package:fushi/src/media/video/video_disc_menu.dart'
    show VideoDiscMenuKey;
import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_video_player_support.dart'
    show ctlVideoRemoteFailure;
import 'package:fushi/src/ops/op_context.dart';

/// 碟片：BD / DVD 原盘会话的控制通道路由（spec
/// `docs/specs/2026-10-26-ai-operations-agent-design.md` §2.2 / §8 P2）。每条路由调用
/// UI 按钮背后的同一个方法，不另写业务逻辑：
///
/// - 列盘：库页 / 详情页问「这个条目有哪几张盘」的唯一入口 [collectDiscRefs]（按盘根
///   归组，开盘用最近看过的那条成员），规格按 [readDiscFormatAtRoot]（角标同一判据）；
/// - 开盘：合集卡「进入原盘菜单」/ 详情页「播放原盘」的 [probeLocalDiscMenu]（开不了
///   菜单就说明原因，不静默降级）+ [openDiscSession]（沉浸式原盘会话）；
/// - 会话内：盘菜单键位 / 遥控器背后的 `discMenuKey`、「退出原盘」的退出汇聚点，经播放页
///   登记的 [VideoDiscRemoteControl]（与 `fushi_cli video …` 同一个登记表）。
///
/// 本机光驱：app 里没有「弹出光驱」「交给系统播放器」一类入口（音频 CD 的选光驱归音乐
/// 域），这里同样不给；远端原盘（已配对 host 的盘共享）要先签发共享，入口在详情页，
/// 不在本域。CLI 侧是 `fushi_cli disc …`（`packages/fushi_cli/lib/src/commands/disc_commands.dart`）。
List<CtlRoute> buildDiscCtlRoutes(OpContext context) => buildDiscCtlRoutesFor(
  database: () => context.appModel.database,
  videoEnabled: () =>
      context.appModel.moduleVisibility.isEnabled(ModuleId.video),
  isReadonly: () => context.appModel.isMigrationReadonly,
  probe: probeLocalDiscMenu,
  open: (DiscRef disc, int? collectionId) async {
    if (context.navigator == null) {
      throw const CtlFailure.conflict('主界面还没就绪');
    }
    await context.focusMainWindow();
    final NavigatorState? navigator = context.navigator;
    if (navigator == null || !navigator.mounted) {
      throw const CtlFailure.conflict('主界面还没就绪');
    }
    unawaited(
      openDiscSession(
        context: navigator.context,
        repo: VideoBookRepository(context.appModel.database),
        book: disc.book,
        collectionId: collectionId,
      ),
    );
  },
  session: () {
    final VideoPlaybackRemote? remote = videoPlaybackRemotes.current.value;
    return remote is VideoDiscRemoteControl
        ? remote as VideoDiscRemoteControl
        : null;
  },
);

/// 路由根。
const String kDiscCtlRoot = '/api/admin/disc';

/// 菜单键的 wire 名（= [VideoDiscMenuKey] 的枚举名）。
final List<String> kDiscCtlMenuKeys = <String>[
  for (final VideoDiscMenuKey key in VideoDiscMenuKey.values) key.name,
];

/// 可注入依赖的路由表（测试换掉开页面、探测与播放页）。
List<CtlRoute> buildDiscCtlRoutesFor({
  required FushiDatabase Function() database,
  required bool Function() videoEnabled,
  bool Function()? isReadonly,
  required Future<DiscMenuUnavailableReason?> Function(DiscRef disc) probe,
  required Future<void> Function(DiscRef disc, int? collectionId) open,
  required VideoDiscRemoteControl? Function() session,
  String Function(DiscMenuUnavailableReason reason) reasonText =
      discMenuUnavailableText,
}) {
  final _DiscCtl ctl = _DiscCtl(
    database: database,
    videoEnabled: videoEnabled,
    isReadonly: isReadonly ?? () => false,
    probe: probe,
    open: open,
    session: session,
    reasonText: reasonText,
  );
  return <CtlRoute>[
    CtlRoute.get('$kDiscCtlRoot/discs', ctl.list),
    CtlRoute.post('$kDiscCtlRoot/open', ctl.openDisc),
    CtlRoute.get('$kDiscCtlRoot/session', ctl.sessionStatus),
    CtlRoute.post('$kDiscCtlRoot/session/key', ctl.menuKey),
    CtlRoute.post('$kDiscCtlRoot/session/exit', ctl.exit),
  ];
}

class _DiscCtl {
  _DiscCtl({
    required this.database,
    required this.videoEnabled,
    required this.isReadonly,
    required this.probe,
    required this.open,
    required this.session,
    required this.reasonText,
  });

  final FushiDatabase Function() database;
  final bool Function() videoEnabled;
  final bool Function() isReadonly;
  final Future<DiscMenuUnavailableReason?> Function(DiscRef disc) probe;
  final Future<void> Function(DiscRef disc, int? collectionId) open;
  final VideoDiscRemoteControl? Function() session;
  final String Function(DiscMenuUnavailableReason reason) reasonText;

  void _requireVideo() {
    if (!videoEnabled()) {
      throw const CtlFailure.rejected('「视频」模块已关闭（设置 › 功能模块）');
    }
  }

  /// 全库的盘（与库页同一归组：一张盘 = 一个盘根，多条标题共用）。
  Future<List<DiscRef>> _discs() async =>
      collectDiscRefs(await VideoBookRepository(database()).listAll());

  Future<Map<String, int>> _primaryCollections() =>
      database().getPrimaryCollectionIdByEntry();

  int? _collectionOf(Map<String, int> primary, DiscRef disc) =>
      primary[MediaKind.video.compositeKey(disc.book.bookUid)];

  // ── 列盘 / 开盘 ──────────────────────────────────────────────────────

  /// `disc ls [关键词]`：库里的原盘（按盘号 / 目录名自然序）。
  Future<Object?> list(CtlCall call) async {
    _requireVideo();
    final String? search = call.optString('search');
    final Map<String, int> primary = await _primaryCollections();
    final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
    for (final DiscRef disc in await _discs()) {
      if (search != null &&
          !matchesMediaSearch(
            query: search,
            titles: <String>[disc.label, disc.book.title],
          )) {
        continue;
      }
      rows.add(await _discJson(disc, _collectionOf(primary, disc)));
    }
    return <String, Object?>{'discs': rows};
  }

  Future<Map<String, Object?>> _discJson(
    DiscRef disc,
    int? collectionId,
  ) async {
    final bool present =
        FileSystemEntity.typeSync(disc.rootPath) !=
        FileSystemEntityType.notFound;
    DiscFormat? format;
    if (present) {
      try {
        format = await readDiscFormatAtRoot(disc.rootPath);
      } on FileSystemException {
        format = null;
      }
    }
    format ??= discFormatHintForMemberPath(disc.book.videoPath);
    return <String, Object?>{
      'uid': disc.book.bookUid,
      'label': disc.label,
      'title': disc.book.title,
      'root': disc.rootPath,
      'format': format?.name,
      'present': present,
      'collectionId': ?collectionId,
      'lastPlayedAt': ?disc.lastPlayedAt,
    };
  }

  /// 按任一成员的 uid 找它所在的盘（开盘用这张盘最近看过的成员，与卡片同一选法）。
  Future<DiscRef> _discFor(String uid) async {
    final VideoBookRow? row = await VideoBookRepository(
      database(),
    ).getByBookUid(uid);
    if (row == null) throw CtlFailure.notFound('视频库里没有 $uid');
    final String? root = discRootForMemberPath(row.videoPath);
    if (root == null) throw CtlFailure.badRequest('$uid 不是原盘标题（disc ls 查看）');
    for (final DiscRef disc in await _discs()) {
      if (disc.rootPath == root) return disc;
    }
    throw CtlFailure.notFound('找不到 $uid 所在的盘');
  }

  /// `disc open <uid>`：进原盘菜单（沉浸式会话）。开不了菜单时如实报原因。
  Future<Object?> openDisc(CtlCall call) async {
    _requireVideo();
    if (isReadonly()) {
      throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态，不能打开媒体');
    }
    final DiscRef disc = await _discFor(call.requireString('uid'));
    final DiscMenuUnavailableReason? reason = await probe(disc);
    if (reason != null) {
      throw CtlFailure(501, reason.name, reasonText(reason));
    }
    final int? collectionId = _collectionOf(await _primaryCollections(), disc);
    await open(disc, collectionId);
    return <String, Object?>{
      'opened': true,
      'uid': disc.book.bookUid,
      'label': disc.label,
      'title': disc.book.title,
      'page': 'disc_session',
    };
  }

  // ── 会话内 ───────────────────────────────────────────────────────────

  VideoDiscRemoteControl _requireSession() {
    _requireVideo();
    final VideoDiscRemoteControl? control = session();
    if (control == null || control.discSession() == null) {
      throw const CtlFailure.conflict('没有打开的原盘会话（disc open 进入）');
    }
    return control;
  }

  Future<T> _run<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on VideoRemoteFailure catch (e) {
      throw ctlVideoRemoteFailure(e);
    }
  }

  /// `disc now`：当前原盘会话（没有时 `active: false`）。
  Future<Object?> sessionStatus(CtlCall call) async {
    _requireVideo();
    final VideoDiscSessionSnapshot? snapshot = session()?.discSession();
    if (snapshot == null) return <String, Object?>{'active': false};
    return <String, Object?>{'active': true, ...snapshot.toJson()};
  }

  /// `disc key <up|down|left|right|select|back|topMenu|titleMenu|popupMenu>`。
  Future<Object?> menuKey(CtlCall call) async {
    final String raw = call.requireString('key');
    final VideoDiscMenuKey? key = VideoDiscMenuKey.values
        .where(
          (VideoDiscMenuKey k) => k.name.toLowerCase() == raw.toLowerCase(),
        )
        .firstOrNull;
    if (key == null) {
      throw CtlFailure.badRequest(
        'key 只能是 ${kDiscCtlMenuKeys.join(' / ')}，收到「$raw」',
      );
    }
    final VideoDiscRemoteControl control = _requireSession();
    await _run(() => control.discMenuKey(key));
    return <String, Object?>{
      'key': key.name,
      'session': control.discSession()?.toJson(),
    };
  }

  /// `disc exit`：退出原盘会话回到上一页。
  Future<Object?> exit(CtlCall call) async {
    final VideoDiscRemoteControl control = _requireSession();
    await _run(control.exitDiscSession);
    return <String, Object?>{'exited': true};
  }
}
