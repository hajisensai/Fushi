import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/mining/external_window_mining.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_window_gif.dart';
import 'package:hibiki/src/mining/immersion_mining_engine.dart';
import 'package:hibiki/src/mining/immersion_mining_request.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';
import 'package:hibiki/src/utils/misc/swipe_dismiss_wrapper.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/utils.dart';

/// texthooker 捕获工作台：实时展示 WebSocket 收到的文本行，逐词查词 + 挖词。
///
/// 订阅单例 [TexthookerService]（ChangeNotifier）实时刷新文本行；每行经日语分词
/// 成可点 span，点击后经 [DictionaryPageMixin.pushNestedPopup] 弹查词浮层，挖词
/// 复用 mixin 的 Anki 逻辑。
class TexthookerPage extends ConsumerStatefulWidget {
  const TexthookerPage({
    super.key,
    this.embedded = false,
    this.onShowLibrary,
    this.onShowDiagnostics,
  });

  /// 嵌入 [HomeGamePage] 时不再创建第二层 Scaffold/AppBar。
  final bool embedded;
  final VoidCallback? onShowLibrary;
  final VoidCallback? onShowDiagnostics;

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
  final GalHookSessionController _session = GalHookSessionController.instance;
  String? _activeLineId;
  String? _activeSentence;
  bool _followLive = true;
  int _unreadLines = 0;
  String? _lastObservedLineId;

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
    final List<TexthookerLineEntry> initialLines =
        TexthookerService.instance.entries;
    _lastObservedLineId = initialLines.isEmpty ? null : initialLines.last.id;
    TexthookerService.instance.addListener(_onLines);
    _session.addListener(_onSessionChanged);
    // TODO-1204：接线查词计数（每次查词 +1 → lookup_mining_counters）。
    attachLookupCounter(_popup);
  }

  @override
  void dispose() {
    TexthookerService.instance.removeListener(_onLines);
    _session.removeListener(_onSessionChanged);
    _popup.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// TODO-1162：外部窗口挖矿模式下覆写制卡——先截绑定窗口当前帧作封面，再连同当前句
  /// 走 [ImmersionMiningEngine]（与 Netflix 后台捕获同形状）。未开启 / 未绑定 / 非
  /// Windows 时回落 [DictionaryPageMixin.onMineEntry] 的普通逐词制卡（Never break）。
  @override
  Future<MinePopupResult> onMineEntry(Map<String, String> fields) async {
    final Map<String, String> effectiveFields =
        Map<String, String>.from(fields);
    final String? activeSentence = _activeSentence;
    if ((effectiveFields['sentence'] ?? '').isEmpty &&
        activeSentence != null &&
        activeSentence.isNotEmpty) {
      effectiveFields['sentence'] = activeSentence;
    }
    final GalHookSessionState sessionState = _session.state;
    final ExternalWindowInfo? bound = sessionState.boundWindow;
    if (!sessionState.externalWindowMode ||
        bound == null ||
        !Platform.isWindows) {
      return super.onMineEntry(effectiveFields);
    }
    HibikiToast.showMine(
      msg: t.card_mining_pending,
      status: MineToastStatus.pending,
    );
    // 画面默认出 GIF 短动图（抓角色口型/眨眼）：先试多帧 GIF；不成（帧不足 / 无
    // ffmpeg / 编码失败）回退单帧 PNG。GIF 成时 [coverName]=.gif 让引擎按动图封面处理，
    // 单帧回退不传 coverName（=png）。两者都失败才报错中止（fail-open，不产出空壳卡）。
    final Uint8List? gifBytes = await captureWindowGifBytes(hwnd: bound.hwnd);
    Uint8List? coverBytes = gifBytes;
    String? coverName = gifBytes != null ? 'external_window.gif' : null;
    if (coverBytes == null) {
      final WindowCaptureResult cap =
          await WindowCaptureChannel.captureWindow(bound.hwnd);
      if (!cap.ok) {
        // 单帧也失败：明确报错，不产出空壳卡（fail-open，不静默假成功）。
        HibikiToast.showMine(
          msg: cap.error != null
              ? '${t.external_window_capture_failed}：${cap.error}'
              : t.external_window_capture_failed,
          status: MineToastStatus.failed,
        );
        return const MinePopupResult();
      }
      coverBytes = cap.pngBytes;
    }
    // galgame 一键制卡：若音频源已开，抓最近一段 → 波形选区 → 帧对齐切片 → 编码成 AAC/m4a
    // 容器字节。任一步不成（无源/无数据/用户取消/切空/编码失败）→ audioBytes 保持 null，
    // 退化为纯截图卡（Never break：截图卡本就无声，不因无音频中止）。
    final Uint8List? audioBytes = await _session.captureAudioBytes(
      lineId: _activeLineId ?? '',
      sentence: effectiveFields['sentence'] ?? '',
      outputExtension: immersionMiningAudioExtension(),
    );

    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    final MiningMediaCompression compression =
        MiningMediaCompression.forCompressionEnabled(
            mixinAppModel.compressMiningMedia);
    final ImmersionMiningResult res = await ImmersionMiningEngine().mine(
      buildExternalWindowRequest(
        fields: effectiveFields,
        sentence: effectiveFields['sentence'] ?? '',
        screenshotBytes: coverBytes,
        coverName: coverName,
        audioBytes: audioBytes,
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
      unawaited(recordMinedSentence(effectiveFields, outcome.noteId));
    }
    HibikiToast.showMine(msg: described.message, status: described.status);
    if (described.success) {
      return MinePopupResult(ankiConnect: true, noteId: outcome.noteId);
    }
    return const MinePopupResult();
  }

  Future<void> _toggleExternalWindowMode() async {
    final bool next = !_session.state.externalWindowMode;
    if (next && _session.state.boundWindow == null) {
      await _session.setExternalWindowMode(true);
      await _pickExternalWindow();
      return;
    }
    await _session.setExternalWindowMode(next);
  }

  /// 拉起窗口选择器：选择结果只作为 intent 交给 app 级会话控制器。
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
          for (final ExternalWindowInfo window in windows)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(window),
              child: Text(
                window.title.isEmpty ? '#${window.hwnd}' : window.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
    if (picked != null) await _session.bindWindow(picked);
  }

  Future<void> _launchGalgameEngineHook() async {
    if (!Platform.isWindows) {
      HibikiToast.show(msg: t.external_window_unsupported);
      return;
    }
    final FilePickerResult? picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['exe'],
    );
    final String? executable =
        picked == null || picked.files.isEmpty ? null : picked.files.first.path;
    if (executable == null) return;
    HibikiToast.show(msg: t.game_capture_launching);
    final bool launched = await _session.launchGame(executable);
    if (!mounted) return;
    final GalHookSessionState state = _session.state;
    if (!launched) {
      HibikiToast.show(msg: state.lastError ?? t.game_capture_launch_failed);
      return;
    }
    HibikiToast.show(
      msg: state.boundWindow == null
          ? t.game_capture_running_no_window
          : t.game_capture_running,
    );
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  /// 外部窗口挖矿模式条：展示已绑定窗口标题 + 重选/解绑；未绑定时点击选窗口。
  Widget _buildExternalWindowBar(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final ExternalWindowInfo? bound = _session.state.boundWindow;
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
                  onPressed: () => unawaited(_session.bindWindow(null)),
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
    final List<TexthookerLineEntry> lines = TexthookerService.instance.entries;
    final String? latestId = lines.isEmpty ? null : lines.last.id;
    final bool receivedNewLine =
        latestId != null && latestId != _lastObservedLineId;
    _lastObservedLineId = latestId;
    setState(() {
      if (!_followLive && receivedNewLine) _unreadLines++;
    });
    if (!receivedNewLine) return;
    if (!_followLive) return;
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

  void _onWordTap(
    TexthookerLineEntry line,
    String word,
    Rect rect,
  ) {
    _activeLineId = line.id;
    _activeSentence = line.text;
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
    final List<TexthookerLineEntry> lines = TexthookerService.instance.entries;
    if (widget.embedded) {
      return Column(
        children: <Widget>[
          HibikiPageHeader(
            title: t.game_capture_workbench,
            subtitle: t.game_capture_description,
            leading: widget.onShowLibrary == null
                ? null
                : IconButton(
                    tooltip: t.game_back_to_library,
                    onPressed: widget.onShowLibrary,
                    icon: const Icon(Icons.arrow_back),
                  ),
            actions: _buildEmbeddedActions(context),
            bottom: _buildSectionTabs(),
          ),
          Expanded(child: _buildMonitorBody(context, lines)),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(t.texthooker),
        actions: <Widget>[
          if (Platform.isWindows)
            IconButton(
              tooltip: t.external_window_mining,
              icon: Icon(
                Icons.crop_free,
                color: _session.state.externalWindowMode
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              onPressed: _toggleExternalWindowMode,
            ),
          if (Platform.isWindows)
            IconButton(
              tooltip: t.game_launch_and_capture,
              icon: const Icon(Icons.rocket_launch_outlined),
              onPressed: _launchGalgameEngineHook,
            ),
          IconButton(
            tooltip: t.clear,
            icon: const Icon(Icons.delete_outline),
            onPressed: TexthookerService.instance.clear,
          ),
        ],
      ),
      body: _buildMonitorBody(context, lines),
    );
  }

  List<Widget> _buildEmbeddedActions(BuildContext context) => <Widget>[
        if (widget.onShowDiagnostics != null)
          HibikiIconButton(
            icon: Icons.monitor_heart_outlined,
            tooltip: t.game_open_diagnostics,
            label: t.game_diagnostics,
            onTap: widget.onShowDiagnostics,
          ),
        if (Platform.isWindows)
          HibikiIconButton(
            icon: Icons.crop_free,
            tooltip: t.external_window_mining,
            label: t.external_window_mining,
            enabledColor: _session.state.externalWindowMode
                ? Theme.of(context).colorScheme.primary
                : null,
            onTap: _toggleExternalWindowMode,
          ),
        if (Platform.isWindows)
          HibikiIconButton(
            icon: Icons.rocket_launch_outlined,
            tooltip: t.game_launch_and_capture,
            label: t.game_launch_and_capture,
            onTap: _launchGalgameEngineHook,
          ),
        if (_session.state.isActive)
          HibikiIconButton(
            icon: Icons.stop_circle_outlined,
            tooltip: t.game_stop_listening,
            label: t.game_stop_listening,
            onTap: () => unawaited(_session.stopCapture()),
          ),
        HibikiIconButton(
          icon: Icons.delete_outline,
          tooltip: t.clear,
          onTap: TexthookerService.instance.clear,
        ),
      ];

  Widget? _buildSectionTabs() {
    if (widget.onShowLibrary == null || widget.onShowDiagnostics == null) {
      return null;
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          HibikiSelectableChip(
            label: t.game_library,
            leadingIcon: Icons.sports_esports_outlined,
            selected: false,
            onSelected: (_) => widget.onShowLibrary!(),
          ),
          const SizedBox(width: 8),
          HibikiSelectableChip(
            label: t.game_capture_workbench,
            leadingIcon: Icons.sensors_outlined,
            selected: true,
            onSelected: (_) {},
          ),
          const SizedBox(width: 8),
          HibikiSelectableChip(
            label: t.game_diagnostics,
            leadingIcon: Icons.monitor_heart_outlined,
            selected: false,
            onSelected: (_) => widget.onShowDiagnostics!(),
          ),
        ],
      ),
    );
  }

  Widget _buildMonitorBody(
    BuildContext context,
    List<TexthookerLineEntry> lines,
  ) {
    final GalHookSessionState state = _session.state;
    return Stack(
      children: <Widget>[
        Column(
          children: <Widget>[
            _buildExperimentalBanner(context),
            if (state.externalWindowMode) _buildExternalWindowBar(context),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints box) {
                    final Widget live = _buildLiveLinesPanel(context, lines);
                    final Widget latest = _LatestLineCard(
                      line: _selectedOrLatestLine(lines),
                    );
                    final Widget health = _CaptureHealthCard(
                      state: state,
                      endpoints: _session.endpointStatuses,
                    );
                    if (box.maxWidth >= 1280) {
                      return Column(
                        children: <Widget>[
                          _SessionOverviewCard(state: state),
                          const SizedBox(height: 12),
                          Expanded(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                Expanded(flex: 5, child: live),
                                const SizedBox(width: 12),
                                Expanded(flex: 3, child: latest),
                                const SizedBox(width: 12),
                                Expanded(flex: 3, child: health),
                              ],
                            ),
                          ),
                        ],
                      );
                    }
                    if (box.maxWidth >= 840) {
                      return Column(
                        children: <Widget>[
                          _SessionOverviewCard(state: state),
                          const SizedBox(height: 12),
                          Expanded(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                Expanded(flex: 2, child: live),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: <Widget>[
                                      Expanded(child: latest),
                                      const SizedBox(height: 12),
                                      Expanded(child: health),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _SessionOverviewCard(state: state, compact: true),
                        const SizedBox(height: 12),
                        Expanded(child: live),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
        ..._buildPopups(context),
      ],
    );
  }

  TexthookerLineEntry? _selectedOrLatestLine(
    List<TexthookerLineEntry> lines,
  ) {
    final String? activeId = _activeLineId;
    if (activeId != null) {
      for (final TexthookerLineEntry line in lines) {
        if (line.id == activeId) return line;
      }
    }
    return lines.isEmpty ? null : lines.last;
  }

  Widget _buildLiveLinesPanel(
    BuildContext context,
    List<TexthookerLineEntry> lines,
  ) {
    return HibikiCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
            child: Row(
              children: <Widget>[
                const Icon(Icons.forum_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${t.game_live_lines} · ${lines.length}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (_unreadLines > 0)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.tertiaryContainer,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text('${t.game_unread_lines} $_unreadLines'),
                  ),
                const SizedBox(width: 8),
                Text(t.game_follow_live),
                Switch(
                  value: _followLive,
                  onChanged: (bool value) {
                    setState(() {
                      _followLive = value;
                      if (value) _unreadLines = 0;
                    });
                    if (value) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (_scroll.hasClients) {
                          _scroll.jumpTo(_scroll.position.maxScrollExtent);
                        }
                      });
                    }
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: lines.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            Icons.sensors_off_outlined,
                            size: 42,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            t.game_capture_empty_title,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            t.game_capture_empty_body,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(8),
                    itemCount: lines.length,
                    itemBuilder: (BuildContext context, int i) =>
                        _TexthookerLine(
                      line: lines[i],
                      selected: lines[i].id == _activeLineId,
                      onWordTap: _onWordTap,
                    ),
                  ),
          ),
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

class _SessionOverviewCard extends StatelessWidget {
  const _SessionOverviewCard({required this.state, this.compact = false});

  final GalHookSessionState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final String audio = _audioBackendLabel(state.audioBackend);
    final String? format = state.audioFormat == null
        ? null
        : '${state.audioFormat!.sampleRate} Hz · '
            '${state.audioFormat!.channels} ch · '
            '${state.audioFormat!.bitsPerSample} bit';
    return HibikiCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: <Widget>[
          Icon(
            state.isActive ? Icons.sensors : Icons.sensors_off_outlined,
            color: state.isActive
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  state.isActive
                      ? t.game_session_listening
                      : t.game_session_idle,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  compact
                      ? '${state.phase.name} · $audio'
                      : '${state.phase.name} · $audio'
                          '${format == null ? '' : ' · $format'}',
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (!compact && state.fallbackReason != null)
                  Text(
                    state.fallbackReason!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.tertiary,
                        ),
                  ),
              ],
            ),
          ),
          _StatusPill(
            label: state.isDegraded
                ? t.game_line_audio_fallback
                : (state.isActive
                    ? t.game_status_ready
                    : t.game_status_waiting),
            ready: state.isActive && !state.isDegraded,
          ),
        ],
      ),
    );
  }
}

class _LatestLineCard extends StatelessWidget {
  const _LatestLineCard({required this.line});

  final TexthookerLineEntry? line;

  @override
  Widget build(BuildContext context) {
    final TexthookerLineEntry? value = line;
    return HibikiCard(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.subtitles_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t.game_latest_line,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (value == null)
              Text(t.game_no_active_line)
            else ...<Widget>[
              Text(
                value.text,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      height: 1.6,
                    ),
              ),
              const SizedBox(height: 14),
              _MetadataRow(
                label: t.game_health_text,
                value: value.sourceLabel ?? value.source.name,
              ),
              _MetadataRow(
                label: t.game_health_audio,
                value: value.audioBackend ?? value.audioStatus.name,
              ),
              if (value.audioDurationMs != null)
                _MetadataRow(
                  label: t.game_audio_format,
                  value:
                      '${(value.audioDurationMs! / 1000).toStringAsFixed(2)}s',
                ),
              if (value.fallbackReason != null)
                _MetadataRow(
                  label: t.game_line_audio_fallback,
                  value: value.fallbackReason!,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CaptureHealthCard extends StatelessWidget {
  const _CaptureHealthCard({required this.state, required this.endpoints});

  final GalHookSessionState state;
  final List<TexthookerEndpointStatus> endpoints;

  @override
  Widget build(BuildContext context) {
    final int connected = endpoints
        .where((e) => e.phase == TexthookerEndpointPhase.connected)
        .length;
    return HibikiCard(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.monitor_heart_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t.game_health,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _HealthRow(
              label: t.game_health_process,
              value: state.gamePid == null ? '—' : 'PID ${state.gamePid}',
              ready: state.gamePid != null,
            ),
            _HealthRow(
              label: t.game_health_window,
              value:
                  state.hasWindow ? t.game_window_bound : t.game_window_missing,
              ready: state.hasWindow,
            ),
            _HealthRow(
              label: t.game_health_text,
              value: endpoints.isEmpty
                  ? t.game_status_not_configured
                  : '$connected/${endpoints.length}',
              ready: state.hasText || connected > 0,
            ),
            _HealthRow(
              label: t.game_health_audio,
              value: _audioBackendLabel(state.audioBackend),
              ready: state.hasAudio,
            ),
            _HealthRow(
              label: t.game_health_helper,
              value: state.phase.name,
              ready: state.isActive && state.phase != GalHookSessionPhase.error,
            ),
            _HealthRow(
              label: t.game_health_anki,
              value: t.game_status_not_configured,
              ready: false,
            ),
          ],
        ),
      ),
    );
  }
}

class _HealthRow extends StatelessWidget {
  const _HealthRow({
    required this.label,
    required this.value,
    required this.ready,
  });

  final String label;
  final String value;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Icon(
            ready ? Icons.check_circle_outline : Icons.schedule_outlined,
            size: 17,
            color: ready
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetadataRow extends StatelessWidget {
  const _MetadataRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.ready});

  final String label;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color background =
        ready ? colors.primaryContainer : colors.surfaceContainerHighest;
    final Color foreground =
        ready ? colors.onPrimaryContainer : colors.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: TextStyle(color: foreground)),
    );
  }
}

String _audioBackendLabel(GalHookAudioBackend backend) => switch (backend) {
      GalHookAudioBackend.none => t.game_audio_backend_none,
      GalHookAudioBackend.pairedVoice => t.game_audio_backend_paired,
      GalHookAudioBackend.enginePcm => t.game_audio_backend_engine,
      GalHookAudioBackend.systemLoopback => t.game_audio_backend_loopback,
    };

/// 一行文本：日语分词成可点 span（引擎未初始化时按字符降级，widget 测试不崩）。
class _TexthookerLine extends StatelessWidget {
  const _TexthookerLine({
    required this.line,
    required this.selected,
    required this.onWordTap,
  });

  final TexthookerLineEntry line;
  final bool selected;
  final void Function(
    TexthookerLineEntry line,
    String word,
    Rect rect,
  ) onWordTap;

  @override
  Widget build(BuildContext context) {
    final List<String> words = JapaneseLanguage.instance.textToWords(line.text);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String source = line.sourceLabel ??
        switch (line.source) {
          TexthookerLineSource.engineHook => t.game_text_source_engine,
          TexthookerLineSource.websocket => t.game_text_source_websocket,
          TexthookerLineSource.unknown => t.game_text_source_unknown,
        };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: HibikiCard(
        color:
            selected ? colors.primaryContainer.withValues(alpha: 0.35) : null,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${_formatTime(line.receivedAt)} · $source'
                    '${line.sourceSequence == null ? '' : ' · #${line.sourceSequence}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                  ),
                ),
                const SizedBox(width: 8),
                _LineAudioChip(status: line.audioStatus),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              children: <Widget>[
                for (final String word in words)
                  _WordSpan(
                    word: word,
                    onTap: (String word, Rect rect) =>
                        onWordTap(line, word, rect),
                  ),
              ],
            ),
            if (line.audioBackend != null ||
                line.fallbackReason != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                <String>[
                  if (line.audioBackend != null) line.audioBackend!,
                  if (line.audioDurationMs != null)
                    '${(line.audioDurationMs! / 1000).toStringAsFixed(2)}s',
                  if (line.fallbackReason != null) line.fallbackReason!,
                ].join(' · '),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _formatTime(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
  }
}

class _LineAudioChip extends StatelessWidget {
  const _LineAudioChip({required this.status});

  final TexthookerLineAudioStatus status;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final (String, Color, Color) appearance = switch (status) {
      TexthookerLineAudioStatus.pending => (
          t.game_line_audio_pending,
          colors.secondaryContainer,
          colors.onSecondaryContainer,
        ),
      TexthookerLineAudioStatus.matched => (
          t.game_line_audio_matched,
          colors.primaryContainer,
          colors.onPrimaryContainer,
        ),
      TexthookerLineAudioStatus.encoded => (
          t.game_line_audio_encoded,
          colors.primaryContainer,
          colors.onPrimaryContainer,
        ),
      TexthookerLineAudioStatus.fallback => (
          t.game_line_audio_fallback,
          colors.tertiaryContainer,
          colors.onTertiaryContainer,
        ),
      TexthookerLineAudioStatus.missing => (
          t.game_line_audio_missing,
          colors.errorContainer,
          colors.onErrorContainer,
        ),
      TexthookerLineAudioStatus.unavailable => (
          t.game_line_audio_unavailable,
          colors.surfaceContainerHighest,
          colors.onSurfaceVariant,
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: appearance.$2,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        appearance.$1,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: appearance.$3,
            ),
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
