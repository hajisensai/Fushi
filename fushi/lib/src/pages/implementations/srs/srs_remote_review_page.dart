/// 远程复习（docs/specs/2026-11-01-srs-remote-review-design.md）：在已配对设备（互联主机）的复习库上直接刷卡。
///
/// 入口在复习首页的「已配对设备」分区（`srs_deck_home_paired.dart`，用户 2026-11-07 拍板方案 A）：每台主机一组，
/// 展开就是它的牌组树，与本机牌组同一个行组件。卡组不下载。复习页、笔记编辑、牌组设置、浏览、自定义学习都是
/// 本机复习用的同一套页面，只是跑在 [SrsRemoteCollectionScope] 这个子作用域里：`srsStoreProvider` 换成转发到
/// 主机的 [SrsRemoteStore]，媒体换成按名字从主机补拉的缓存（[SrsRemoteMediaStore]）。所以功能与在本机复习一致。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart'
    show SrsRemoteServedProfile;
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/srs/srs_app_runtime.dart';
import 'package:fushi/src/srs/srs_card_autoplay.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_remote_store_client.dart';
import 'package:fushi/src/sync/interconnect_host_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/video_remote_targets.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 远程复习失败的提示文案（主机的机读码 / 连接层的码）。
String srsRemoteReviewErrorText(InterconnectHostError e) => switch (e.message) {
  InterconnectHostError.unreachableCode ||
  InterconnectHostError.certificateMismatchCode =>
    t.srs_remote_review_error_unreachable,
  SrsRemoteStoreError.profileChanged =>
    t.srs_remote_review_error_profile_changed,
  SrsRemoteStoreError.unavailable => t.srs_remote_review_error_unavailable,
  SrsRemoteStoreError.stale => t.srs_remote_review_card_changed,
  _ => t.srs_remote_review_error_other(code: e.message),
};

/// 连上一台主机后的远程复习会话：转发到主机的库 + 按名字补拉的媒体缓存。
class SrsRemoteSession {
  const SrsRemoteSession({
    required this.client,
    required this.store,
    required this.media,
  });

  final SrsRemoteHostClient client;
  final SrsRemoteStore store;
  final SrsRemoteMediaStore media;
}

/// 找主机、连主机。单独成一个 provider，测试换成打到内存主机的实现。
class SrsRemoteHostConnector {
  const SrsRemoteHostConnector(this.app);

  final AppModel app;

  /// 互联配置在 app 库里；库还没开（启动早期 / 测试替身）时没有可用主机。
  SyncRepository? get repository =>
      app.isDatabaseOpen ? SyncRepository(app.database) : null;

  /// 本机互联配置此刻允许连的已配对主机（只读本地库，不走网络：总开关、服务端模式、启用且有凭据的条目）。
  /// 缓存了主机列表的调用方每次复用前用它对账。
  Future<List<InterconnectHostTarget>> configured() async {
    final SyncRepository? repo = repository;
    if (repo == null) return const <InterconnectHostTarget>[];
    return configuredInterconnectHostTargets(repo);
  }

  /// [candidates] 里声明了远程复习能力的主机（走网络探 `/api/capabilities`，没应答的不列）。
  Future<List<InterconnectHostTarget>> supporting(
    List<InterconnectHostTarget> candidates,
  ) async {
    final SyncRepository? repo = repository;
    if (repo == null || candidates.isEmpty) {
      return const <InterconnectHostTarget>[];
    }
    return filterSrsRemoteStoreTargets(repo, candidates);
  }

  /// 本机当前配置的 profile uid：主机提供几份 profile 时直接打开同一份（见 [SrsRemoteStore.connect]）。
  Future<String?> _localProfileUid() async {
    if (!app.isDatabaseOpen) return null;
    try {
      return await app.database.profileUidOf(
        await app.database.resolveActiveProfileId(),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsRemoteReview.localProfile', e, stack);
      return null;
    }
  }

  /// 连上 [target]：握手拿到主机的 profile，失败抛 [InterconnectHostError]。主机提供几份 profile 又没有
  /// 本机这份时交给 [chooseProfile] 让用户选，用户取消抛 [SrsRemoteProfileChoiceCancelled]。
  Future<SrsRemoteSession> open(
    InterconnectHostTarget target, {
    SrsRemoteProfileChooser? chooseProfile,
  }) async {
    final SyncRepository? repository = this.repository;
    if (repository == null) {
      throw StateError('app database is closed');
    }
    final SrsRemoteHostClient client = SrsRemoteHostClient(
      repository: repository,
      peer: target.peer,
    );
    final SrsRemoteMediaStore media = SrsRemoteMediaStore(
      SrsRemoteMediaStore.directoryFor(
        await getTemporaryDirectory(),
        target.hostId,
      ),
      client,
    );
    final SrsRemoteStore store = await SrsRemoteStore.connect(
      client,
      preferProfile: await _localProfileUid(),
      chooseProfile: chooseProfile,
      prefetchMedia: media.prefetch,
    );
    return SrsRemoteSession(client: client, store: store, media: media);
  }
}

/// 主机提供几份 profile 时让用户选一份；返回 null = 用户取消。
typedef SrsRemoteProfileChooser =
    Future<String?> Function(List<SrsRemoteServedProfile> profiles);

/// 「选择复习库」对话框（[SrsRemoteProfileChooser] 的界面实现）。
Future<String?> showSrsRemoteProfileChoice(
  BuildContext context,
  List<SrsRemoteServedProfile> profiles,
) {
  return showFushiChoiceDialog<String>(
    context: context,
    title: t.srs_remote_review_choose_profile,
    message: t.srs_remote_review_choose_profile_hint,
    icon: FushiIcons.profiles,
    options: <FushiChoiceOption<String>>[
      for (final SrsRemoteServedProfile p in profiles)
        FushiChoiceOption<String>(
          value: p.uid,
          label: p.name.isEmpty ? t.srs_remote_review_profile_unnamed : p.name,
          subtitle: t.srs_remote_review_profile_notes(n: p.notes),
        ),
    ],
  );
}

final Provider<SrsRemoteHostConnector> srsRemoteHostConnectorProvider =
    Provider<SrsRemoteHostConnector>(
      (Ref ref) => SrsRemoteHostConnector(ref.watch(appProvider)),
    );

/// 把主机上的复习库装进子作用域：作用域里的复习页 / 笔记编辑 / 牌组设置 / 浏览读写的都是主机的库。
///
/// Riverpod 的子作用域只替换被覆盖的 provider：读了 `srsStoreProvider` 的派生 provider 若不在这里重建，
/// 读到的仍是根容器（本机）的库，所以凡是可达页面用到的派生 provider 都在这里一并覆盖：
/// - 媒体库与音频出口（卡面 / 原生 Fushi 卡片 / `[sound:]` 播放都经它们读媒体）；
/// - RWKV 服务与 app 运行时置空：RWKV 与参数优化在主机上跑，本机的那份不碰主机的库；
/// - 修订号是作用域自己的：远程写入只叫醒作用域里的页面，不触发本机复习库的互联推送。
class SrsRemoteCollectionScope extends StatelessWidget {
  const SrsRemoteCollectionScope({
    super.key,
    required this.store,
    required this.media,
    required this.child,
  });

  final SrsRemoteStore store;
  final SrsRemoteMediaStore media;
  final Widget child;

  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: <Override>[
      srsStoreProvider.overrideWith((Ref ref) => store),
      srsMediaStoreProvider.overrideWith((Ref ref) => media),
      srsCardAudioOutputProvider.overrideWith(srsDefaultCardAudioOutput),
      srsRwkvServiceProvider.overrideWith((Ref ref) => null),
      srsAppRuntimeProvider.overrideWith((Ref ref) => null),
      srsRevisionProvider.overrideWith((Ref ref) => 0),
      srsLocalWriteProvider.overrideWith((Ref ref) => 0),
    ],
    child: child,
  );
}
