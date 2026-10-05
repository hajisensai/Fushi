// 排行榜页（设计 docs/specs/2026-09-28-leaderboard-accounts.md 第 5 节）。首页统计中心
// 入口旁单独一颗按钮进来（2026-10-01 从统计中心的第 5 个 tab 抽出）。
//
// 未开启：同意说明卡（会公开什么 / 不会上传什么）+ 注册 / 登录 / 恢复码导入入口；
// 未开启时本页不发任何网络请求。
// 已开启：页头（头像、昵称#、主页 / 好友 / 分享 / 账户）→ 同步状态行 → 榜单
// （范围 × 窗口 × 指标，或「作品人气」）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';

import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/leaderboard/leaderboard_store.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_account_page.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_common.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_friends_page.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_share_card.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_sign_in_page.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_user_page.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_work_page.dart';
import 'package:fushi/utils.dart';

/// 榜单每页行数。
const int kLeaderboardRankPageSize = 50;

/// 排行榜独立页：页头 + [LeaderboardTab]。排行榜自带周 / 月 / 总窗口，与统计中心
/// 的时间范围选择无关，所以不再挂在统计中心里当 tab。
class LeaderboardPage extends StatelessWidget {
  const LeaderboardPage({super.key});

  @override
  Widget build(BuildContext context) => FushiPageScaffold(
    title: t.leaderboard_title,
    body: const LeaderboardTab(),
  );
}

/// 排行榜页的主体：按账户状态在说明卡与榜单之间切换。
class LeaderboardTab extends ConsumerStatefulWidget {
  const LeaderboardTab({super.key});

  @override
  ConsumerState<LeaderboardTab> createState() => _LeaderboardTabState();
}

class _LeaderboardTabState extends ConsumerState<LeaderboardTab> {
  late Future<void> _loaded;

  @override
  void initState() {
    super.initState();
    _loaded = ref.read(leaderboardServiceProvider).load();
  }

  @override
  Widget build(BuildContext context) {
    final LeaderboardService service = ref.watch(leaderboardServiceProvider);
    return FutureBuilder<void>(
      future: _loaded,
      builder: (BuildContext context, AsyncSnapshot<void> snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const FushiLoadingView();
        }
        if (snap.hasError) {
          return LeaderboardErrorView(
            error: snap.error!,
            onRetry: () => setState(() => _loaded = service.load()),
          );
        }
        return service.status == LeaderboardStatus.active
            ? const LeaderboardActiveView()
            : const LeaderboardIntroView();
      },
    );
  }
}

/// 未开启：说明卡 + 三个入口。
class LeaderboardIntroView extends ConsumerWidget {
  const LeaderboardIntroView({super.key});

  Future<void> _openSignIn(BuildContext context, LeaderboardSignInMode mode) =>
      Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (BuildContext _) => LeaderboardSignInPage(mode: mode),
        ),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool accountGone = ref
        .watch(leaderboardServiceProvider)
        .accountGoneNotice;
    return ListView(
      key: const ValueKey<String>('leaderboard-intro'),
      padding: withBottomSafeInset(
        context,
        EdgeInsets.all(tokens.spacing.card),
      ),
      children: <Widget>[
        if (accountGone) ...<Widget>[
          Text(
            t.leaderboard_error_unknown_account,
            key: const ValueKey<String>('leaderboard-intro-account-gone'),
            style: tokens.type.listSubtitle.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
          SizedBox(height: tokens.spacing.card),
        ],
        FushiCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(t.leaderboard_intro_title, style: tokens.type.pageTitle),
              SizedBox(height: tokens.spacing.gap),
              Text(t.leaderboard_intro_body, style: tokens.type.listSubtitle),
              SizedBox(height: tokens.spacing.card),
              const LeaderboardPublicDataList(),
            ],
          ),
        ),
        SizedBox(height: tokens.spacing.card),
        Wrap(
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            FushiFilledButton.icon(
              key: const ValueKey<String>('leaderboard-intro-register'),
              onPressed: () => unawaited(
                _openSignIn(context, LeaderboardSignInMode.register),
              ),
              icon: const FushiIcon(Icons.person_add_alt_1_outlined),
              label: Text(t.leaderboard_intro_register),
            ),
            FushiOutlinedButton.icon(
              key: const ValueKey<String>('leaderboard-intro-login'),
              onPressed: () =>
                  unawaited(_openSignIn(context, LeaderboardSignInMode.login)),
              icon: const FushiIcon(Icons.login),
              label: Text(t.leaderboard_intro_login),
            ),
            FushiTextButton.icon(
              key: const ValueKey<String>('leaderboard-intro-recovery'),
              onPressed: () =>
                  unawaited(showLeaderboardRecoveryImportDialog(context)),
              icon: const FushiIcon(Icons.key_outlined),
              label: Text(t.leaderboard_intro_recovery),
            ),
          ],
        ),
      ],
    );
  }
}

/// 榜单下方是「用户榜」还是「作品人气」。
enum _BoardView { users, works }

/// 已开启：页头 + 同步状态 + 榜单。
class LeaderboardActiveView extends ConsumerStatefulWidget {
  const LeaderboardActiveView({super.key});

  @override
  ConsumerState<LeaderboardActiveView> createState() =>
      _LeaderboardActiveViewState();
}

class _LeaderboardActiveViewState extends ConsumerState<LeaderboardActiveView> {
  _BoardView _view = _BoardView.users;
  LeaderboardScope _scope = LeaderboardScope.global;
  LeaderboardWindow _window = LeaderboardWindow.week;
  LeaderboardMetric _metric = LeaderboardMetric.book;

  RankPage? _rank;
  List<RankRow> _rankRows = <RankRow>[];
  PopularPage? _popular;
  List<PopularWorkRow> _popularRows = <PopularWorkRow>[];
  bool _loading = false;
  bool _loadingMore = false;
  Object? _error;

  bool _syncing = false;
  Object? _syncError;
  Object? _selfError;

  /// 过期响应丢弃：筛选切换后旧请求晚到不得覆盖新结果。
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    final LeaderboardService service = ref.read(leaderboardServiceProvider);
    unawaited(_refreshSelf());
    unawaited(_reload());
    // 统计中心打开 = 上传时机之一（间隔 / 开关 / 上传设备判断都在服务里）。
    unawaited(
      service.maybeSyncInBackground().catchError((Object e, StackTrace st) {
        ErrorLogService.instance.log('Leaderboard.backgroundSync', e, st);
        if (mounted) setState(() => _syncError = e);
      }),
    );
  }

  Future<void> _refreshSelf() async {
    try {
      await ref.read(leaderboardServiceProvider).refreshSelf();
      if (mounted) setState(() => _selfError = null);
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.refreshSelf', e, st);
      if (mounted) setState(() => _selfError = e);
    }
  }

  LeaderboardKind? get _popularKind => switch (_metric) {
    LeaderboardMetric.book => LeaderboardKind.book,
    LeaderboardMetric.manga => LeaderboardKind.manga,
    LeaderboardMetric.video => LeaderboardKind.video,
    LeaderboardMetric.game => LeaderboardKind.game,
    LeaderboardMetric.chars => null,
  };

  Future<void> _reload() async {
    final LeaderboardClient? client = ref
        .read(leaderboardServiceProvider)
        .client;
    if (client == null) return;
    final int gen = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_view == _BoardView.users) {
        final RankPage page = await client.rank(
          metric: _metric,
          window: _window,
          scope: _scope,
          limit: kLeaderboardRankPageSize,
        );
        if (!mounted || gen != _generation) return;
        setState(() {
          _rank = page;
          _rankRows = page.rows;
        });
      } else {
        final PopularPage page = await client.popular(
          window: _window,
          kind: _popularKind,
          limit: kLeaderboardRankPageSize,
        );
        if (!mounted || gen != _generation) return;
        setState(() {
          _popular = page;
          _popularRows = page.rows;
        });
      }
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.loadBoard', e, st);
      if (mounted && gen == _generation) setState(() => _error = e);
    } finally {
      if (mounted && gen == _generation) setState(() => _loading = false);
    }
  }

  bool get _rankHasMore {
    final RankPage? page = _rank;
    if (page == null) return false;
    return _rankRows.length < page.total &&
        _rankRows.length % kLeaderboardRankPageSize == 0 &&
        _rankRows.isNotEmpty;
  }

  Future<void> _loadMoreRank() async {
    final LeaderboardClient? client = ref
        .read(leaderboardServiceProvider)
        .client;
    if (client == null || _loadingMore) return;
    final int gen = _generation;
    setState(() => _loadingMore = true);
    try {
      final RankPage page = await client.rank(
        metric: _metric,
        window: _window,
        scope: _scope,
        limit: kLeaderboardRankPageSize,
        offset: _rankRows.length,
      );
      if (!mounted || gen != _generation) return;
      setState(() => _rankRows = <RankRow>[..._rankRows, ...page.rows]);
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.loadMoreRank', e, st);
      if (mounted) FushiToast.show(msg: leaderboardErrorText(e));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  bool get _popularHasMore =>
      _popularRows.isNotEmpty &&
      _popularRows.length % kLeaderboardRankPageSize == 0;

  Future<void> _loadMorePopular() async {
    final LeaderboardClient? client = ref
        .read(leaderboardServiceProvider)
        .client;
    if (client == null || _loadingMore) return;
    final int gen = _generation;
    setState(() => _loadingMore = true);
    try {
      final PopularPage page = await client.popular(
        window: _window,
        kind: _popularKind,
        limit: kLeaderboardRankPageSize,
        offset: _popularRows.length,
      );
      if (!mounted || gen != _generation) return;
      setState(
        () => _popularRows = <PopularWorkRow>[..._popularRows, ...page.rows],
      );
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.loadMorePopular', e, st);
      if (mounted) FushiToast.show(msg: leaderboardErrorText(e));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() {
      _syncing = true;
      _syncError = null;
    });
    try {
      await ref.read(leaderboardServiceProvider).syncNow();
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.syncNow', e, st);
      if (mounted) setState(() => _syncError = e);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _claim() async {
    final FushiDestructiveConfirmResult? ok =
        await showAppDialog<FushiDestructiveConfirmResult>(
          context: context,
          builder: (BuildContext _) => FushiDestructiveConfirmDialog(
            title: t.leaderboard_sync_claim_title,
            message: t.leaderboard_sync_claim_message,
            confirmLabel: t.leaderboard_sync_claim_action,
            leadingIcon: Icons.sync_alt,
          ),
        );
    if (ok == null || !mounted) return;
    final LeaderboardService service = ref.read(leaderboardServiceProvider);
    // 登录 / 导入时没同意公开的本机账户：接管前先确认公开清单。
    final bool consent =
        !service.hasConsent &&
        await showLeaderboardUploadConsentDialog(context);
    if (!service.hasConsent && !consent) return;
    if (!mounted) return;
    setState(() {
      _syncing = true;
      _syncError = null;
    });
    try {
      await service.claimUploadDevice(consent: consent);
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.claimUploadDevice', e, st);
      if (mounted) setState(() => _syncError = e);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  void _openUser(String id) => unawaited(
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => LeaderboardUserPage(accountId: id),
      ),
    ),
  );

  void _openWork(String id) => unawaited(
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => LeaderboardWorkPage(workId: id),
      ),
    ),
  );

  void _push(Widget page) => unawaited(
    Navigator.of(
      context,
    ).push<void>(MaterialPageRoute<void>(builder: (BuildContext _) => page)),
  );

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final LeaderboardService service = ref.watch(leaderboardServiceProvider);
    return FushiRefreshIndicator(
      onRefresh: () async {
        await Future.wait(<Future<void>>[_refreshSelf(), _reload()]);
      },
      child: ListView(
        key: const ValueKey<String>('leaderboard-active'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: withBottomSafeInset(
          context,
          EdgeInsets.only(bottom: tokens.spacing.card * 2),
        ),
        children: <Widget>[
          _buildHeader(tokens, service),
          _buildSyncRow(tokens, service),
          _buildFilters(tokens),
          ..._buildBoard(tokens),
        ],
      ),
    );
  }

  Widget _buildHeader(FushiDesignTokens tokens, LeaderboardService service) {
    final LeaderboardSelf? self = service.self;
    final String selfId = self?.account.id ?? service.account?.accountId ?? '';
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.card,
        tokens.spacing.card,
        tokens.spacing.card,
        0,
      ),
      child: FushiCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                if (self != null)
                  LeaderboardAvatar(account: self.account, size: 48)
                else
                  const SizedBox.square(
                    dimension: 48,
                    child: FushiIcon(Icons.account_circle_outlined, size: 40),
                  ),
                SizedBox(width: tokens.spacing.gap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        self?.account.tag ?? t.leaderboard_header_loading,
                        key: const ValueKey<String>('leaderboard-self-tag'),
                        style: tokens.type.listTitle,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (_selfError != null)
                        Text(
                          leaderboardErrorText(_selfError!),
                          style: tokens.type.metadata,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: tokens.spacing.gap),
            Wrap(
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: <Widget>[
                FushiOutlinedButton.icon(
                  onPressed: selfId.isEmpty ? null : () => _openUser(selfId),
                  icon: const FushiIcon(Icons.person_outline),
                  label: Text(t.leaderboard_header_profile),
                ),
                FushiOutlinedButton.icon(
                  onPressed: () => _push(const LeaderboardFriendsPage()),
                  icon: const FushiIcon(Icons.group_outlined),
                  label: Text(t.leaderboard_header_friends),
                ),
                FushiOutlinedButton.icon(
                  key: const ValueKey<String>('leaderboard-header-share'),
                  onPressed: self == null
                      ? null
                      : () => unawaited(
                          showLeaderboardShareSheet(
                            context,
                            initialWindow: _window,
                          ),
                        ),
                  icon: const FushiIcon(Icons.ios_share),
                  label: Text(t.leaderboard_header_share),
                ),
                FushiOutlinedButton.icon(
                  onPressed: () => _push(const LeaderboardAccountPage()),
                  icon: const FushiIcon(Icons.manage_accounts_outlined),
                  label: Text(t.leaderboard_header_account),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSyncRow(FushiDesignTokens tokens, LeaderboardService service) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final LeaderboardLocalAccount? account = service.account;
    final int? last = account?.lastSyncAt;
    final String status = account != null && !account.uploadEnabled
        ? t.leaderboard_sync_upload_off
        : (last == null
              ? t.leaderboard_sync_never
              : t.leaderboard_sync_last(time: leaderboardDateTime(last)));
    final bool blockedElsewhere = service.isUploadDevice == false;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.card,
        tokens.spacing.gap,
        tokens.spacing.card,
        0,
      ),
      child: FushiCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const FushiIcon(Icons.cloud_sync_outlined, size: 20),
                SizedBox(width: tokens.spacing.gap),
                Expanded(
                  child: Text(
                    status,
                    key: const ValueKey<String>('leaderboard-sync-status'),
                    style: tokens.type.listSubtitle,
                  ),
                ),
                FushiTextButton(
                  key: const ValueKey<String>('leaderboard-sync-now'),
                  onPressed:
                      _syncing ||
                          blockedElsewhere ||
                          account?.uploadEnabled != true
                      ? null
                      : () => unawaited(_syncNow()),
                  child: _syncing
                      ? const SizedBox.square(
                          dimension: 16,
                          child: FushiCircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(t.leaderboard_sync_now),
                ),
              ],
            ),
            if (blockedElsewhere) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              Text(
                t.leaderboard_sync_owned_elsewhere,
                key: const ValueKey<String>('leaderboard-sync-elsewhere'),
                style: tokens.type.listSubtitle,
              ),
              SizedBox(height: tokens.spacing.gap),
              FushiFilledButton.tonalIcon(
                key: const ValueKey<String>('leaderboard-sync-claim'),
                onPressed: _syncing ? null : () => unawaited(_claim()),
                icon: const FushiIcon(Icons.sync_alt),
                label: Text(t.leaderboard_sync_claim_action),
              ),
            ],
            if ((service.droppedForShelfLimit ?? 0) > 0) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              Text(
                t.leaderboard_sync_shelf_limit(
                  limit: kLeaderboardMaxShelfRows,
                  count: service.droppedForShelfLimit!,
                ),
                key: const ValueKey<String>('leaderboard-sync-shelf-limit'),
                style: tokens.type.listSubtitle,
              ),
            ],
            if (_syncError != null) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              Text(
                leaderboardSyncErrorText(_syncError!),
                key: const ValueKey<String>('leaderboard-sync-error'),
                style: tokens.type.metadata.copyWith(color: colors.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _select(VoidCallback change) {
    setState(change);
    unawaited(_reload());
  }

  Widget _buildFilters(FushiDesignTokens tokens) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.card,
        tokens.spacing.card,
        tokens.spacing.card,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          LeaderboardChoiceRow<_BoardView>(
            keyPrefix: 'leaderboard-view',
            values: _BoardView.values,
            selected: _view,
            labelOf: (_BoardView v) => v == _BoardView.users
                ? t.leaderboard_view_users
                : t.leaderboard_view_works,
            onSelected: (_BoardView v) => _select(() {
              _view = v;
              // 作品人气没有「字数」维度。
              if (v == _BoardView.works && _metric == LeaderboardMetric.chars) {
                _metric = LeaderboardMetric.book;
              }
            }),
          ),
          SizedBox(height: tokens.spacing.gap),
          if (_view == _BoardView.users) ...<Widget>[
            LeaderboardChoiceRow<LeaderboardScope>(
              keyPrefix: 'leaderboard-scope',
              values: LeaderboardScope.values,
              selected: _scope,
              labelOf: (LeaderboardScope s) => s == LeaderboardScope.global
                  ? t.leaderboard_scope_global
                  : t.leaderboard_scope_friends,
              onSelected: (LeaderboardScope s) => _select(() => _scope = s),
            ),
            SizedBox(height: tokens.spacing.gap),
          ],
          LeaderboardChoiceRow<LeaderboardWindow>(
            keyPrefix: 'leaderboard-window',
            values: LeaderboardWindow.values,
            selected: _window,
            labelOf: leaderboardWindowLabel,
            onSelected: (LeaderboardWindow w) => _select(() => _window = w),
          ),
          SizedBox(height: tokens.spacing.gap),
          LeaderboardChoiceRow<LeaderboardMetric>(
            keyPrefix: 'leaderboard-metric',
            values: _view == _BoardView.users
                ? LeaderboardMetric.values
                : LeaderboardMetric.values
                      .where(
                        (LeaderboardMetric m) => m != LeaderboardMetric.chars,
                      )
                      .toList(),
            selected: _metric,
            labelOf: leaderboardMetricLabel,
            onSelected: (LeaderboardMetric m) => _select(() => _metric = m),
          ),
        ],
      ),
    );
  }

  /// 「我」这一行。服务端对不在快照里的观看者带回实时值、名次为空（快照每
  /// [kLeaderboardSnapshotInterval] 刷新一次，刚同步完的人一定还不在里面）：此时说「下次
  /// 刷新后排名」，只有本期确实没有数据才说「还没有上榜」。
  String _meText(RankPage page) {
    final UserStanding? me = page.me;
    if (me == null || me.value <= 0) return t.leaderboard_board_me_unranked;
    final String value = leaderboardMetricValue(_metric, me.value);
    final int? rank = me.rank;
    if (rank != null) return t.leaderboard_board_me(rank: rank, value: value);
    final int? computedAt = page.computedAt;
    return t.leaderboard_board_me_pending(
      value: value,
      time: computedAt == null
          ? t.leaderboard_board_generating
          : leaderboardDateTime(
              computedAt + kLeaderboardSnapshotInterval.inMilliseconds,
            ),
    );
  }

  String _computedLabel(int? computedAt) => computedAt == null
      ? t.leaderboard_board_generating
      : t.leaderboard_board_updated(time: leaderboardDateTime(computedAt));

  List<Widget> _buildBoard(FushiDesignTokens tokens) {
    if (_loading) {
      return <Widget>[
        const FushiLoadingView(),
      ];
    }
    if (_error != null) {
      return <Widget>[
        Padding(
          padding: EdgeInsets.all(tokens.spacing.card),
          child: LeaderboardErrorView(
            error: _error!,
            onRetry: () => unawaited(_reload()),
          ),
        ),
      ];
    }
    return _view == _BoardView.users
        ? _buildRankBoard(tokens)
        : _buildPopularBoard(tokens);
  }

  List<Widget> _buildRankBoard(FushiDesignTokens tokens) {
    final RankPage? page = _rank;
    if (page == null) return const <Widget>[];
    final String meText = _meText(page);
    return <Widget>[
      LeaderboardSectionTitle(
        _computedLabel(page.computedAt),
        trailing: Text(
          t.leaderboard_board_total(n: page.total),
          style: tokens.type.metadata,
        ),
      ),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: tokens.spacing.card),
        child: FushiCard(
          key: const ValueKey<String>('leaderboard-board-me'),
          selected: true,
          child: Text(meText, style: tokens.type.listTitle),
        ),
      ),
      if (_rankRows.isEmpty)
        Padding(
          padding: EdgeInsets.all(tokens.spacing.card),
          child: FushiPlaceholderMessage(
            icon: Icons.leaderboard_outlined,
            message: page.computedAt == null
                ? t.leaderboard_board_generating
                : t.leaderboard_board_empty,
          ),
        ),
      for (final RankRow row in _rankRows)
        FushiListItem(
          key: ValueKey<String>('leaderboard-rank-${row.account.id}'),
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: 36,
                child: Text(
                  '${row.rank}',
                  textAlign: TextAlign.center,
                  style: tokens.type.listTitle,
                ),
              ),
              SizedBox(width: tokens.spacing.gap),
              LeaderboardAvatar(account: row.account),
            ],
          ),
          title: Text(row.account.tag),
          trailing: Text(
            leaderboardMetricValue(_metric, row.value),
            style: tokens.type.listTitle,
          ),
          onTap: () => _openUser(row.account.id),
        ),
      LeaderboardLoadMore(
        hasMore: _rankHasMore,
        loading: _loadingMore,
        onLoadMore: () => unawaited(_loadMoreRank()),
      ),
    ];
  }

  List<Widget> _buildPopularBoard(FushiDesignTokens tokens) {
    final PopularPage? page = _popular;
    if (page == null) return const <Widget>[];
    return <Widget>[
      LeaderboardSectionTitle(_computedLabel(page.computedAt)),
      if (_popularRows.isEmpty)
        Padding(
          padding: EdgeInsets.all(tokens.spacing.card),
          child: FushiPlaceholderMessage(
            icon: Icons.local_fire_department_outlined,
            message: page.computedAt == null
                ? t.leaderboard_board_generating
                : t.leaderboard_board_empty,
          ),
        ),
      for (final PopularWorkRow row in _popularRows)
        FushiListItem(
          key: ValueKey<String>('leaderboard-popular-${row.work.id}'),
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: 36,
                child: Text(
                  '${row.rank}',
                  textAlign: TextAlign.center,
                  style: tokens.type.listTitle,
                ),
              ),
              SizedBox(width: tokens.spacing.gap),
              LeaderboardCover(work: row.work, width: 40),
            ],
          ),
          title: Text(row.work.title),
          subtitle: Text(
            row.work.author.isEmpty
                ? leaderboardKindLabel(row.work.kind)
                : '${row.work.author} · ${leaderboardKindLabel(row.work.kind)}',
          ),
          trailing: Text(
            t.leaderboard_readers(n: row.readers),
            style: tokens.type.metadata,
          ),
          onTap: () => _openWork(row.work.id),
        ),
      LeaderboardLoadMore(
        hasMore: _popularHasMore,
        loading: _loadingMore,
        onLoadMore: () => unawaited(_loadMorePopular()),
      ),
    ];
  }
}
