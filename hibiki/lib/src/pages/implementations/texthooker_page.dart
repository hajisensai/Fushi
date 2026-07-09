import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/mining/external_window_mining.dart';
import 'package:hibiki/src/mining/immersion_mining_engine.dart';
import 'package:hibiki/src/mining/immersion_mining_request.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/utils/misc/swipe_dismiss_wrapper.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/utils.dart';

/// 独立 texthooker tab：实时展示 WebSocket 收到的文本行，逐词查词 + 挖词。
///
/// 订阅单例 [TexthookerService]（ChangeNotifier）实时刷新文本行；每行经日语分词
/// 成可点 span，点击后经 [DictionaryPageMixin.pushNestedPopup] 弹查词浮层，挖词
/// 复用 mixin 的 Anki 逻辑。
class TexthookerPage extends ConsumerStatefulWidget {
  const TexthookerPage({super.key});

  @override
  ConsumerState<TexthookerPage> createState() => _TexthookerPageState();
}

class _TexthookerPageState extends ConsumerState<TexthookerPage>
    with DictionaryPageMixin {
  final DictionaryPopupController _popup = DictionaryPopupController(
    lowMemory: false,
    onLookupStackDepthChanged: recordLookupStackDepth,
  );
  final ScrollController _scroll = ScrollController();

  /// TODO-1162 外部窗口挖矿模式（仅 Windows）：开启后制卡额外截绑定窗口当前帧作封面。
  bool _externalWindowMode = false;

  /// 已绑定的目标外部窗口（null = 未绑定；未绑定时制卡回落普通逐词制卡）。
  ExternalWindowInfo? _boundWindow;

  /// 缓存的 [AppModel] 引用（`appProvider` 为单例，实例不变）。在 [initState] 一次性
  /// 读取：浮层层在 `LayoutBuilder` 回调里访问 `mixinAppModel`，widget 失活后再
  /// `ref.read` 会抛「deactivated widget's ancestor」（与视频页同源），缓存实例规避。
  late final AppModel _appModel = ref.read(appProvider);

  @override
  AppModel get mixinAppModel => _appModel;

  @override
  ThemeData get mixinTheme => Theme.of(context);

  @override
  void initState() {
    super.initState();
    TexthookerService.instance.addListener(_onLines);
    // TODO-1204：接线查词计数（每次查词 +1 → lookup_mining_counters）。
    attachLookupCounter(_popup);
  }

  @override
  void dispose() {
    TexthookerService.instance.removeListener(_onLines);
    _popup.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// TODO-1162：外部窗口挖矿模式下覆写制卡——先截绑定窗口当前帧作封面，再连同当前句
  /// 走 [ImmersionMiningEngine]（与 Netflix 后台捕获同形状）。未开启 / 未绑定 / 非
  /// Windows 时回落 [DictionaryPageMixin.onMineEntry] 的普通逐词制卡（Never break）。
  @override
  Future<MinePopupResult> onMineEntry(Map<String, String> fields) async {
    final ExternalWindowInfo? bound = _boundWindow;
    if (!_externalWindowMode || bound == null || !Platform.isWindows) {
      return super.onMineEntry(fields);
    }
    HibikiToast.showMine(
      msg: t.card_mining_pending,
      status: MineToastStatus.pending,
    );
    final WindowCaptureResult cap =
        await WindowCaptureChannel.captureWindow(bound.hwnd);
    if (!cap.ok) {
      // 截图失败：明确报错，不产出空壳卡（fail-open，不静默假成功）。
      HibikiToast.showMine(
        msg: cap.error != null
            ? '${t.external_window_capture_failed}：${cap.error}'
            : t.external_window_capture_failed,
        status: MineToastStatus.failed,
      );
      return const MinePopupResult();
    }
    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    final MiningMediaCompression compression =
        MiningMediaCompression.forCompressionEnabled(
            mixinAppModel.compressMiningMedia);
    final ImmersionMiningResult res = await ImmersionMiningEngine().mine(
      buildExternalWindowRequest(
        fields: fields,
        sentence: fields['sentence'] ?? '',
        screenshotBytes: cap.pngBytes,
        documentTitle: bound.title.isEmpty ? 'External window' : bound.title,
      ),
      compression: compression,
      tempDir: Directory.systemTemp.path,
      repo: repo,
    );
    if (res.aborted) {
      HibikiToast.showMine(
        msg: res.abortReason != null
            ? '${t.external_window_capture_failed}：${res.abortReason}'
            : t.external_window_capture_failed,
        status: MineToastStatus.failed,
      );
      return const MinePopupResult();
    }
    final MineOutcome outcome = res.outcome! as MineOutcome;
    final String deckName = outcome.result == MineResult.success
        ? (await repo.loadSettings()).selectedDeckName ?? ''
        : '';
    final described = describeMineOutcome(outcome, deckName: deckName);
    if (described.record) {
      unawaited(recordMined());
      unawaited(recordMinedSentence(fields, outcome.noteId));
    }
    HibikiToast.showMine(msg: described.message, status: described.status);
    if (described.success) {
      return MinePopupResult(ankiConnect: true, noteId: outcome.noteId);
    }
    return const MinePopupResult();
  }

  /// 切换外部窗口挖矿模式；首次开启且未绑定窗口时直接拉起窗口选择器。
  void _toggleExternalWindowMode() {
    setState(() => _externalWindowMode = !_externalWindowMode);
    if (_externalWindowMode && _boundWindow == null) {
      _pickExternalWindow();
    }
  }

  /// 拉起窗口选择器：列 native 返回的可捕获顶层窗口，选一个绑定。native 不可用 /
  /// 无窗口 / 非 Windows 时以 toast 明确提示（不静默）。
  Future<void> _pickExternalWindow() async {
    if (!Platform.isWindows) {
      HibikiToast.show(msg: t.external_window_unsupported);
      return;
    }
    final List<ExternalWindowInfo> windows =
        await WindowCaptureChannel.listWindows();
    if (windows.isEmpty) {
      HibikiToast.show(msg: t.external_window_no_windows);
      return;
    }
    if (!context.mounted) return;
    final ExternalWindowInfo? picked = await showDialog<ExternalWindowInfo>(
      context: context,
      builder: (BuildContext ctx) => SimpleDialog(
        title: Text(t.external_window_select),
        children: <Widget>[
          for (final ExternalWindowInfo w in windows)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(w),
              child: Text(
                w.title.isEmpty ? '#${w.hwnd}' : w.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
    if (picked != null && mounted) {
      setState(() => _boundWindow = picked);
    }
  }

  /// 外部窗口挖矿模式条：展示已绑定窗口标题 + 重选/解绑；未绑定时点击选窗口。
  Widget _buildExternalWindowBar(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final ExternalWindowInfo? bound = _boundWindow;
    return Material(
      // 走共享设计 token 的语义 overlay 面（顶层容器面调性），不在页面里直接引原始
      // ColorScheme 面 token（MD3 守卫要求 ordinary chrome 走共享组件）。
      color: HibikiDesignTokens.of(context).surfaces.overlay,
      child: InkWell(
        onTap: _pickExternalWindow,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: <Widget>[
              Icon(Icons.crop_free, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  bound == null
                      ? t.external_window_none
                      : (bound.title.isEmpty ? '#${bound.hwnd}' : bound.title),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              if (bound != null)
                IconButton(
                  tooltip: t.external_window_unbind,
                  icon: const Icon(Icons.link_off, size: 18),
                  onPressed: () => setState(() => _boundWindow = null),
                ),
              IconButton(
                tooltip: t.external_window_refresh,
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: _pickExternalWindow,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _onLines() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  /// TODO-1052：查词浮层 barrier 上「桌面水平拖过阈关一层」的纯状态追踪器（与
  /// reader/audiobook、video、home_dictionary 共用 [BarrierSwipeDismissTracker]）。
  final BarrierSwipeDismissTracker _barrierSwipe = BarrierSwipeDismissTracker();

  /// texthooker 每次点词 `replaceStack: true`，可见栈至多一层（+ 隐藏热槽）；关一层
  /// 即收起当前查词。逐层关索引取最后可见层（无可见层回退 0，与 barrier 只在有可见层
  /// 时才渲染一致）。
  int get _topVisiblePopupIndex {
    final int i = _popup.lastVisibleIndex;
    return i < 0 ? 0 : i;
  }

  void _onBarrierHorizontalDragStart(DragStartDetails details) {
    _barrierSwipe.begin();
  }

  void _onBarrierHorizontalDragUpdate(DragUpdateDetails details) {
    _barrierSwipe.update(details.delta.dx);
  }

  void _onBarrierHorizontalDragEnd(DragEndDetails details) {
    if (_barrierSwipe.end(
      sensitivity: ReaderHibikiSource.instance.dismissSwipeSensitivity,
    )) {
      popNestedPopupAt(_topVisiblePopupIndex, _popup);
    }
  }

  void _onWordTap(String word, Rect rect) {
    pushNestedPopup(
      query: word,
      selectionRect: rect,
      controller: _popup,
      replaceStack: true,
      autoRead: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<String> lines = TexthookerService.instance.lines;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.texthooker),
        actions: <Widget>[
          if (Platform.isWindows)
            IconButton(
              tooltip: t.external_window_mining,
              icon: Icon(
                Icons.crop_free,
                color: _externalWindowMode
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              onPressed: _toggleExternalWindowMode,
            ),
          IconButton(
            tooltip: t.clear,
            icon: const Icon(Icons.delete_outline),
            onPressed: TexthookerService.instance.clear,
          ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          Column(
            children: <Widget>[
              _buildExperimentalBanner(context),
              if (_externalWindowMode) _buildExternalWindowBar(context),
              Expanded(
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: lines.length,
                  itemBuilder: (BuildContext context, int i) =>
                      _TexthookerLine(text: lines[i], onWordTap: _onWordTap),
                ),
              ),
            ],
          ),
          ..._buildPopups(context),
        ],
      ),
    );
  }

  /// texthooker 为实验性功能：页头下方常驻一条提示横幅，复用视频 tab
  /// （[HomeVideoPage]）同款 secondaryContainer 调性与 textTheme，不抢内容焦点。
  Widget _buildExperimentalBanner(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: colors.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.science_outlined,
            size: 18,
            color: colors.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t.texthooker_experimental_banner,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSecondaryContainer,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildPopups(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    return <Widget>[
      // TODO-1052：查词浮层显示（或搜索中）时叠一层全屏 dismiss barrier——点真空白关一层
      // （逐层关，与其它表面同语义），桌面开滑动关闭时水平拖过阈亦关一层。texthooker 原
      // 先无 barrier（点外面关不掉浮层）；本层是附加的关闭手势，不改逐词查词点击本身。
      if (_popup.hasVisiblePopup || _popup.isSearchingUi)
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => popNestedPopupAt(_topVisiblePopupIndex, _popup),
            onHorizontalDragStart:
                ReaderHibikiSource.instance.enableSwipeToClose
                    ? _onBarrierHorizontalDragStart
                    : null,
            onHorizontalDragUpdate:
                ReaderHibikiSource.instance.enableSwipeToClose
                    ? _onBarrierHorizontalDragUpdate
                    : null,
            onHorizontalDragEnd: ReaderHibikiSource.instance.enableSwipeToClose
                ? _onBarrierHorizontalDragEnd
                : null,
            child: const ColoredBox(color: Colors.transparent),
          ),
        ),
      // 搜索期加载占位卡（搜索→就绪才显示，与首页查词同观感）。
      if (_popup.isSearchingUi && _popup.pendingRect != null)
        buildPopupLoadingPlaceholder(
          rect: _popup.pendingRect!,
          screen: screen,
        ),
      for (int i = 0; i < _popup.entries.length; i++)
        buildNestedPopupLayer(
          index: i,
          screen: screen,
          controller: _popup,
          onPush: (String text, Rect rect) => pushNestedPopup(
            query: text,
            selectionRect: rect,
            controller: _popup,
          ),
          onPop: (int index) => popNestedPopupAt(index, _popup),
        ),
    ];
  }
}

/// 一行文本：日语分词成可点 span（引擎未初始化时按字符降级，widget 测试不崩）。
class _TexthookerLine extends StatelessWidget {
  const _TexthookerLine({required this.text, required this.onWordTap});

  final String text;
  final void Function(String word, Rect rect) onWordTap;

  @override
  Widget build(BuildContext context) {
    final List<String> words = JapaneseLanguage.instance.textToWords(text);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        children: <Widget>[
          for (final String w in words) _WordSpan(word: w, onTap: onWordTap),
        ],
      ),
    );
  }
}

/// 单个可点词 span：点击时上报全局选区矩形供浮层定位。
class _WordSpan extends StatelessWidget {
  const _WordSpan({required this.word, required this.onTap});

  final String word;
  final void Function(String word, Rect rect) onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapUp: (TapUpDetails details) {
        final RenderBox box = context.findRenderObject()! as RenderBox;
        final Offset topLeft = box.localToGlobal(Offset.zero);
        onTap(word, topLeft & box.size);
      },
      child: Text(
        word,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.6),
      ),
    );
  }
}
