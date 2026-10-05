// 作品页：封面、标题、作者、读完人数、读者列表（游标分页）、举报、分享。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';

import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_common.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_user_page.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/utils.dart';

class LeaderboardWorkPage extends ConsumerStatefulWidget {
  const LeaderboardWorkPage({required this.workId, super.key});

  final String workId;

  @override
  ConsumerState<LeaderboardWorkPage> createState() =>
      _LeaderboardWorkPageState();
}

class _LeaderboardWorkPageState extends ConsumerState<LeaderboardWorkPage> {
  WorkPage? _page;
  final List<WorkReader> _readers = <WorkReader>[];
  String? _next;
  bool _loading = false;
  Object? _error;
  int _generation = 0;

  LeaderboardClient? get _client => ref.read(leaderboardServiceProvider).client;

  @override
  void initState() {
    super.initState();
    unawaited(_load(reset: true));
  }

  Future<void> _load({required bool reset}) async {
    final LeaderboardClient? client = _client;
    if (client == null) return;
    if (!reset && (_loading || _next == null)) return;
    final int gen = reset ? ++_generation : _generation;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _readers.clear();
        _next = null;
      }
    });
    try {
      final WorkPage page = await client.work(
        widget.workId,
        cursor: reset ? null : _next,
      );
      if (!mounted || gen != _generation) return;
      setState(() {
        _page = page;
        _readers.addAll(page.rows);
        _next = page.next;
      });
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.work', e, st);
      if (mounted && gen == _generation) setState(() => _error = e);
    } finally {
      if (mounted && gen == _generation) setState(() => _loading = false);
    }
  }

  Future<void> _report() async {
    final WorkPage? page = _page;
    final LeaderboardClient? client = _client;
    if (page == null || client == null) return;
    final String? reason = await showLeaderboardReportDialog(
      context,
      targetLabel: page.work.title,
    );
    if (reason == null) return;
    try {
      await client.report(
        targetKind: 'work',
        targetId: widget.workId,
        reason: reason,
      );
      FushiToast.show(msg: t.leaderboard_report_done);
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.reportWork', e, st);
      FushiToast.show(msg: leaderboardErrorText(e));
    }
  }

  Future<void> _share() async {
    final Uri? base = leaderboardShareBase(ref);
    if (base == null) return;
    await FushiShare.shareText(
      LeaderboardClient.shareWorkUrl(base, widget.workId).toString(),
    );
  }

  void _openUser(String id) => unawaited(
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => LeaderboardUserPage(accountId: id),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final WorkPage? page = _page;
    return FushiPageScaffold(
      title: page?.work.title ?? t.leaderboard_work_title,
      actions: <Widget>[
        FushiIconButton(
          icon: Icons.flag_outlined,
          tooltip: t.leaderboard_report,
          enabled: page != null,
          onTap: _report,
        ),
        FushiIconButton(
          icon: Icons.ios_share,
          tooltip: t.leaderboard_share,
          onTap: _share,
        ),
      ],
      body: FushiRefreshIndicator(
        onRefresh: () => _load(reset: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: withBottomSafeInset(
            context,
            EdgeInsets.all(tokens.spacing.card),
          ),
          children: <Widget>[
            if (page == null && _error != null)
              LeaderboardErrorView(
                error: _error!,
                onRetry: () => unawaited(_load(reset: true)),
              )
            else if (page == null)
              const FushiLoadingView()
            else ...<Widget>[
              FushiCard(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    LeaderboardCover(work: page.work, width: 96),
                    SizedBox(width: tokens.spacing.card),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(page.work.title, style: tokens.type.pageTitle),
                          if (page.work.author.isNotEmpty)
                            Text(
                              page.work.author,
                              style: tokens.type.listSubtitle,
                            ),
                          SizedBox(height: tokens.spacing.gap),
                          Text(
                            leaderboardKindLabel(page.work.kind),
                            style: tokens.type.metadata,
                          ),
                          Text(
                            t.leaderboard_work_readers(n: page.readers),
                            style: tokens.type.listTitle,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              LeaderboardSectionTitle(t.leaderboard_work_reader_list),
              for (final WorkReader r in _readers)
                FushiListItem(
                  leading: LeaderboardAvatar(account: r.account),
                  title: Text(r.account.tag),
                  subtitle: Text(
                    leaderboardFinishedLabel(r.finishedDate, r.finishedAt),
                  ),
                  onTap: () => _openUser(r.account.id),
                ),
              if (_readers.isEmpty && !_loading)
                FushiPlaceholderMessage(
                  icon: Icons.people_outline,
                  message: t.leaderboard_work_no_readers,
                ),
              LeaderboardLoadMore(
                hasMore: _next != null,
                loading: _loading,
                onLoadMore: () => unawaited(_load(reset: false)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
