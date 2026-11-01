/// 复习远程刷卡（docs/specs/2026-11-01-srs-remote-review-design.md）：选电脑 → 选牌组 → 在电脑的复习上刷卡。
///
/// 卡组不下载：每张卡由电脑渲染好推过来，本机只显示、计时、把评分交回去。卡面复用本机复习页的
/// [SrsCardFace] / [SrsFushiCardView]，媒体经 [SrsRemoteMediaStore]（覆盖 `srsMediaStoreProvider`）读本地缓存。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_builtin.dart' show kSrsBuiltinFushiCardKey;
import 'package:fushi_srs/fushi_srs.dart' show SrsIntervalUnit;
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart'
    show
        SrsRatingButton,
        SrsRatingTone,
        srsIntervalLabel,
        srsReviewBridgeTokens;
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/srs/srs_card_autoplay.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_remote_review_client.dart';
import 'package:fushi/src/sync/interconnect_host_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/video_remote_targets.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 远程刷卡失败的提示文案（host 的机读码 / 连接层的码）。
String srsRemoteReviewErrorText(InterconnectHostError e) => switch (e.message) {
  InterconnectHostError.unreachableCode ||
  InterconnectHostError.certificateMismatchCode =>
    t.srs_remote_review_error_unreachable,
  SrsRemoteReviewError.profileChanged =>
    t.srs_remote_review_error_profile_changed,
  SrsRemoteReviewError.unavailable => t.srs_remote_review_error_unavailable,
  SrsRemoteReviewError.stale => t.srs_remote_review_card_changed,
  _ => t.srs_remote_review_error_other(code: e.message),
};

/// 入口：列出提供远程刷卡的电脑，选一台后列它的牌组。只有一台时直接进它的牌组。
class SrsRemoteReviewEntryPage extends ConsumerStatefulWidget {
  const SrsRemoteReviewEntryPage({super.key, this.probeTargets});

  /// 探测可用电脑（测试覆写）。
  final Future<List<InterconnectHostTarget>> Function(SyncRepository repo)?
  probeTargets;

  @override
  ConsumerState<SrsRemoteReviewEntryPage> createState() =>
      _SrsRemoteReviewEntryPageState();
}

class _SrsRemoteReviewEntryPageState
    extends ConsumerState<SrsRemoteReviewEntryPage> {
  List<InterconnectHostTarget>? _targets;
  InterconnectHostTarget? _target;
  SrsRemoteReviewClient? _client;
  ({String profile, List<SrsRemoteDeck> decks})? _decks;
  String? _error;
  bool _loading = true;

  SyncRepository get _repo => SyncRepository(ref.read(appProvider).database);

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
  }

  @override
  void dispose() {
    _client?.cancelPending();
    super.dispose();
  }

  Future<void> _probe() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final List<InterconnectHostTarget> targets =
        await (widget.probeTargets ?? probeSrsRemoteReviewTargets)(_repo);
    if (!mounted) return;
    setState(() {
      _targets = targets;
      _loading = false;
    });
    if (targets.length == 1) await _select(targets.single);
  }

  Future<void> _select(InterconnectHostTarget target) async {
    _client?.cancelPending();
    final SrsRemoteReviewClient client = SrsRemoteReviewClient(
      repository: _repo,
      peer: target.peer,
    );
    setState(() {
      _target = target;
      _client = client;
      _decks = null;
      _error = null;
      _loading = true;
    });
    try {
      final ({String profile, List<SrsRemoteDeck> decks}) decks = await client
          .decks();
      if (!mounted || _client != client) return;
      setState(() {
        _decks = decks;
        _loading = false;
      });
    } on InterconnectHostError catch (e) {
      if (!mounted || _client != client) return;
      setState(() {
        _error = srsRemoteReviewErrorText(e);
        _loading = false;
      });
    }
  }

  Future<void> _open(SrsRemoteDeck deck) async {
    final SrsRemoteReviewClient? client = _client;
    final InterconnectHostTarget? target = _target;
    final String? profile = _decks?.profile;
    if (client == null || target == null || profile == null) return;
    await Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => SrsRemoteReviewPage(
          client: client,
          hostId: target.hostId,
          profile: profile,
          deckId: deck.id,
          deckName: deck.name,
        ),
      ),
    );
    // 回来时重读计数（这一轮刷掉的卡）；电脑切了配置也在这里重新拿到。
    if (mounted && _target == target) await _select(target);
  }

  /// 有多台电脑且已选了一台：返回键先回到电脑列表。
  bool get _canGoBackToHosts => _target != null && (_targets?.length ?? 0) > 1;

  @override
  Widget build(BuildContext context) {
    final String title = _target?.displayName ?? t.srs_remote_review_title;
    return PopScope(
      canPop: !_canGoBackToHosts,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop || !_canGoBackToHosts) return;
        _client?.cancelPending();
        setState(() {
          _target = null;
          _client = null;
          _decks = null;
          _error = null;
          _loading = false;
        });
      },
      child: FushiPageScaffold(
        title: title,
        header: isGlassDesign(context) ? null : _buildTopBar(context, title),
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
                    : _target == null
                    ? 'hosts'
                    : 'decks:${_target!.hostId}',
              ),
              child: _buildBody(context),
            ),
          ),
        ),
      ),
    );
  }

  void _refresh() {
    final InterconnectHostTarget? target = _target;
    unawaited(target == null ? _probe() : _select(target));
  }

  Widget _buildTopBar(BuildContext context, String title) {
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
          <FushiToolbarItem>[
            FushiToolbarItem(
              key: const ValueKey<String>('srs_remote_refresh'),
              icon: FushiIcons.refresh,
              label: t.retry,
              onPressed: _refresh,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const SafeArea(bottom: false, child: FushiLoadingView());
    }
    final String? error = _error;
    if (error != null) {
      return Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.error,
          message: error,
          tone: FushiPlaceholderTone.error,
          action: FushiFilledButton.icon(
            onPressed: _refresh,
            icon: const FushiIcon(FushiIcons.refresh),
            label: Text(t.retry),
          ),
        ),
      );
    }
    if (_target == null) return _buildHosts(context);
    return _buildDecks(context);
  }

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

  Widget _buildHosts(BuildContext context) {
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
            onTap: () => unawaited(_select(targets[i])),
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

  Widget _buildDecks(BuildContext context) {
    final List<SrsRemoteDeck> decks = _decks?.decks ?? const <SrsRemoteDeck>[];
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
      _hint(context),
      for (int i = 0; i < decks.length; i++)
        FushiPressScale(
          child: FushiGroupedListItem(
            key: ValueKey<String>('srs_remote_deck_${decks[i].id}'),
            index: i,
            count: decks.length,
            onTap: () => unawaited(_open(decks[i])),
            child: FushiListItem(
              density: srsListDensityOf(context),
              padding: EdgeInsetsDirectional.only(
                start: tokens.spacing.gap * (1 + decks[i].depth),
                end: tokens.spacing.gap,
              ),
              title: Text(
                decks[i].name.split('::').last,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: SrsCountTriple(
                newCount: decks[i].counts.newCount,
                learnCount: decks[i].counts.learnCount,
                reviewCount: decks[i].counts.reviewCount,
                dense: true,
                tight: true,
              ),
            ),
          ),
        ),
    ]);
  }
}

/// 在电脑的复习上刷一个牌组。
class SrsRemoteReviewPage extends ConsumerStatefulWidget {
  const SrsRemoteReviewPage({
    super.key,
    required this.client,
    required this.hostId,
    required this.profile,
    required this.deckId,
    required this.deckName,
    this.mediaRoot,
  });

  final SrsRemoteReviewClient client;
  final String hostId;
  final String profile;
  final String deckId;
  final String deckName;

  /// 媒体缓存目录（测试覆写；默认临时目录下按电脑分）。
  final Directory? mediaRoot;

  @override
  ConsumerState<SrsRemoteReviewPage> createState() =>
      _SrsRemoteReviewPageState();
}

class _SrsRemoteReviewPageState extends ConsumerState<SrsRemoteReviewPage> {
  SrsRemoteMediaStore? _media;

  @override
  void initState() {
    super.initState();
    unawaited(_openMedia());
  }

  Future<void> _openMedia() async {
    final Directory root =
        widget.mediaRoot ??
        SrsRemoteMediaStore.directoryFor(
          await getTemporaryDirectory(),
          widget.hostId,
        );
    if (!mounted) return;
    setState(() => _media = SrsRemoteMediaStore(root, widget.client));
  }

  @override
  Widget build(BuildContext context) {
    final SrsRemoteMediaStore? media = _media;
    if (media == null) {
      return const Material(child: FushiLoadingView());
    }
    // 卡面、原生 Fushi 卡片与音频出口都按 `srsMediaStoreProvider` 读媒体：在这个子作用域里换成缓存目录，
    // 音频出口要在同一作用域里重建，否则它读到的还是根容器的（本机）媒体库。
    return ProviderScope(
      overrides: <Override>[
        srsMediaStoreProvider.overrideWith((Ref ref) => media),
        srsCardAudioOutputProvider.overrideWith(srsDefaultCardAudioOutput),
      ],
      child: _SrsRemoteReviewSession(
        client: widget.client,
        media: media,
        profile: widget.profile,
        deckId: widget.deckId,
        deckName: widget.deckName,
      ),
    );
  }
}

class _SrsRemoteReviewSession extends ConsumerStatefulWidget {
  const _SrsRemoteReviewSession({
    required this.client,
    required this.media,
    required this.profile,
    required this.deckId,
    required this.deckName,
  });

  final SrsRemoteReviewClient client;
  final SrsRemoteMediaStore media;
  final String profile;
  final String deckId;
  final String deckName;

  @override
  ConsumerState<_SrsRemoteReviewSession> createState() =>
      _SrsRemoteReviewSessionState();
}

class _SrsRemoteReviewSessionState
    extends ConsumerState<_SrsRemoteReviewSession> {
  /// 当前卡在前，预取的在后。
  List<SrsRemoteCard> _queue = const <SrsRemoteCard>[];
  SrsRemoteCounts _counts = const SrsRemoteCounts(
    newCount: 0,
    learnCount: 0,
    reviewCount: 0,
  );
  bool _rwkvPending = false;
  bool _loading = true;
  bool _busy = false;
  bool _showingAnswer = false;
  int _reviewed = 0;

  /// 本会话记下的评分（卡, 日志），撤销从尾部取。
  final List<(String, String)> _undo = <(String, String)>[];

  /// 正在交的这次作答的请求 id：失败重试时沿用（host 按它去重），成功 / 换卡后清掉。
  String? _pendingRequest;
  final Stopwatch _clock = Stopwatch();
  late final SrsCardAudioSequencer _audio;
  final FocusNode _focus = FocusNode(debugLabel: 'SrsRemoteReview');

  SrsRemoteCard? get _current => _queue.isEmpty ? null : _queue.first;

  FushiShortcutRegistry get _shortcuts =>
      ref.read(appProvider).shortcutRegistry;

  @override
  void initState() {
    super.initState();
    _audio = SrsCardAudioSequencer(ref.read(srsCardAudioOutputProvider));
    unawaited(_reload());
  }

  @override
  void dispose() {
    srsRunLogged('SrsRemoteReview.stopAudio', _audio.cancel);
    _focus.dispose();
    super.dispose();
  }

  /// 重新排队（首屏 / 卡变了 / 撤销失败后对齐）。
  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final SrsRemoteStudy study = await widget.client.next(
        profile: widget.profile,
        deck: widget.deckId,
      );
      await _apply(study);
    } on InterconnectHostError catch (e) {
      _fail(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 换成 host 排出的队列：先把当前卡的媒体拉进缓存再显示，预取那张的媒体在后台拉。
  Future<void> _apply(SrsRemoteStudy study) async {
    final List<SrsRemoteCard> cards = study.cards;
    if (cards.isNotEmpty) {
      await widget.media.prefetch(cards.first.mediaNames);
      for (final SrsRemoteCard c in cards.skip(1)) {
        unawaited(widget.media.prefetch(c.mediaNames));
      }
    }
    if (!mounted) return;
    setState(() {
      _queue = cards;
      _counts = study.counts;
      _rwkvPending = study.rwkvPending;
      _showingAnswer = false;
      _pendingRequest = null;
    });
    _onCardShown();
  }

  void _onCardShown() {
    _clock
      ..reset()
      ..start();
    _autoplay();
    if (!_focus.hasFocus) _focus.requestFocus();
  }

  void _fail(InterconnectHostError e) {
    if (!mounted) return;
    FushiToast.show(msg: srsRemoteReviewErrorText(e));
    if (e.message == SrsRemoteReviewError.profileChanged) {
      unawaited(Navigator.of(context).maybePop());
    }
  }

  void _showAnswer() {
    if (_current == null || _showingAnswer || _busy) return;
    setState(() => _showingAnswer = true);
    _autoplay();
  }

  Future<void> _rate(int rating) async {
    final SrsRemoteCard? card = _current;
    if (card == null || !_showingAnswer || _busy) return;
    setState(() => _busy = true);
    final String request = _pendingRequest ??= widget.client.requestId();
    try {
      final ({String logId, SrsRemoteStudy study}) out = await widget.client
          .answer(
            profile: widget.profile,
            request: request,
            deck: widget.deckId,
            card: card,
            rating: rating,
            durationMs: _clock.elapsedMilliseconds,
          );
      _undo.add((card.id, out.logId));
      _reviewed++;
      await _apply(out.study);
    } on InterconnectHostError catch (e) {
      _fail(e);
      // 卡在别处被复习过：丢掉它重新排队；连接类失败保留请求 id，再点同一评分不会重复记账。
      if (e.message == SrsRemoteReviewError.stale) {
        _pendingRequest = null;
        await _reload();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _undoLast() async {
    if (_undo.isEmpty || _busy) return;
    setState(() => _busy = true);
    final (String cardId, String logId) = _undo.last;
    try {
      final ({bool ok, SrsRemoteCard? card}) out = await widget.client.undo(
        profile: widget.profile,
        cardId: cardId,
        logId: logId,
      );
      _undo.removeLast();
      final SrsRemoteCard? card = out.card;
      if (!out.ok || card == null) {
        FushiToast.show(msg: t.srs_review_undo_blocked);
        return;
      }
      _reviewed--;
      await widget.media.prefetch(card.mediaNames);
      if (!mounted) return;
      setState(() {
        _queue = <SrsRemoteCard>[
          card,
          ..._queue.where((SrsRemoteCard c) => c.id != card.id),
        ];
        _showingAnswer = false;
        _pendingRequest = null;
      });
      _onCardShown();
    } on InterconnectHostError catch (e) {
      _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------------ 音频

  ({List<String> question, List<String> answer}) _mediaOf(SrsRemoteCard c) {
    if (c.rendered.fushiCardDefinitions != null) {
      final SrsFushiCardMedia media = srsFushiCardMedia(
        c.rendered.fields,
        audioCardFront:
            srsFushiFrontKind(c.rendered.fields) == SrsFushiFrontKind.audio,
      );
      return (question: media.front, answer: media.back);
    }
    return (
      question: srsCardSoundNames(c.rendered.question),
      answer: srsCardSoundNames(c.rendered.answer),
    );
  }

  void _autoplay() {
    final SrsRemoteCard? card = _current;
    if (card == null || !card.autoplay) {
      srsRunLogged('SrsRemoteReview.stopAudio', _audio.cancel);
      return;
    }
    final ({List<String> question, List<String> answer}) m = _mediaOf(card);
    final List<String> names = srsAutoplayOf(
      question: m.question,
      answer: m.answer,
      answerSide: _showingAnswer,
    );
    srsRunLogged('SrsRemoteReview.autoplay', () => _audio.play(names));
  }

  void _replay() {
    final SrsRemoteCard? card = _current;
    if (card == null) return;
    final ({List<String> question, List<String> answer}) m = _mediaOf(card);
    final List<String> names = srsReplayOf(
      question: m.question,
      answer: m.answer,
      answerSide: _showingAnswer,
      includeQuestion: true,
    );
    srsRunLogged('SrsRemoteReview.replay', () => _audio.play(names));
  }

  // ------------------------------------------------------------------ 键盘

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final ShortcutAction? action = _shortcuts.resolveKeyboard(
      event.logicalKey,
      modifiers: <ModifierKey>{
        if (HardwareKeyboard.instance.isControlPressed) ModifierKey.ctrl,
        if (HardwareKeyboard.instance.isShiftPressed) ModifierKey.shift,
        if (HardwareKeyboard.instance.isAltPressed) ModifierKey.alt,
        if (HardwareKeyboard.instance.isMetaPressed) ModifierKey.meta,
      },
      scope: ShortcutScope.srsReview,
      physicalKey: event.physicalKey,
    );
    return action != null && _execute(action)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  /// 卡面 WebView 持焦时经键盘桥回传的按键，走同一个解析。
  void _onBridgeKey(String token) {
    final InputBinding? binding = InputBinding.fromBridgeToken(token);
    if (binding == null) return;
    final ShortcutAction? action = _shortcuts.resolveKeyboard(
      binding.key,
      modifiers: binding.modifiers,
      scope: ShortcutScope.srsReview,
    );
    if (action != null && _execute(action)) return;
    if (_shortcuts.resolveKeyboard(
          binding.key,
          modifiers: binding.modifiers,
          scope: ShortcutScope.universal,
        ) ==
        ShortcutAction.globalBack) {
      unawaited(Navigator.of(context).maybePop());
    }
  }

  bool _execute(ShortcutAction action) {
    bool rate(int r) {
      if (!_showingAnswer) return false;
      unawaited(_rate(r));
      return true;
    }

    switch (action) {
      case ShortcutAction.srsReviewPrimary:
        if (_showingAnswer) {
          unawaited(_rate(3));
        } else {
          _showAnswer();
        }
        return true;
      case ShortcutAction.srsReviewAgain:
        return rate(1);
      case ShortcutAction.srsReviewHard:
        return rate(2);
      case ShortcutAction.srsReviewGood:
        return rate(3);
      case ShortcutAction.srsReviewEasy:
        return rate(4);
      case ShortcutAction.srsReviewReplayAudio:
        _replay();
        return true;
      case ShortcutAction.srsReviewUndo:
        unawaited(_undoLast());
        return true;
      default:
        return false;
    }
  }

  String _withKeyHint(String label, ShortcutAction action) {
    final List<InputBinding> keys = _shortcuts
        .bindingsFor(action)
        .keyboardBindings;
    return keys.isEmpty ? label : '$label (${keys.first.displayLabel})';
  }

  // ------------------------------------------------------------------ 界面

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: FushiPageScaffold(
        title: widget.deckName,
        extendBodyBehindHeader: false,
        header: apple ? null : _buildTopBar(context),
        actions: apple
            ? <Widget>[
                if (_undo.isNotEmpty)
                  FushiIconButton(
                    key: const ValueKey<String>('srs_remote_undo'),
                    icon: FushiIcons.undo,
                    tooltip: t.undo,
                    enabled: !_busy,
                    onTap: () => unawaited(_undoLast()),
                  ),
              ]
            : const <Widget>[],
        body: Builder(builder: _buildBody),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
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
        title: widget.deckName,
        leading: <FushiToolbarItem>[
          if (navigator != null && navigator.canPop())
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
        actions: <List<FushiToolbarItem>>[
          <FushiToolbarItem>[
            if (_undo.isNotEmpty)
              FushiToolbarItem(
                key: const ValueKey<String>('srs_remote_undo'),
                icon: FushiIcons.undo,
                label: _withKeyHint(t.undo, ShortcutAction.srsReviewUndo),
                onPressed: _busy ? null : () => unawaited(_undoLast()),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final SrsRemoteCard? card = _current;
    final Widget content = _loading && card == null
        ? const FushiLoadingView(key: ValueKey<String>('loading'))
        : card == null
        ? _buildFinished(context)
        : KeyedSubtree(
            key: const ValueKey<String>('card'),
            child: _buildCard(context, card),
          );
    return AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.short),
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
      child: content,
    );
  }

  Widget _buildFinished(BuildContext context) => Center(
    key: const ValueKey<String>('finished'),
    child: FushiPlaceholderMessage(
      icon: _rwkvPending ? FushiIcons.history : FushiIcons.check,
      message: _rwkvPending ? t.srs_review_rwkv_pending : t.srs_review_done,
      detail: _reviewed > 0 ? t.srs_review_done_detail(n: _reviewed) : null,
      action: FushiFilledButton.icon(
        onPressed: () => unawaited(Navigator.of(context).maybePop()),
        icon: const FushiIcon(FushiIcons.back),
        label: Text(t.srs_review_back_to_decks),
      ),
    ),
  );

  Widget _buildCard(BuildContext context, SrsRemoteCard card) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String language = ref.read(appProvider).defaultContentLanguage;
    final SrsCardFace face = SrsCardFace(
      cardId: card.id,
      showingAnswer: _showingAnswer,
      bodyHtml: _showingAnswer ? card.rendered.answer : card.rendered.question,
      css: card.rendered.css,
      languageCode: language.isEmpty ? null : language,
      onBridgeKey: _onBridgeKey,
      bridgeKeys: srsReviewBridgeTokens(_shortcuts),
      fushiCard: card.builtinKey == kSrsBuiltinFushiCardKey,
      onPlayAudio: (List<String> names) =>
          srsRunLogged('SrsRemoteReview.play', () => _audio.play(names)),
      autoplayMedia: card.autoplay,
    );
    final String? definitions = card.rendered.fushiCardDefinitions;
    final Widget faceWidget = definitions != null
        ? SrsFushiCardView(
            key: const ValueKey<String>('srs-fushi-card-view'),
            face: face,
            fields: card.rendered.fields,
            definitionsHtml: definitions,
          )
        : ref.watch(srsCardFaceBuilderProvider)(context, face);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(child: faceWidget),
        SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              tokens.spacing.gap,
              tokens.spacing.page,
              tokens.spacing.gap,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: tokens.spacing.gap,
              children: <Widget>[
                Center(
                  child: SrsCountTriple(
                    newCount: _counts.newCount,
                    learnCount: _counts.learnCount,
                    reviewCount: _counts.reviewCount,
                    reviewPending: _rwkvPending,
                    dense: true,
                  ),
                ),
                AnimatedSwitcher(
                  duration: fushiMotionDuration(context, FushiMotion.short),
                  switchInCurve: FushiMotion.enter,
                  switchOutCurve: FushiMotion.exit,
                  child: _showingAnswer
                      ? _buildRatingRow(context, card)
                      : _buildShowAnswer(context),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildShowAnswer(BuildContext context) => FushiPressScale(
    key: const ValueKey<String>('srs-remote-show-answer-row'),
    enabled: !_busy,
    child: FushiTooltip(
      message: _withKeyHint(
        t.srs_review_show_answer,
        ShortcutAction.srsReviewPrimary,
      ),
      child: FushiFilledButton.icon(
        key: const ValueKey<String>('srs-remote-show-answer'),
        onPressed: _busy ? null : _showAnswer,
        size: FushiButtonSize.m,
        icon: const FushiIcon(FushiIcons.visibility),
        label: Text(t.srs_review_show_answer),
      ),
    ),
  );

  Widget _buildRatingRow(BuildContext context, SrsRemoteCard card) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool showIntervals = ref.watch(srsReviewShowIntervalsProvider);
    final bool twoButtons = ref.watch(srsReviewHideHardEasyProvider);
    String interval(int rating) {
      final ({String amount, SrsIntervalUnit unit})? parts = card.intervalOf(
        rating,
      );
      return showIntervals && parts != null ? srsIntervalLabel(parts) : '';
    }

    Widget button(int rating, String label, SrsRatingTone tone) => Expanded(
      child: SrsRatingButton(
        key: ValueKey<String>('srs-remote-rate-$rating'),
        tone: tone,
        interval: interval(rating),
        label: label,
        tooltip: _withKeyHint(label, switch (rating) {
          1 => ShortcutAction.srsReviewAgain,
          2 => ShortcutAction.srsReviewHard,
          3 => ShortcutAction.srsReviewGood,
          _ => ShortcutAction.srsReviewEasy,
        }),
        onPressed: _busy ? null : () => unawaited(_rate(rating)),
      ),
    );

    return Row(
      key: ValueKey<String>(
        twoButtons ? 'srs-remote-rating-two' : 'srs-remote-rating',
      ),
      spacing: tokens.spacing.gap,
      children: <Widget>[
        button(1, t.srs_rating_again, SrsRatingTone.again),
        if (!twoButtons) button(2, t.srs_rating_hard, SrsRatingTone.hard),
        button(3, t.srs_rating_good, SrsRatingTone.good),
        if (!twoButtons) button(4, t.srs_rating_easy, SrsRatingTone.easy),
      ],
    );
  }
}
