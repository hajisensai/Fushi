import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_controller.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_manga_panels.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_mosaic.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_sections.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show MiningRequestOverrides;
import 'package:fushi_core/fushi_core.dart' show fushiDebugPrint;
import 'package:fushi_engine/mining/immersion_mining_request.dart'
    show VideoMiningImageMode;

/// 对话框可用宽度（屏宽扣掉两侧留白）达到这个值才排双栏：右栏 340–400 + 左栏至少
/// 能放下一句日文整行，再窄左栏的句子卡会被挤成一字一行。
const double kAdvancedMiningWideMinWidth = 840;

/// 双栏对话框的上限尺寸（交互稿 ① / ②）。
const double kAdvancedMiningWideMaxWidth = 968;
const double kAdvancedMiningWideMaxHeight = 656;

/// 「高级制卡」的呈现形态。
enum AdvancedMiningPresentation {
  /// 居中对话框（宽屏双栏；不够宽时单栏 + 折叠摘要行）。
  dialog,

  /// 手机全高底部面板（交互稿 ③）。
  sheet,
}

/// 「高级制卡」对话框入口（契约见 [AdvancedMiningCapabilities]）。
///
/// 调用方负责在外面包 `runWithLookupPopupHidden`（查词弹窗是原生平台视图，会盖住
/// Flutter 对话框，BUG-797）。对话框关闭（确认或取消）后会调用
/// [AdvancedMiningSections.onClosed]。
///
/// 手机宽度（< [kFushiSheetWideBreakpoint]）走底部面板，其余走对话框——与全应用
/// `adaptiveModalSheet` 的断点一致，同一台设备上弹层形态不会因功能而异。
Future<void> showAdvancedMiningDialog({
  required BuildContext context,
  required AdvancedMiningCapabilities capabilities,
}) async {
  try {
    if (MediaQuery.sizeOf(context).width < kFushiSheetWideBreakpoint) {
      await adaptiveModalSheet<void>(
        context: context,
        useSafeArea: true,
        builder: (_) => AdvancedMiningDialog(
          capabilities: capabilities,
          presentation: AdvancedMiningPresentation.sheet,
        ),
      );
    } else {
      await showAppDialog<void>(
        context: context,
        builder: (_) => AdvancedMiningDialog(capabilities: capabilities),
      );
    }
  } finally {
    await capabilities.sections.onClosed?.call();
  }
}

/// 「高级制卡」对话框本体（纯 UI，所有能力经 [capabilities] 注入）。
///
/// 句子部分从原「调整上下文」对话框（`SentenceContextDialog`）演进而来，保留它修过的
/// 全部行为：确认先落地再关窗、没点到如实提示（BUG-2627）；矮窗整体可滚动不塌
/// （BUG-922）；标题块与关闭键按各自高度居中（BUG-2033）；按钮折行不截字（BUG-3211）；
/// 取消时把上下文还原到打开时的快照；编辑态锁住外层控件；往返在路上时不许关；
/// 试听在关窗 / 确认时停止。
class AdvancedMiningDialog extends StatefulWidget {
  const AdvancedMiningDialog({
    super.key,
    required this.capabilities,
    this.presentation = AdvancedMiningPresentation.dialog,
  });

  final AdvancedMiningCapabilities capabilities;
  final AdvancedMiningPresentation presentation;

  @override
  State<AdvancedMiningDialog> createState() => _AdvancedMiningDialogState();
}

/// 窄屏里折叠成摘要行的分区。
enum _Fold { deck, wordAudio, audio, image }

class _AdvancedMiningDialogState extends State<AdvancedMiningDialog> {
  late final AdvancedMiningController _c = AdvancedMiningController(
    widget.capabilities,
  );

  /// 已经走完确认或取消（窗口由它们关闭）。没走完就被关掉（底部面板下拉、路由被
  /// 外部移除）时，dispose 里补做取消的收尾：停试听、还原句子快照。
  bool _finished = false;

  final Set<_Fold> _expanded = <_Fold>{};

  @override
  void initState() {
    super.initState();
    unawaited(_c.load());
  }

  @override
  void dispose() {
    if (!_finished) {
      unawaited(_c.stopPreview());
      unawaited(_c.stopWordAudioPreview());
      unawaited(_c.restoreSentenceSnapshot());
    }
    _c.dispose();
    super.dispose();
  }

  bool get _sheet => widget.presentation == AdvancedMiningPresentation.sheet;

  // ───────────────────────────── 动作 ─────────────────────────────

  Future<void> _cancel() async {
    if (_c.busy) return;
    if (_c.editing) {
      _c.cancelEdit();
      return;
    }
    _finished = true;
    _c.busy = true;
    // 关窗前先停试听：对话框没了但音频还在放，用户没有任何入口能停下来。
    await _c.stopPreview();
    await _c.stopWordAudioPreview();
    // 还原到打开时的上下文：取消不把半调整的草稿留给后续一键「+」。
    await _c.restoreSentenceSnapshot();
    if (!mounted) return;
    _c.busy = false;
    Navigator.of(context).pop();
  }

  /// 「制卡到 …」：**先把制卡点下去、确认它落地了，再关窗**。
  ///
  /// BUG-2627：制卡是「Dart → 查词弹窗 WebView 的 DOM → 回点那颗制卡按钮」的往返，
  /// 而那层弹窗**只在本对话框开着的时候才被保护住**（`runWithLookupPopupHidden`）。
  /// 先 `pop()` 再回点，往返途中任何一条关栈路径都会让回点静默落空：对话框关了、
  /// 卡没制出来、连一句提示都没有。所以在保护窗口**内**完成往返，期间进 busy
  /// （禁用一切外层控件，PopScope 也不放行），落地与否都有确定结局。
  ///
  /// BUG-2634：往返的终点是**宿主接受了制卡任务**，不是 ffmpeg / Anki 落地——等落地
  /// 会把对话框锁死几十秒。
  Future<void> _confirm() async {
    if (_c.locked) return;
    // 制卡走了，试听不该继续响。不 await——制卡不等它。
    unawaited(_c.stopPreview());
    unawaited(_c.stopWordAudioPreview());
    _c.busy = true;
    bool mined = false;
    try {
      final MiningRequestOverrides overrides = _c.buildOverrides();
      // 选了非默认音源时会重新解析一次（互联源 URL 带短时令牌），所以在 busy 里等。
      final String? wordAudioUrl = await _c.resolveWordAudioUrl();
      await _applyDefaultDeck();
      mined = await widget.capabilities.onConfirm(
        overrides,
        wordAudioUrl: wordAudioUrl,
      );
    } catch (e, stack) {
      // 宿主抛错与「没点到」对用户是同一件事：卡没制出来。照常关窗 + 提示。
      fushiDebugPrint('AdvancedMiningDialog.confirm: $e\n$stack');
      mined = false;
    }
    if (!mounted) return;
    _finished = true;
    _c.busy = false;
    Navigator.of(context).pop();
    if (!mined) {
      FushiToast.show(
        msg: t.popup_ctx_confirm_failed,
        severity: ToastSeverity.warning,
      );
    }
  }

  /// 勾了「同时设为默认卡组」：先持久化再制卡。失败不挡制卡——这张卡的卡组已经由
  /// 覆盖项带过去了，默认值没改成只影响以后的一键「+」。
  Future<void> _applyDefaultDeck() async {
    final AdvancedMiningDeckSection? deck = _c.deckSection;
    final Future<void> Function(String)? setDefault = deck?.setDefaultDeck;
    final String? name = _c.deckName;
    if (deck == null ||
        setDefault == null ||
        !_c.setDeckAsDefault ||
        name == null ||
        name == deck.defaultDeckName) {
      return;
    }
    try {
      await setDefault(name);
    } catch (e, stack) {
      fushiDebugPrint('AdvancedMiningDialog.setDefaultDeck: $e\n$stack');
    }
  }

  Future<void> _togglePreview() async {
    final bool ok = await _c.togglePreview();
    if (!ok && mounted) {
      // 没有可试听的音频：如实说一声，不留一个「像在放但没声音」的按钮。
      FushiToast.show(
        msg: t.popup_ctx_preview_unavailable,
        severity: ToastSeverity.info,
      );
    }
  }

  Future<void> _previewWordAudio(int index) async {
    final bool ok = await _c.previewWordAudio(index);
    if (!ok && mounted) {
      FushiToast.show(
        msg: t.popup_advanced_mining_word_audio_preview_failed,
        severity: ToastSeverity.info,
      );
    }
  }

  void _toggleFold(_Fold fold) {
    setState(() {
      if (!_expanded.remove(fold)) _expanded.add(fold);
    });
  }

  /// `[` / `]` 增减前文，Shift+`[` / `]` 增减后文（`[` = 增、`]` = 减，与提示文案
  /// 「[ ] 增减」同序）。编辑态下不拦截：输入框里要能打出方括号。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_c.sentenceSection == null || _c.locked) return KeyEventResult.ignored;
    final HardwareKeyboard kb = HardwareKeyboard.instance;
    if (kb.isControlPressed || kb.isAltPressed || kb.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    // 认物理键：Shift+[ 在美式布局下的逻辑键是 `{`，各平台报法不一。
    final bool left =
        event.physicalKey == PhysicalKeyboardKey.bracketLeft ||
        event.logicalKey == LogicalKeyboardKey.bracketLeft ||
        event.logicalKey == LogicalKeyboardKey.braceLeft;
    final bool right =
        event.physicalKey == PhysicalKeyboardKey.bracketRight ||
        event.logicalKey == LogicalKeyboardKey.bracketRight ||
        event.logicalKey == LogicalKeyboardKey.braceRight;
    if (!left && !right) return KeyEventResult.ignored;
    unawaited(_c.adjustContext(prevDir: !kb.isShiftPressed, plus: left));
    return KeyEventResult.handled;
  }

  // ───────────────────────────── 构建 ─────────────────────────────

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _c,
    builder: (BuildContext context, Widget? _) => PopScope(
      // Esc / 返回 / 点遮罩都走「取消」：还原句子快照、停试听；往返在路上（busy）
      // 时一概不放行——一 pop 保护就撤、回点结果也没人接（BUG-2627）；编辑态下先
      // 退出编辑，而不是连对话框一起关掉、丢掉改到一半的句子。
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) unawaited(_cancel());
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: _buildFrame(context),
      ),
    ),
  );

  Widget _buildFrame(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    if (_sheet) return _narrowBody(context);
    final bool hasLeft = _c.sentenceSection != null || _c.mangaSection != null;
    final bool hasRight =
        _c.deckSection != null ||
        _c.wordAudioSection != null ||
        _c.audioSection != null ||
        _c.videoSection != null ||
        _c.stillSection != null ||
        _c.mangaSection != null;
    final bool wide =
        screen.width - 80 >= kAdvancedMiningWideMinWidth && hasLeft && hasRight;
    if (!wide) {
      return FushiDialogFrame(
        maxWidth: 560,
        maxHeightFactor: 0.92,
        scrollable: false,
        child: _narrowBody(context),
      );
    }
    return FushiDialogFrame(
      maxWidth: kAdvancedMiningWideMaxWidth,
      maxHeightFactor: 0.94,
      scrollable: false,
      child: SizedBox(
        height: math.min(
          kAdvancedMiningWideMaxHeight,
          screen.height * 0.94 - 48,
        ),
        child: _wideBody(context),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final String term =
        widget.capabilities.expression ?? widget.capabilities.matched;
    // BUG-2033：控件（关闭键）与标题块按各自实际高度垂直居中，不顶对齐。
    return Padding(
      padding: EdgeInsets.fromLTRB(24, _sheet ? 0 : 20, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  t.popup_advanced_mining_eyebrow(term: term),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.fushiType.labelMedium.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  t.popup_advanced_mining_title,
                  style: context.fushiType.headlineSmallEmphasized,
                ),
              ],
            ),
          ),
          FushiIconButtonControl(
            tooltip: t.popup_ctx_cancel,
            onPressed: _c.locked ? null : () => unawaited(_cancel()),
            icon: const FushiIcon(FushiIcons.close, size: 22),
          ),
        ],
      ),
    );
  }

  String get _confirmLabel {
    final String? deck = _c.targetDeckName;
    return deck == null
        ? t.popup_ctx_confirm
        : t.popup_advanced_mining_confirm_to_deck(deck: deck);
  }

  /// 主按钮。BUG-3211：放开最大高度，长卡组名在按钮里折行、按钮跟着长高，绝不截字。
  Widget _confirmButton({bool large = false}) => FushiFilledButton(
    autofocus: true,
    onPressed: _c.locked ? null : () => unawaited(_confirm()),
    style: ButtonStyle(
      maximumSize: const WidgetStatePropertyAll<Size>(Size.infinite),
      minimumSize: WidgetStatePropertyAll<Size>(Size(0, large ? 52 : 44)),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      ),
    ),
    child: Text(_confirmLabel, textAlign: TextAlign.center),
  );

  Widget _cancelButton({bool large = false}) => FushiOutlinedButton(
    onPressed: _c.locked ? null : () => unawaited(_cancel()),
    style: ButtonStyle(
      maximumSize: const WidgetStatePropertyAll<Size>(Size.infinite),
      minimumSize: WidgetStatePropertyAll<Size>(Size(0, large ? 52 : 44)),
    ),
    child: Text(t.popup_ctx_cancel, textAlign: TextAlign.center),
  );

  Widget _resetButton() => FushiTextButton(
    onPressed: _c.locked ? null : () => unawaited(_c.resetToDefaults()),
    style: const ButtonStyle(
      maximumSize: WidgetStatePropertyAll<Size>(Size.infinite),
    ),
    child: Text(t.popup_advanced_mining_reset),
  );

  /// 宽屏双栏（交互稿 ① / ②）：左栏句子或裁切工作区，右栏卡组 / 音频 / 图片 / 预览。
  Widget _wideBody(BuildContext context) {
    final bool manga = _c.mangaSection != null;
    final Widget left = manga
        ? AdvancedMiningSectionShell(
            title: t.popup_advanced_mining_image_section,
            expandChild: true,
            child: MangaCropWorkspace(
              header: MangaCropChoiceChips(controller: _c),
              controller: _c,
              onSubmit: () => unawaited(_confirm()),
            ),
          )
        : SingleChildScrollView(
            child: AdvancedMiningSentencePanel(
              controller: _c,
              matched: widget.capabilities.matched,
              showShortcutHint: true,
            ),
          );
    final List<Widget> right = <Widget>[
      if (_c.deckSection != null) AdvancedMiningDeckPanel(controller: _c),
      if (_c.wordAudioSection != null)
        AdvancedMiningWordAudioPanel(
          controller: _c,
          onPreview: (int i) => unawaited(_previewWordAudio(i)),
        ),
      if (manga && _c.sentenceSection != null)
        AdvancedMiningSentencePanel(
          controller: _c,
          matched: widget.capabilities.matched,
        ),
      if (_c.audioSection != null)
        AdvancedMiningAudioPanel(
          controller: _c,
          onTogglePreview: () => unawaited(_togglePreview()),
        ),
      if (_c.videoSection != null)
        AdvancedMiningVideoImagePanel(controller: _c),
      if (_c.stillSection != null)
        AdvancedMiningStillImagePanel(controller: _c),
      if (manga) MangaCropPreviewPanel(controller: _c),
    ];
    return FushiEntranceScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _header(context),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
                    child: FushiStaggeredEntrance(index: 0, child: left),
                  ),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: manga ? 340 : 400,
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          for (int i = 0; i < right.length; i++) ...<Widget>[
                            if (i > 0) const SizedBox(height: 12),
                            FushiStaggeredEntrance(
                              index: i + 1,
                              child: right[i],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 20, 20),
            child: Row(
              children: <Widget>[
                Flexible(child: _resetButton()),
                const Spacer(),
                _cancelButton(),
                const SizedBox(width: 8),
                Flexible(flex: 2, child: _confirmButton()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 窄屏（手机底部面板 / 窄对话框，交互稿 ③）：句子区常驻展开，卡组 / 音频 / 图片
  /// 折叠成摘要行、点开就地展开；主按钮通栏在底部。
  ///
  /// BUG-922：中间整块是**一个**滚动区（句子卡、摘要行、恢复默认都在里面），头尾
  /// 固定。矮窗里只是滚动变长，句子卡始终保有真实高度，不会被固定区挤塌成 0。
  Widget _narrowBody(BuildContext context) {
    // 有句子区时它常驻展开，其余分区折叠成摘要行，句子才不会被挤到屏外；没有句子
    // 区（纯查词页只有卡组、或只有音频）时没什么可让位的，分区直接整块展开——把
    // 唯一的分区折起来只会多一次点击。漫画框选始终走全屏页。
    final bool fold = _c.sentenceSection != null;
    final List<Widget> rows = _foldRows(context, foldInline: fold);
    final List<Widget> sections = <Widget>[
      if (_c.sentenceSection != null)
        AdvancedMiningSentencePanel(
          controller: _c,
          matched: widget.capabilities.matched,
        ),
      if (!fold) ...<Widget>[
        if (_c.deckSection != null) AdvancedMiningDeckPanel(controller: _c),
        if (_c.wordAudioSection != null)
          AdvancedMiningWordAudioPanel(
            controller: _c,
            onPreview: (int i) => unawaited(_previewWordAudio(i)),
          ),
        if (_c.audioSection != null)
          AdvancedMiningAudioPanel(
            controller: _c,
            onTogglePreview: () => unawaited(_togglePreview()),
          ),
        if (_c.videoSection != null)
          AdvancedMiningVideoImagePanel(controller: _c),
        if (_c.stillSection != null)
          AdvancedMiningStillImagePanel(controller: _c),
      ],
      if (rows.isNotEmpty)
        ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(20)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final (int i, Widget row) in rows.indexed) ...<Widget>[
                if (i > 0) const SizedBox(height: 2),
                row,
              ],
            ],
          ),
        ),
      Center(child: _resetButton()),
    ];
    return FushiEntranceScope(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _header(context),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (int i = 0; i < sections.length; i++) ...<Widget>[
                    if (i > 0) const SizedBox(height: 12),
                    FushiStaggeredEntrance(index: i, child: sections[i]),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: Row(
              children: <Widget>[
                _cancelButton(large: true),
                const SizedBox(width: 10),
                Expanded(child: _confirmButton(large: true)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 摘要行。[foldInline] 为 false 时卡组 / 音频 / 视频图片已整块展开，只剩漫画
  /// 那一行（它点开的是全屏框选页）。
  List<Widget> _foldRows(
    BuildContext context, {
    required bool foldInline,
  }) => <Widget>[
    if (foldInline && _c.deckSection != null)
      _FoldRow(
        label: t.popup_advanced_mining_deck_section,
        value: _c.deckName ?? '—',
        expanded: _expanded.contains(_Fold.deck),
        onTap: () => _toggleFold(_Fold.deck),
        child: AdvancedMiningDeckPanel(controller: _c, embedded: true),
      ),
    if (foldInline && _c.wordAudioSection != null)
      _FoldRow(
        label: t.popup_advanced_mining_word_audio_section,
        value: advancedMiningWordAudioSummary(_c),
        expanded: _expanded.contains(_Fold.wordAudio),
        onTap: () => _toggleFold(_Fold.wordAudio),
        child: AdvancedMiningWordAudioPanel(
          controller: _c,
          embedded: true,
          onPreview: (int i) => unawaited(_previewWordAudio(i)),
        ),
      ),
    if (foldInline && _c.audioSection != null)
      _FoldRow(
        label: t.popup_advanced_mining_audio_section,
        value: _audioSummary(),
        expanded: _expanded.contains(_Fold.audio),
        onTap: () => _toggleFold(_Fold.audio),
        trailing: _c.audioWindow != null && !_c.omitAudio
            ? AdvancedMiningPreviewButton(
                previewing: _c.previewing,
                size: 36,
                onPressed: _c.locked ? null : () => unawaited(_togglePreview()),
              )
            : null,
        child: AdvancedMiningAudioPanel(
          controller: _c,
          embedded: true,
          onTogglePreview: () => unawaited(_togglePreview()),
        ),
      ),
    if (foldInline && _c.videoSection != null)
      _FoldRow(
        label: t.popup_advanced_mining_image_section,
        value: _videoSummary(),
        expanded: _expanded.contains(_Fold.image),
        onTap: () => _toggleFold(_Fold.image),
        child: AdvancedMiningVideoImagePanel(controller: _c, embedded: true),
      ),
    if (foldInline && _c.stillSection != null)
      _FoldRow(
        label: t.popup_advanced_mining_image_section,
        value: advancedMiningStillSummary(_c),
        expanded: _expanded.contains(_Fold.image),
        onTap: () => _toggleFold(_Fold.image),
        child: AdvancedMiningStillImagePanel(controller: _c, embedded: true),
      ),
    // 漫画的框选需要整屏：摘要行点开进入全屏框选页，而不是在面板里挤一张小图。
    if (_c.mangaSection != null)
      _FoldRow(
        label: t.popup_advanced_mining_image_section,
        value: _c.mangaLoading ? '…' : mangaCropSummary(_c),
        expanded: false,
        opensPage: true,
        onTap: _c.locked || _c.mangaLoading
            ? null
            : () => unawaited(MangaCropFullscreenPage.open(context, _c)),
      ),
  ];

  String _audioSummary() {
    if (_c.omitAudio) return t.popup_advanced_mining_audio_none;
    if (!_c.audioLoaded) return '…';
    final AdvancedMiningAudioWindow? w = _c.audioWindow;
    if (w == null) return t.popup_advanced_mining_audio_unavailable;
    return '${t.popup_advanced_mining_audio_follow} · '
        '${formatAdvancedMiningDuration(w.durationMs)}';
  }

  String _videoSummary() {
    final VideoMiningImageMode? mode = _c.videoImageMode;
    if (mode == null) return t.popup_advanced_mining_image_none;
    final String label = videoImageModeLabel(mode);
    if (mode.isStill) {
      final int? at = _c.stillFrameMs;
      return at == null ? label : '$label · ${formatAdvancedMiningTime(at)}';
    }
    final AdvancedMiningAudioWindow? w = _c.audioWindow;
    if (w == null) return label;
    return '$label · ${formatAdvancedMiningTime(w.startMs)} – '
        '${formatAdvancedMiningTime(w.endMs)}';
  }
}

/// 窄屏的一行摘要（「卡组　日语::挖矿　›」）；点开就地展开该分区的完整内容，
/// 展开 / 收起带尺寸补间与箭头旋转。[opensPage] 时箭头不旋转（点开的是另一页）。
class _FoldRow extends StatelessWidget {
  const _FoldRow({
    required this.label,
    required this.value,
    required this.expanded,
    required this.onTap,
    this.trailing,
    this.child,
    this.opensPage = false,
  });

  final String label;
  final String value;
  final bool expanded;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Widget? child;
  final bool opensPage;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 摘要行与分区卡同一面（设计令牌的分组面，FushiCard 默认底）。
    final Color surface = FushiDesignTokens.of(context).surfaces.group;
    final Widget row = FushiPressScale(
      enabled: onTap != null,
      child: Material(
        color: surface,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 72,
                    child: Text(
                      label,
                      style: context.fushiType.titleSmallEmphasized,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      value,
                      style: context.fushiType.bodyMedium.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (trailing != null) ...<Widget>[
                    const SizedBox(width: 8),
                    trailing!,
                  ],
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: expanded ? 0.25 : 0,
                    duration: fushiMotionDuration(context, FushiMotion.short),
                    curve: FushiMotion.standard,
                    child: FushiIcon(
                      FushiIcons.chevronRight,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return Semantics(
      expanded: opensPage ? null : expanded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          row,
          if (child != null)
            FushiAnimatedSize(
              duration: context.fushiMotion.spatialDefault.duration,
              curve: context.fushiMotion.spatialDefault.curve,
              alignment: Alignment.topCenter,
              child: expanded
                  ? ColoredBox(color: surface, child: child)
                  : const SizedBox(width: double.infinity),
            ),
        ],
      ),
    );
  }
}
