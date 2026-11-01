/// 远程复习（docs/specs/2026-11-01-srs-remote-review-design.md）：选一台已配对的互联主机 → 它的牌组 → 复习。
///
/// 卡组不下载。复习页、笔记编辑、牌组设置、浏览、自定义学习都是本机复习用的同一套页面，只是跑在
/// [SrsRemoteCollectionScope] 这个子作用域里：`srsStoreProvider` 换成转发到主机的 [SrsRemoteStore]，
/// 媒体换成按名字从主机补拉的缓存（[SrsRemoteMediaStore]）。所以功能与在本机复习一致。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_browse.dart' show srsDeckQuery;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsCustomStudy;
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_deck_settings_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_app_runtime.dart';
import 'package:fushi/src/srs/srs_card_autoplay.dart';
import 'package:fushi/src/srs/srs_change_note_type.dart';
import 'package:fushi/src/srs/srs_custom_study_flow.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_remote_store_client.dart';
import 'package:fushi/src/sync/interconnect_host_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/video_remote_targets.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

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

/// 入口：列出提供远程复习的互联主机，选一台后进它的牌组。只有一台时直接进。
class SrsRemoteReviewEntryPage extends ConsumerStatefulWidget {
  const SrsRemoteReviewEntryPage({super.key, this.probeTargets});

  /// 探测可用主机（测试覆写）。
  final Future<List<InterconnectHostTarget>> Function(SyncRepository repo)?
  probeTargets;

  @override
  ConsumerState<SrsRemoteReviewEntryPage> createState() =>
      _SrsRemoteReviewEntryPageState();
}

class _SrsRemoteReviewEntryPageState
    extends ConsumerState<SrsRemoteReviewEntryPage> {
  List<InterconnectHostTarget>? _targets;
  String? _error;
  bool _loading = true;
  SrsRemoteHostClient? _connecting;

  SyncRepository get _repo => SyncRepository(ref.read(appProvider).database);

  @override
  void initState() {
    super.initState();
    unawaited(_probe(autoOpen: true));
  }

  @override
  void dispose() {
    _connecting?.cancelPending();
    super.dispose();
  }

  Future<void> _probe({bool autoOpen = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final List<InterconnectHostTarget> targets =
        await (widget.probeTargets ?? probeSrsRemoteStoreTargets)(_repo);
    if (!mounted) return;
    setState(() {
      _targets = targets;
      _loading = false;
    });
    if (autoOpen && targets.length == 1) await _open(targets.single);
  }

  Future<void> _open(InterconnectHostTarget target) async {
    _connecting?.cancelPending();
    final SrsRemoteHostClient client = SrsRemoteHostClient(
      repository: _repo,
      peer: target.peer,
    );
    setState(() {
      _connecting = client;
      _error = null;
      _loading = true;
    });
    final SrsRemoteStore store;
    final SrsRemoteMediaStore media;
    try {
      media = SrsRemoteMediaStore(
        SrsRemoteMediaStore.directoryFor(
          await getTemporaryDirectory(),
          target.hostId,
        ),
        client,
      );
      store = await SrsRemoteStore.connect(
        client,
        prefetchMedia: media.prefetch,
      );
    } on InterconnectHostError catch (e) {
      if (!mounted || _connecting != client) return;
      setState(() {
        _error = srsRemoteReviewErrorText(e);
        _loading = false;
      });
      return;
    }
    if (!mounted || _connecting != client) return;
    setState(() => _loading = false);
    await Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => SrsRemoteCollectionScope(
          store: store,
          media: media,
          child: SrsRemoteDeckListPage(hostName: target.displayName),
        ),
      ),
    );
  }

  void _refresh() => unawaited(_probe());

  @override
  Widget build(BuildContext context) {
    final String title = t.srs_remote_review_title;
    return FushiPageScaffold(
      title: title,
      header: isGlassDesign(context) ? null : _topBar(context, title, _refresh),
      actions: isGlassDesign(context)
          ? <Widget>[
              FushiIconButton(
                icon: FushiIcons.refresh,
                tooltip: t.retry,
                onTap: _refresh,
              ),
            ]
          : const <Widget>[],
      body: Builder(
        builder: (BuildContext context) => AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.short),
          switchInCurve: FushiMotion.enter,
          switchOutCurve: FushiMotion.exit,
          child: KeyedSubtree(
            key: ValueKey<String>(
              _loading
                  ? 'loading'
                  : _error != null
                  ? 'error'
                  : 'hosts',
            ),
            child: _buildBody(context),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const SafeArea(bottom: false, child: FushiLoadingView());
    }
    final String? error = _error;
    if (error != null) return _errorView(error, _refresh);
    final List<InterconnectHostTarget> targets =
        _targets ?? const <InterconnectHostTarget>[];
    if (targets.isEmpty) {
      return Center(
        child: FushiPlaceholderMessage(
          key: const ValueKey<String>('srs_remote_no_hosts'),
          icon: FushiIcons.devices,
          message: t.srs_remote_review_hosts_empty,
          detail: t.srs_remote_review_hosts_empty_hint,
          action: FushiFilledButton.icon(
            onPressed: _refresh,
            icon: const FushiIcon(FushiIcons.refresh),
            label: Text(t.retry),
          ),
        ),
      );
    }
    return _list(context, <Widget>[
      _hint(context),
      for (int i = 0; i < targets.length; i++)
        FushiPressScale(
          child: FushiGroupedListItem(
            key: ValueKey<String>('srs_remote_host_${targets[i].hostId}'),
            index: i,
            count: targets.length,
            onTap: () => unawaited(_open(targets[i])),
            child: FushiListItem(
              density: srsListDensityOf(context),
              leading: const FushiListLeadingIcon(FushiIcons.devices),
              title: Text(targets[i].displayName),
              trailing: const FushiIcon(FushiIcons.chevronRight),
            ),
          ),
        ),
    ]);
  }
}

enum _RemoteDeckAction { customStudy, browse, settings }

/// 主机上的牌组列表（在 [SrsRemoteCollectionScope] 里）：点牌组进本机同一个复习页；「⋯」里是自定义学习、
/// 浏览此牌组的卡片、牌组设置；顶栏是添加笔记与浏览。
class SrsRemoteDeckListPage extends ConsumerStatefulWidget {
  const SrsRemoteDeckListPage({super.key, required this.hostName});

  final String hostName;

  @override
  ConsumerState<SrsRemoteDeckListPage> createState() =>
      _SrsRemoteDeckListPageState();
}

class _SrsRemoteDeckListPageState extends ConsumerState<SrsRemoteDeckListPage> {
  List<SrsDeckSummary>? _decks;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    try {
      final List<SrsDeckSummary> decks = await store.deckSummaries();
      if (!mounted) return;
      setState(() {
        _decks = decks;
        _error = null;
      });
    } on InterconnectHostError catch (e) {
      if (!mounted) return;
      setState(() => _error = srsRemoteReviewErrorText(e));
    }
  }

  Future<void> _push(WidgetBuilder builder) async {
    await Navigator.of(
      context,
    ).push<void>(adaptivePageRoute<void>(context: context, builder: builder));
    // 回来时重读计数（这一轮复习掉的卡、改过的设置）。
    if (mounted) await _load();
  }

  Future<void> _review(SrsDeckSummary deck, [SrsCustomStudy? custom]) => _push(
    (_) => SrsReviewPage(
      deckId: deck.deck.id,
      deckName: deck.fullName,
      custom: custom,
    ),
  );

  Future<void> _browse({String? query}) => _push(
    (_) => SrsBrowsePage(
      initialQuery: query,
      onChangeNoteType: showSrsChangeNoteTypeFlow,
      onMigrateToFushiCard: srsMigrateNotesToFushiCard,
    ),
  );

  void _onAction(SrsDeckSummary deck, _RemoteDeckAction action) {
    switch (action) {
      case _RemoteDeckAction.customStudy:
        srsRunLogged(
          'SrsRemoteDeckList.customStudy',
          () => srsRunCustomStudy(
            context,
            ref,
            deck,
            openReview: (SrsCustomStudy? custom) => _review(deck, custom),
          ),
        );
      case _RemoteDeckAction.browse:
        srsRunLogged(
          'SrsRemoteDeckList.browseDeck',
          () => _browse(query: srsDeckQuery(deck.fullName)),
        );
      case _RemoteDeckAction.settings:
        srsRunLogged(
          'SrsRemoteDeckList.settings',
          () => _push((_) => SrsDeckSettingsPage(deckId: deck.deck.id)),
        );
    }
  }

  void _refresh() => unawaited(_load());

  List<FushiToolbarItem> get _toolbar => <FushiToolbarItem>[
    FushiToolbarItem(
      key: const ValueKey<String>('srs_remote_add_note'),
      icon: FushiIcons.add,
      label: t.srs_note_add,
      onPressed: () => srsRunLogged(
        'SrsRemoteDeckList.addNote',
        () => _push((_) => const SrsNoteEditorPage()),
      ),
    ),
    FushiToolbarItem(
      key: const ValueKey<String>('srs_remote_browse'),
      icon: FushiIcons.search,
      label: t.srs_browse_title,
      onPressed: () => srsRunLogged('SrsRemoteDeckList.browse', _browse),
    ),
    FushiToolbarItem(
      key: const ValueKey<String>('srs_remote_refresh'),
      icon: FushiIcons.refresh,
      label: t.retry,
      onPressed: _refresh,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final String title = widget.hostName;
    return FushiPageScaffold(
      title: title,
      header: isGlassDesign(context)
          ? null
          : _topBar(context, title, _refresh, extra: _toolbar),
      actions: isGlassDesign(context)
          ? <Widget>[
              for (final FushiToolbarItem item in _toolbar)
                FushiIconButton(
                  icon: item.icon,
                  tooltip: item.label,
                  onTap: item.onPressed,
                ),
            ]
          : const <Widget>[],
      body: Builder(builder: _buildBody),
    );
  }

  Widget _buildBody(BuildContext context) {
    final String? error = _error;
    if (error != null) return _errorView(error, _refresh);
    final List<SrsDeckSummary>? decks = _decks;
    if (decks == null) {
      return const SafeArea(bottom: false, child: FushiLoadingView());
    }
    if (decks.isEmpty) {
      return Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.libraryAdd,
          message: t.srs_remote_review_decks_empty,
        ),
      );
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return _list(context, <Widget>[
      for (int i = 0; i < decks.length; i++)
        FushiPressScale(
          child: FushiGroupedListItem(
            key: ValueKey<String>('srs_remote_deck_${decks[i].deck.id}'),
            index: i,
            count: decks.length,
            onTap: () => srsRunLogged(
              'SrsRemoteDeckList.review',
              () => _review(decks[i]),
            ),
            child: FushiListItem(
              density: srsListDensityOf(context),
              padding: EdgeInsetsDirectional.only(
                start: tokens.spacing.gap * (1 + decks[i].depth),
                end: tokens.spacing.gap / 2,
              ),
              title: Text(
                decks[i].deck.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SrsCountTriple(
                    newCount: decks[i].newCount,
                    learnCount: decks[i].learnCount,
                    reviewCount: decks[i].reviewCount,
                    reviewPending: decks[i].rwkvPending,
                    dense: true,
                    tight: true,
                  ),
                  FushiPopupMenuButton<_RemoteDeckAction>(
                    key: ValueKey<String>(
                      'srs_remote_deck_menu_${decks[i].deck.id}',
                    ),
                    tooltip: t.srs_deck_menu,
                    icon: const FushiIcon(FushiIcons.more),
                    onSelected: (_RemoteDeckAction a) => _onAction(decks[i], a),
                    itemBuilder: (BuildContext context) =>
                        <PopupMenuEntry<_RemoteDeckAction>>[
                          PopupMenuItem<_RemoteDeckAction>(
                            value: _RemoteDeckAction.customStudy,
                            child: Text(t.srs_custom_study_title),
                          ),
                          PopupMenuItem<_RemoteDeckAction>(
                            value: _RemoteDeckAction.browse,
                            child: Text(t.srs_deck_browse_cards),
                          ),
                          PopupMenuItem<_RemoteDeckAction>(
                            value: _RemoteDeckAction.settings,
                            child: Text(t.srs_deck_settings),
                          ),
                        ],
                  ),
                ],
              ),
            ),
          ),
        ),
    ]);
  }
}

Widget _topBar(
  BuildContext context,
  String title,
  VoidCallback refresh, {
  List<FushiToolbarItem>? extra,
}) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  final NavigatorState? navigator = Navigator.maybeOf(context);
  return Padding(
    padding: EdgeInsets.fromLTRB(
      tokens.spacing.page,
      tokens.spacing.gap,
      tokens.spacing.page,
      tokens.spacing.gap,
    ),
    child: FushiFloatingTopBar(
      title: title,
      leading: <FushiToolbarItem>[
        if (navigator != null && navigator.canPop())
          FushiToolbarItem(
            icon: FushiIcons.back,
            label: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: () => unawaited(navigator.maybePop()),
          ),
      ],
      actions: <List<FushiToolbarItem>>[
        extra ??
            <FushiToolbarItem>[
              FushiToolbarItem(
                key: const ValueKey<String>('srs_remote_refresh'),
                icon: FushiIcons.refresh,
                label: t.retry,
                onPressed: refresh,
              ),
            ],
      ],
    ),
  );
}

Widget _errorView(String error, VoidCallback retry) => Center(
  child: FushiPlaceholderMessage(
    icon: FushiIcons.error,
    message: error,
    tone: FushiPlaceholderTone.error,
    action: FushiFilledButton.icon(
      onPressed: retry,
      icon: const FushiIcon(FushiIcons.refresh),
      label: Text(t.retry),
    ),
  ),
);

Widget _list(BuildContext context, List<Widget> items) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  return FushiEntranceScope(
    child: ListView.builder(
      padding: withBottomSafeInset(
        context,
        EdgeInsets.fromLTRB(
          tokens.spacing.page,
          tokens.spacing.gap + MediaQuery.paddingOf(context).top,
          tokens.spacing.page,
          tokens.spacing.section,
        ),
      ),
      itemCount: items.length,
      itemBuilder: fushiStaggeredItemBuilder(
        (BuildContext context, int index) => items[index],
      ),
    ),
  );
}

Widget _hint(BuildContext context) => Padding(
  padding: EdgeInsets.only(bottom: FushiDesignTokens.of(context).spacing.gap),
  child: Text(
    t.srs_remote_review_hint,
    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  ),
);

/// 测试与调用方用：主机媒体缓存目录（临时目录下按主机分）。
Future<Directory> srsRemoteMediaRootFor(String hostId) async =>
    SrsRemoteMediaStore.directoryFor(await getTemporaryDirectory(), hostId);
