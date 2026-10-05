// 萌メーター式用户页：左（上）是资料卡（头像、昵称#、各类读完数与名次、字数与名次、
// 注册日、首条记录日）+ 社交动作；右（下）是书架（读完 / 在读 × 类别，游标分页）。
// 书架对观看者不可见（403 shelf_private）时显示「仅好友可见」。

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';

import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_common.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_work_page.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/utils.dart';

/// 观看者与该用户的好友关系（取服务端用户卡的 `relation`；只有字段缺失——旧服务端——
/// 时才由 `friends()` 推出）。
enum LeaderboardRelation { self, none, outgoing, incoming, friends }

/// 书架筛选：读完 / 在读（线上 `status` 值）。
enum LeaderboardShelfStatus {
  finished('finished'),
  reading('reading');

  const LeaderboardShelfStatus(this.wire);
  final String wire;
}

class LeaderboardUserPage extends ConsumerStatefulWidget {
  const LeaderboardUserPage({required this.accountId, super.key});

  final String accountId;

  @override
  ConsumerState<LeaderboardUserPage> createState() =>
      _LeaderboardUserPageState();
}

class _LeaderboardUserPageState extends ConsumerState<LeaderboardUserPage> {
  UserCard? _card;
  Object? _cardError;
  LeaderboardRelation _relation = LeaderboardRelation.none;
  bool _relationBusy = false;

  LeaderboardShelfStatus _status = LeaderboardShelfStatus.finished;
  LeaderboardKind? _kind;
  final List<ShelfItem> _rows = <ShelfItem>[];
  String? _next;
  bool _shelfLoading = false;
  bool _shelfPrivate = false;
  Object? _shelfError;
  int _shelfGeneration = 0;

  LeaderboardClient? get _client => ref.read(leaderboardServiceProvider).client;

  String? get _selfId {
    final LeaderboardService s = ref.read(leaderboardServiceProvider);
    return s.self?.account.id ?? s.account?.accountId;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadCard());
    unawaited(_loadShelf(reset: true));
  }

  Future<void> _loadCard() async {
    final LeaderboardClient? client = _client;
    if (client == null) return;
    setState(() => _cardError = null);
    try {
      final UserCard card = await client.user(widget.accountId);
      final LeaderboardRelation relation =
          _relationFromCard(card) ?? await _loadRelation(client);
      if (!mounted) return;
      setState(() {
        _card = card;
        _relation = relation;
      });
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.user', e, st);
      if (mounted) setState(() => _cardError = e);
    }
  }

  /// 服务端用户卡直接带观看者关系（签名请求时，陌生人是 `none`）；缺字段（旧服务端 /
  /// 匿名）返回 null，由 [_loadRelation] 退回按好友列表推断。未知的新值按无关系处理，
  /// 同样不再去拉好友列表。
  LeaderboardRelation? _relationFromCard(UserCard card) {
    switch (card.relation) {
      case 'none':
        return LeaderboardRelation.none;
      case 'self':
        return LeaderboardRelation.self;
      case 'friend':
        return LeaderboardRelation.friends;
      case 'outgoing':
        return LeaderboardRelation.outgoing;
      case 'incoming':
        return LeaderboardRelation.incoming;
      case null:
        return widget.accountId == _selfId ? LeaderboardRelation.self : null;
      default:
        return LeaderboardRelation.none;
    }
  }

  Future<LeaderboardRelation> _loadRelation(LeaderboardClient client) async {
    if (widget.accountId == _selfId) return LeaderboardRelation.self;
    final FriendList list = await client.friends();
    bool has(Iterable<LeaderboardAccount> accounts) =>
        accounts.any((LeaderboardAccount a) => a.id == widget.accountId);
    if (has(list.friends.map((Friend f) => f.account))) {
      return LeaderboardRelation.friends;
    }
    if (has(list.incoming.map((FriendRequest f) => f.account))) {
      return LeaderboardRelation.incoming;
    }
    if (has(list.outgoing.map((FriendRequest f) => f.account))) {
      return LeaderboardRelation.outgoing;
    }
    return LeaderboardRelation.none;
  }

  Future<void> _loadShelf({required bool reset}) async {
    final LeaderboardClient? client = _client;
    if (client == null) return;
    if (!reset && (_shelfLoading || _next == null)) return;
    final int gen = reset ? ++_shelfGeneration : _shelfGeneration;
    setState(() {
      _shelfLoading = true;
      _shelfError = null;
      if (reset) {
        _rows.clear();
        _next = null;
        _shelfPrivate = false;
      }
    });
    try {
      final ShelfPage page = await client.userShelf(
        widget.accountId,
        status: _status.wire,
        kind: _kind,
        cursor: reset ? null : _next,
      );
      if (!mounted || gen != _shelfGeneration) return;
      setState(() {
        _rows.addAll(page.rows);
        _next = page.next;
      });
    } on LeaderboardApiException catch (e, st) {
      if (!mounted || gen != _shelfGeneration) return;
      if (e.status == 403 && e.code == 'shelf_private') {
        setState(() => _shelfPrivate = true);
      } else {
        ErrorLogService.instance.log('Leaderboard.userShelf', e, st);
        setState(() => _shelfError = e);
      }
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.userShelf', e, st);
      if (mounted && gen == _shelfGeneration) setState(() => _shelfError = e);
    } finally {
      if (mounted && gen == _shelfGeneration) {
        setState(() => _shelfLoading = false);
      }
    }
  }

  Future<void> _friendAction() async {
    final LeaderboardClient? client = _client;
    if (client == null) return;
    setState(() => _relationBusy = true);
    try {
      final String state = await client.addFriend(widget.accountId);
      if (!mounted) return;
      setState(
        () => _relation = state == 'accepted'
            ? LeaderboardRelation.friends
            : LeaderboardRelation.outgoing,
      );
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.addFriend', e, st);
      if (mounted) FushiToast.show(msg: leaderboardErrorText(e));
    } finally {
      if (mounted) setState(() => _relationBusy = false);
    }
  }

  Future<void> _block() async {
    final UserCard? card = _card;
    final LeaderboardClient? client = _client;
    if (card == null || client == null) return;
    final FushiDestructiveConfirmResult? ok =
        await showAppDialog<FushiDestructiveConfirmResult>(
          context: context,
          builder: (BuildContext _) => FushiDestructiveConfirmDialog(
            title: t.leaderboard_user_block_title,
            message: t.leaderboard_user_block_message(user: card.account.tag),
            confirmLabel: t.leaderboard_user_block,
            leadingIcon: Icons.block,
          ),
        );
    if (ok == null || !mounted) return;
    try {
      await client.block(widget.accountId);
      FushiToast.show(msg: t.leaderboard_user_blocked);
      if (mounted) Navigator.of(context).pop();
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.block', e, st);
      FushiToast.show(msg: leaderboardErrorText(e));
    }
  }

  Future<void> _report() async {
    final UserCard? card = _card;
    final LeaderboardClient? client = _client;
    if (card == null || client == null) return;
    final String? reason = await showLeaderboardReportDialog(
      context,
      targetLabel: card.account.tag,
    );
    if (reason == null) return;
    try {
      await client.report(
        targetKind: 'account',
        targetId: widget.accountId,
        reason: reason,
      );
      FushiToast.show(msg: t.leaderboard_report_done);
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.report', e, st);
      FushiToast.show(msg: leaderboardErrorText(e));
    }
  }

  Future<void> _share() async {
    final Uri? base = leaderboardShareBase(ref);
    if (base == null) return;
    await FushiShare.shareText(
      LeaderboardClient.shareUserUrl(base, widget.accountId).toString(),
    );
  }

  void _openUser(String id) {
    if (id == widget.accountId) return;
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext _) => LeaderboardUserPage(accountId: id),
        ),
      ),
    );
  }

  void _openWork(String id) => unawaited(
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => LeaderboardWorkPage(workId: id),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final UserCard? card = _card;
    return FushiPageScaffold(
      title: card?.account.tag ?? t.leaderboard_user_title,
      actions: <Widget>[
        FushiIconButton(
          icon: Icons.ios_share,
          tooltip: t.leaderboard_share,
          onTap: _share,
        ),
      ],
      body: FushiRefreshIndicator(
        onRefresh: () async {
          await Future.wait(<Future<void>>[
            _loadCard(),
            _loadShelf(reset: true),
          ]);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: withBottomSafeInset(
            context,
            EdgeInsets.all(tokens.spacing.card),
          ),
          children: <Widget>[
            _buildCard(tokens),
            SizedBox(height: tokens.spacing.card),
            ..._buildShelf(tokens),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(FushiDesignTokens tokens) {
    final UserCard? card = _card;
    if (_cardError != null) {
      return LeaderboardErrorView(
        error: _cardError!,
        onRetry: () => unawaited(_loadCard()),
      );
    }
    if (card == null) {
      return const FushiLoadingView();
    }
    String standing(LeaderboardMetric m) {
      final UserStanding s = card.standing(m);
      final String value = leaderboardMetricValue(m, s.value);
      return s.rank == null
          ? value
          : t.leaderboard_user_stat_ranked(value: value, rank: s.rank!);
    }

    return FushiCard(
      key: const ValueKey<String>('leaderboard-user-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              LeaderboardAvatar(account: card.account, size: 64),
              SizedBox(width: tokens.spacing.card),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(card.account.tag, style: tokens.type.pageTitle),
                    Text(
                      t.leaderboard_user_joined(
                        date: leaderboardDate(card.createdAt),
                      ),
                      style: tokens.type.metadata,
                    ),
                    Text(
                      t.leaderboard_user_first_record(
                        date: card.firstRecordDate ?? '—',
                      ),
                      style: tokens.type.metadata,
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: tokens.spacing.gap),
          for (final LeaderboardMetric m in LeaderboardMetric.values)
            Padding(
              padding: EdgeInsets.only(bottom: tokens.spacing.gap / 2),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 72,
                    child: Text(
                      leaderboardMetricLabel(m),
                      style: tokens.type.metadata,
                    ),
                  ),
                  Expanded(
                    child: Text(standing(m), style: tokens.type.listSubtitle),
                  ),
                ],
              ),
            ),
          if (card.rankComputedAt == null)
            Text(t.leaderboard_board_generating, style: tokens.type.metadata),
          SizedBox(height: tokens.spacing.gap),
          _buildActions(tokens),
        ],
      ),
    );
  }

  Widget _buildActions(FushiDesignTokens tokens) {
    final List<Widget> buttons = <Widget>[];
    switch (_relation) {
      case LeaderboardRelation.self:
        break;
      case LeaderboardRelation.none:
        buttons.add(
          FushiFilledButton.icon(
            key: const ValueKey<String>('leaderboard-user-add-friend'),
            onPressed: _relationBusy ? null : () => unawaited(_friendAction()),
            icon: const FushiIcon(Icons.person_add_alt_1_outlined),
            label: Text(t.leaderboard_user_add_friend),
          ),
        );
      case LeaderboardRelation.incoming:
        buttons.add(
          FushiFilledButton.icon(
            onPressed: _relationBusy ? null : () => unawaited(_friendAction()),
            icon: const FushiIcon(Icons.how_to_reg_outlined),
            label: Text(t.leaderboard_user_accept),
          ),
        );
      case LeaderboardRelation.outgoing:
        buttons.add(
          FushiFilledButton.tonal(
            onPressed: null,
            child: Text(t.leaderboard_user_requested),
          ),
        );
      case LeaderboardRelation.friends:
        buttons.add(
          FushiFilledButton.tonalIcon(
            onPressed: null,
            icon: const FushiIcon(Icons.people_alt_outlined),
            label: Text(t.leaderboard_user_is_friend),
          ),
        );
    }
    if (_relation != LeaderboardRelation.self) {
      buttons.addAll(<Widget>[
        FushiOutlinedButton.icon(
          onPressed: () => unawaited(_block()),
          icon: const FushiIcon(Icons.block),
          label: Text(t.leaderboard_user_block),
        ),
        FushiOutlinedButton.icon(
          onPressed: () => unawaited(_report()),
          icon: const FushiIcon(Icons.flag_outlined),
          label: Text(t.leaderboard_report),
        ),
      ]);
    }
    buttons.add(
      FushiOutlinedButton.icon(
        onPressed: () => unawaited(_share()),
        icon: const FushiIcon(Icons.ios_share),
        label: Text(t.leaderboard_share),
      ),
    );
    return Wrap(
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap,
      children: buttons,
    );
  }

  void _selectShelf(VoidCallback change) {
    setState(change);
    unawaited(_loadShelf(reset: true));
  }

  List<Widget> _buildShelf(FushiDesignTokens tokens) {
    final List<Widget> out = <Widget>[
      LeaderboardChoiceRow<LeaderboardShelfStatus>(
        keyPrefix: 'leaderboard-shelf-status',
        values: LeaderboardShelfStatus.values,
        selected: _status,
        labelOf: (LeaderboardShelfStatus s) =>
            s == LeaderboardShelfStatus.finished
            ? t.leaderboard_shelf_finished
            : t.leaderboard_shelf_reading,
        onSelected: (LeaderboardShelfStatus s) =>
            _selectShelf(() => _status = s),
      ),
      SizedBox(height: tokens.spacing.gap),
      LeaderboardChoiceRow<LeaderboardKind?>(
        keyPrefix: 'leaderboard-shelf-kind',
        values: const <LeaderboardKind?>[null, ...LeaderboardKind.values],
        selected: _kind,
        labelOf: (LeaderboardKind? k) =>
            k == null ? t.leaderboard_kind_all : leaderboardKindLabel(k),
        onSelected: (LeaderboardKind? k) => _selectShelf(() => _kind = k),
      ),
      SizedBox(height: tokens.spacing.gap),
    ];
    if (_shelfPrivate) {
      out.add(
        FushiPlaceholderMessage(
          key: const ValueKey<String>('leaderboard-shelf-private'),
          icon: Icons.lock_outline,
          message: t.leaderboard_user_shelf_private,
        ),
      );
      return out;
    }
    if (_shelfError != null && _rows.isEmpty) {
      out.add(
        LeaderboardErrorView(
          error: _shelfError!,
          onRetry: () => unawaited(_loadShelf(reset: true)),
        ),
      );
      return out;
    }
    if (!_shelfLoading && _rows.isEmpty) {
      out.add(
        FushiPlaceholderMessage(
          icon: Icons.menu_book_outlined,
          message: t.leaderboard_shelf_empty,
        ),
      );
      return out;
    }
    for (final ShelfItem item in _rows) {
      out.add(_buildShelfRow(tokens, item));
    }
    out.add(
      LeaderboardLoadMore(
        hasMore: _next != null,
        loading: _shelfLoading,
        onLoadMore: () => unawaited(_loadShelf(reset: false)),
      ),
    );
    return out;
  }

  Widget _buildShelfRow(FushiDesignTokens tokens, ShelfItem item) {
    final String when = _status == LeaderboardShelfStatus.reading
        ? t.leaderboard_shelf_reading
        : leaderboardFinishedLabel(item.finishedDate, item.finishedAt);
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap),
      child: FushiCard(
        key: ValueKey<String>('leaderboard-shelf-${item.work.id}'),
        onTap: () => _openWork(item.work.id),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            LeaderboardCover(work: item.work),
            SizedBox(width: tokens.spacing.card),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '$when · ${t.leaderboard_readers(n: item.readers)}',
                    style: tokens.type.metadata,
                  ),
                  Text(
                    item.work.title,
                    style: tokens.type.listTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (item.work.author.isNotEmpty)
                    Text(
                      item.work.author,
                      style: tokens.type.listSubtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (item.wall.isNotEmpty) ...<Widget>[
                    SizedBox(height: tokens.spacing.gap / 2),
                    Wrap(
                      spacing: tokens.spacing.gap / 2,
                      runSpacing: tokens.spacing.gap / 2,
                      children: <Widget>[
                        for (final LeaderboardAccount a in item.wall)
                          LeaderboardAvatar(
                            account: a,
                            size: 28,
                            onTap: () => _openUser(a.id),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
