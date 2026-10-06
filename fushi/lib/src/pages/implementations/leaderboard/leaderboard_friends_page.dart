// 好友页：我的好友码（= 账户 id，可复制 / 分享）、按好友码添加、收到的申请（接受 /
// 拒绝）、发出的申请（撤回）、好友列表（删除）、屏蔽列表（解除）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';

import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_common.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_user_page.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/utils.dart';

final RegExp _friendCodeShape = RegExp(r'^[A-Za-z0-9_-]{1,32}$');

class LeaderboardFriendsPage extends ConsumerStatefulWidget {
  const LeaderboardFriendsPage({super.key});

  @override
  ConsumerState<LeaderboardFriendsPage> createState() =>
      _LeaderboardFriendsPageState();
}

class _LeaderboardFriendsPageState
    extends ConsumerState<LeaderboardFriendsPage> {
  final TextEditingController _code = TextEditingController();
  FriendList? _list;
  List<LeaderboardAccount> _blocked = <LeaderboardAccount>[];
  Object? _error;
  String? _addMessage;
  bool _adding = false;

  /// 正在处理的账户 id（按钮去抖，避免连点发两次）。
  final Set<String> _busy = <String>{};

  LeaderboardClient? get _client => ref.read(leaderboardServiceProvider).client;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final LeaderboardClient? client = _client;
    if (client == null) return;
    try {
      final FriendList list = await client.friends();
      final List<LeaderboardAccount> blocked = await client.blocks();
      if (!mounted) return;
      setState(() {
        _list = list;
        _blocked = blocked;
        _error = null;
      });
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.friends', e, st);
      if (mounted) setState(() => _error = e);
    }
  }

  String get _myCode {
    final LeaderboardService s = ref.read(leaderboardServiceProvider);
    return s.self?.account.id ?? s.account?.accountId ?? '';
  }

  Future<void> _add() async {
    final LeaderboardClient? client = _client;
    final String code = _code.text.trim();
    if (client == null || code.isEmpty) return;
    if (!_friendCodeShape.hasMatch(code)) {
      setState(() => _addMessage = t.leaderboard_friends_bad_code);
      return;
    }
    setState(() {
      _adding = true;
      _addMessage = null;
    });
    try {
      final String state = await client.addFriend(code);
      if (!mounted) return;
      _code.clear();
      setState(
        () => _addMessage = state == 'accepted'
            ? t.leaderboard_friends_added
            : t.leaderboard_friends_requested,
      );
      await _load();
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.addFriendByCode', e, st);
      if (mounted) setState(() => _addMessage = leaderboardErrorText(e));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  /// 对某账户执行一个写操作后刷新整页。
  Future<void> _act(String id, Future<void> Function() op) async {
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await op();
      await _load();
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.friendAction', e, st);
      FushiToast.show(msg: leaderboardErrorText(e));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _removeFriend(LeaderboardAccount a) async {
    final FushiDestructiveConfirmResult? ok =
        await showAppDialog<FushiDestructiveConfirmResult>(
          context: context,
          builder: (BuildContext _) => FushiDestructiveConfirmDialog(
            title: t.leaderboard_friends_remove_title,
            message: t.leaderboard_friends_remove_message(user: a.tag),
            confirmLabel: t.leaderboard_friends_remove,
            leadingIcon: Icons.person_remove_outlined,
          ),
        );
    if (ok == null || !mounted) return;
    final LeaderboardClient? client = _client;
    if (client == null) return;
    await _act(a.id, () => client.removeFriend(a.id));
  }

  void _openUser(String id) => unawaited(
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => LeaderboardUserPage(accountId: id),
      ),
    ),
  );

  Widget _row(LeaderboardAccount a, String? subtitle, List<Widget> actions) {
    final bool busy = _busy.contains(a.id);
    return FushiListItem(
      key: ValueKey<String>('leaderboard-friend-${a.id}'),
      leading: LeaderboardAvatar(account: a),
      title: Text(a.tag),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: busy
          ? const SizedBox.square(
              dimension: 20,
              child: FushiCircularProgressIndicator(strokeWidth: 2),
            )
          : Row(mainAxisSize: MainAxisSize.min, children: actions),
      onTap: () => _openUser(a.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final LeaderboardClient? client = _client;
    final FriendList? list = _list;
    final String myCode = _myCode;
    return FushiPageScaffold(
      title: t.leaderboard_friends_title,
      actions: <Widget>[
        FushiIconButton(
          icon: Icons.refresh,
          tooltip: t.leaderboard_refresh,
          onTap: _load,
        ),
      ],
      body: ListView(
        padding: withBottomSafeInset(
          context,
          EdgeInsets.all(tokens.spacing.card),
        ),
        children: <Widget>[
          FushiCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  t.leaderboard_friends_my_code,
                  style: tokens.type.metadata,
                ),
                SelectableText(
                  myCode,
                  key: const ValueKey<String>('leaderboard-friend-code'),
                  style: tokens.type.pageTitle,
                ),
                SizedBox(height: tokens.spacing.gap),
                Wrap(
                  spacing: tokens.spacing.gap,
                  runSpacing: tokens.spacing.gap,
                  children: <Widget>[
                    FushiOutlinedButton.icon(
                      onPressed: myCode.isEmpty
                          ? null
                          : () => unawaited(leaderboardCopy(myCode)),
                      icon: const FushiIcon(Icons.copy),
                      label: Text(t.leaderboard_copy),
                    ),
                    FushiOutlinedButton.icon(
                      onPressed: myCode.isEmpty
                          ? null
                          : () => unawaited(
                              FushiShare.shareText(
                                t.leaderboard_friends_share_text(code: myCode),
                              ),
                            ),
                      icon: const FushiIcon(Icons.ios_share),
                      label: Text(t.leaderboard_share),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(height: tokens.spacing.card),
          FushiCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                FushiTextField(
                  key: const ValueKey<String>('leaderboard-friend-add-field'),
                  controller: _code,
                  labelText: t.leaderboard_friends_add_hint,
                  onSubmitted: (String _) => unawaited(_add()),
                ),
                SizedBox(height: tokens.spacing.gap),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FushiFilledButton.icon(
                    onPressed: _adding ? null : () => unawaited(_add()),
                    icon: const FushiIcon(Icons.person_add_alt_1_outlined),
                    label: Text(t.leaderboard_friends_add),
                  ),
                ),
                if (_addMessage != null) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap),
                  Text(_addMessage!, style: tokens.type.metadata),
                ],
              ],
            ),
          ),
          if (_error != null)
            LeaderboardErrorView(
              error: _error!,
              onRetry: () => unawaited(_load()),
            )
          else if (list == null)
            const FushiLoadingView()
          else if (client != null) ...<Widget>[
            LeaderboardSectionTitle(
              t.leaderboard_friends_incoming(n: list.incoming.length),
            ),
            for (final FriendRequest r in list.incoming)
              _row(r.account, leaderboardDate(r.at), <Widget>[
                FushiTextButton(
                  onPressed: () => unawaited(
                    _act(r.account.id, () async {
                      await client.addFriend(r.account.id);
                    }),
                  ),
                  child: Text(t.leaderboard_user_accept),
                ),
                FushiTextButton(
                  onPressed: () => unawaited(
                    _act(r.account.id, () => client.removeFriend(r.account.id)),
                  ),
                  child: Text(t.leaderboard_friends_decline),
                ),
              ]),
            LeaderboardSectionTitle(
              t.leaderboard_friends_outgoing(n: list.outgoing.length),
            ),
            for (final FriendRequest r in list.outgoing)
              _row(r.account, leaderboardDate(r.at), <Widget>[
                FushiTextButton(
                  onPressed: () => unawaited(
                    _act(r.account.id, () => client.removeFriend(r.account.id)),
                  ),
                  child: Text(t.leaderboard_friends_withdraw),
                ),
              ]),
            LeaderboardSectionTitle(
              t.leaderboard_friends_list(n: list.friends.length),
            ),
            if (list.friends.isEmpty)
              Text(t.leaderboard_friends_empty, style: tokens.type.metadata),
            for (final Friend f in list.friends)
              _row(
                f.account,
                t.leaderboard_friends_since(date: leaderboardDate(f.since)),
                <Widget>[
                  FushiTextButton(
                    onPressed: () => unawaited(_removeFriend(f.account)),
                    style: TextButton.styleFrom(foregroundColor: colors.error),
                    child: Text(t.leaderboard_friends_remove),
                  ),
                ],
              ),
            LeaderboardSectionTitle(
              t.leaderboard_friends_blocked(n: _blocked.length),
            ),
            for (final LeaderboardAccount a in _blocked)
              _row(a, null, <Widget>[
                FushiTextButton(
                  onPressed: () =>
                      unawaited(_act(a.id, () => client.unblock(a.id))),
                  child: Text(t.leaderboard_friends_unblock),
                ),
              ]),
          ],
        ],
      ),
    );
  }
}
