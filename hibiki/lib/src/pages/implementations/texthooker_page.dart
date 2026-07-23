import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:hibiki/src/mining/gal_hook_mining_coordinator.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/galgame_helper_installer.dart';
import 'package:hibiki/src/mining/galgame_hook_code_profile.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:hibiki/src/pages/implementations/game_shared.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';
import 'package:hibiki/src/utils/misc/swipe_dismiss_wrapper.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/utils.dart';

/// fallback 制卡（非外部窗口/非 Windows，走普通 in-app popup 制卡）也要带上当前活跃
/// hook 台词作 sentence，否则挖出的卡 `{sentence}` 恒空（BUG-954）。仅在 [fields] 未自带
/// 非空 sentence 且存在 [activeSentence] 时注入，不覆盖调用方已提供的句子。
@visibleForTesting
Map<String, String> injectActiveSentence(
  Map<String, String> fields,
  String? activeSentence,
) {
  if (activeSentence == null || activeSentence.isEmpty) {
    return fields;
  }
  if ((fields['sentence'] ?? '').isNotEmpty) {
    return fields;
  }
  return Map<String, String>.from(fields)..['sentence'] = activeSentence;
}

/// 捕获工作台工具栏「更多」菜单动作：驱动 [PopupMenuButton.onSelected] 的单一枚举，
/// 消除嵌入/独立两套按钮定义的特殊分支。
enum _GalHookToolbarMenuAction { audioFallback, showOverlay, externalWindow }

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
  OverlayEntry? _popupOverlayEntry;
  bool _overlayInert = false;
  String? _activeLineId;
  String? _activeSentence;
  bool _followLive = true;
  int _unreadLines = 0;
  String? _lastObservedLineId;

  /// galgame 引擎-hook 启动的**再入守卫**：一次启动含选文件、位数探测、helper 确认/下载对话框、
  /// 注入会话等多个 await，可持续数秒。没有守卫时重复点击会叠出多个下载确认对话框。
  bool _launchingGalHook = false;

  /// 实时台词列表的筛选维度（全部 / 有音频 / 已制卡 / 已收藏）。与线程下拉正交叠加。
  TexthookerLineFilter _lineFilter = TexthookerLineFilter.all;

  /// 分词结果缓存：行文本按 id 不可变，缓存 textToWords 避免每次 rebuild 重复分词
  /// （每来一行整页 setState）。行对象随音频/制卡/收藏态 copyWith 换新但 id/text 不变，
  /// 按 id 缓存恒安全。上限略高于行 buffer 上限，越界淘汰最旧插入项。
  final _TexthookerWordCache _wordCache = _TexthookerWordCache();

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
    // BUG-1028：开页 seed 常驻隐藏热槽，使查词弹窗 WebView 冷加载一次后全程复用，
    // 消除本页此前「每次点词 replaceStack 冷建 WebView」的高延迟（对齐 home_dictionary_page）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _seedWarmPopup();
      // 跟随实时开着且进页前已有台词时，首帧后定位到最新一行——列表视口高度
      // 有限（筛选 chips/线程下拉占位后更矮），不定位则最新台词可能在视口外。
      if (mounted && _followLive && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  /// BUG-1028：开页 seed 常驻隐藏热槽（低内存模式 [DictionaryPopupController.seedWarmSlot]
  /// 据 lowMemory 早退不保留）。仅在 AppModel 已初始化（能安全读 lowMemoryMode）时执行，
  /// 与 home_dictionary_page 的 `_seedWarmPopup` 同范式。
  void _seedWarmPopup() {
    if (!mounted || !_appModel.isInitialised) return;
    _popup.lowMemory = _appModel.lowMemoryMode;
    setState(() => _popup.seedWarmSlot());
  }

  @override
  void dispose() {
    TexthookerService.instance.removeListener(_onLines);
    _session.removeListener(_onSessionChanged);
    final OverlayEntry? popupOverlay = _popupOverlayEntry;
    if (popupOverlay != null) {
      if (popupOverlay.mounted) popupOverlay.remove();
      popupOverlay.dispose();
      _popupOverlayEntry = null;
    }
    _popup.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void deactivate() {
    _overlayInert = true;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _overlayInert = false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // BUG-953：games 是保活 tab，切走时用 Offstage 隐藏（**不触发 deactivate**），但 home_page
    // 同步把 TickerMode 关掉。用 TickerMode 作可见性信号：tab 不可见时把插在 root Overlay 的
    // 查词浮层置 inert 并重建（收起为 SizedBox），防止弹窗/barrier 跨 tab 残留遮挡新 tab；
    // 重新可见时恢复，保留用户查词浮层状态。仅 Offstage 隐藏这一路 deactivate 覆盖不到。
    final bool nextInert = !TickerMode.of(context);
    if (nextInert != _overlayInert) {
      _overlayInert = nextInert;
      _popupOverlayEntry?.markNeedsBuild();
    }
  }

  /// 测试可见：查词浮层当前是否被置为 inert（隐藏 tab / 失活时收起）。BUG-953 守卫用。
  @visibleForTesting
  bool get debugOverlayInert => _overlayInert;

  @override
  Future<MinePopupResult> onMineEntry(Map<String, String> fields) async {
    final GalHookSessionState sessionState = _session.state;
    if (!sessionState.externalWindowMode ||
        sessionState.boundWindow == null ||
        !Platform.isWindows) {
      // fallback 制卡不走 [GalHookMiningCoordinator]（那条路径由协调器回写 mined）——
      // 这里在 super 成功（ankiConnect）后自己把当前活跃行标记为已制卡。
      final MinePopupResult result = await super.onMineEntry(
        injectActiveSentence(fields, _activeSentence),
      );
      final String? lineId = _activeLineId;
      if (result.ankiConnect && lineId != null) {
        TexthookerService.instance.markLineMined(lineId);
      }
      return result;
    }
    return _mineActiveLine(fields: fields);
  }

  @override
  Future<MinePopupResult> onUpdateEntry(
    int noteId,
    Map<String, String> fields,
  ) async {
    final GalHookSessionState sessionState = _session.state;
    if (!sessionState.externalWindowMode ||
        sessionState.boundWindow == null ||
        !Platform.isWindows) {
      return super
          .onUpdateEntry(noteId, injectActiveSentence(fields, _activeSentence));
    }
    return _mineActiveLine(fields: fields, updateNoteId: noteId);
  }

  Future<MinePopupResult> _mineActiveLine({
    required Map<String, String> fields,
    int? updateNoteId,
  }) async {
    final String? lineId = _activeLineId;
    final TexthookerLineEntry? entry =
        lineId == null ? null : _session.entryById(lineId);
    if (entry == null) {
      HibikiToast.showMine(
        msg: t.game_hook_line_unavailable,
        status: MineToastStatus.failed,
      );
      return const MinePopupResult();
    }
    final Map<String, String> effectiveFields = Map<String, String>.from(fields)
      ..['sentence'] = entry.text;
    HibikiToast.showMine(
      msg: t.card_mining_pending,
      status: MineToastStatus.pending,
    );
    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    final GalHookMiningResult result =
        await GalHookMiningCoordinator.instance.mineLine(
      lineId: entry.id,
      fields: effectiveFields,
      compression: MiningMediaCompression.resolve(
        imageTier: mixinAppModel.miningImageQuality,
        audioTier: mixinAppModel.miningAudioQuality,
      ),
      repo: repo,
      updateNoteId: updateNoteId,
    );
    if (result.aborted) {
      HibikiToast.showMine(
        msg: result.audioFallbackDisabled
            ? t.game_audio_fallback_disabled_missing
            : result.failureReason != null
                ? '${t.external_window_capture_failed}：${result.failureReason}'
                : t.external_window_capture_failed,
        status: MineToastStatus.failed,
      );
      return const MinePopupResult();
    }
    final MineOutcome outcome = result.outcome!;
    final String deckName = outcome.result == MineResult.success
        ? (await repo.loadSettings()).selectedDeckName ?? ''
        : '';
    final described = describeMineOutcome(
      outcome,
      deckName: deckName,
      overwrite: updateNoteId != null,
    );
    if (updateNoteId == null && described.record) {
      unawaited(recordMined());
      unawaited(recordMinedSentence(effectiveFields, outcome.noteId));
    }
    HibikiToast.showMine(msg: described.message, status: described.status);
    if (result.sentenceAudioMissing) {
      HibikiToast.show(msg: t.game_card_sentence_audio_missing);
    }
    if (result.unmappedTokens.isNotEmpty) {
      // 冒号统一全角（与上方 external_window_capture_failed toast 一致）。
      HibikiToast.show(
        msg: '${t.game_card_mapping_missing}：'
            '${result.unmappedTokens.join(', ')}',
      );
    }
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

  /// galgame 引擎-hook（launch 模式）：页面只发起会话；位数解析、注入器选择、窗口绑定、
  /// 音频源回退都在 [GalHookSessionController]。KiriKiriZ 仍走早注入；SiglusEngine 由
  /// injector 自动改为 Enigma-safe 延迟附着，并通过 raw-only Ogg 路径提供制卡音频。
  Future<void> _launchGalgameEngineHook() async {
    if (_launchingGalHook) return; // 再入守卫：启动进行中，忽略重复点击（避免多开确认对话框）。
    _launchingGalHook = true;
    try {
      if (!Platform.isWindows) {
        HibikiToast.show(msg: t.external_window_unsupported);
        return;
      }
      final FilePickerResult? picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['exe'],
      );
      final String? executable = picked == null || picked.files.isEmpty
          ? null
          : picked.files.first.path;
      if (executable == null) return;
      final bool is32Bit =
          await EngineHookGalAudioSource.exeIs32Bit(executable) ?? false;
      if (GalHookSessionController.defaultInjectorResolver(is32Bit: is32Bit) ==
          null) {
        if (!context.mounted) return;
        final bool installed = await GalgameHelperInstaller().ensureInjector(
          is32Bit: is32Bit,
          context: context,
        );
        if (!installed || !mounted) return;
      }
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
    } finally {
      _launchingGalHook = false;
    }
  }

  Future<void> _importLunaHookProfiles() async {
    try {
      final FilePickerResult? picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['tsv'],
      );
      final String? path = picked == null || picked.files.isEmpty
          ? null
          : picked.files.first.path;
      if (path == null) return;
      final LunaHookCodeProfileStore store =
          await LunaHookCodeProfileStore.openDefault();
      await store.replaceFrom(File(path));
      HibikiToast.show(msg: 'Hook Code · ${t.dialog_import}');
    } on FormatException {
      HibikiToast.show(msg: t.audiobook_import_error);
    } catch (_) {
      HibikiToast.show(msg: t.audiobook_import_error);
    }
  }

  Future<void> _exportLunaHookProfiles() async {
    try {
      final String? path = await FilePicker.platform.saveFile(
        fileName: 'hibiki_luna_hook_profiles.tsv',
        type: FileType.custom,
        allowedExtensions: <String>['tsv'],
      );
      if (path == null) return;
      final LunaHookCodeProfileStore store =
          await LunaHookCodeProfileStore.openDefault();
      await store.exportTo(File(path));
      HibikiToast.show(msg: 'Hook Code · ${t.dialog_export}');
    } catch (_) {
      HibikiToast.show(msg: t.audiobook_import_error);
    }
  }

  Future<void> _saveSelectedLunaHookCode() async {
    final String? executable = _session.currentLaunchExecutable;
    final TexthookerTextThread? thread = _session.selectedTextThread;
    final String? hookCode = thread?.hookCode;
    if (executable == null || hookCode == null || hookCode.trim().isEmpty) {
      HibikiToast.show(msg: t.game_text_thread_hint);
      return;
    }
    try {
      final File executableFile = File(executable);
      final String hash = await sha256File(executableFile);
      final String label = executable.split(RegExp(r'[/\\]')).last;
      final LunaHookCodeProfileStore store =
          await LunaHookCodeProfileStore.openDefault();
      await store.upsert(
        LunaHookCodeProfile(
          executableSha256: hash,
          moduleName: '',
          moduleSha256: '',
          codepage: 932,
          hookCode: hookCode,
          label: label,
        ),
      );
      HibikiToast.show(msg: 'Hook Code · ${t.dialog_save}');
    } catch (_) {
      HibikiToast.show(msg: t.audiobook_import_error);
    }
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
                HibikiIconButton(
                  icon: Icons.link_off,
                  size: 18,
                  tooltip: t.external_window_unbind,
                  onTap: () => unawaited(_session.bindWindow(null)),
                ),
              HibikiIconButton(
                icon: Icons.refresh,
                size: 18,
                tooltip: t.external_window_refresh,
                onTap: _pickExternalWindow,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 列表当前是否停在（接近）底部。检查发生在新行触发 rebuild 之前，故 maxScrollExtent
  /// 反映的是加入新行前的内容——用户真在底部时 pixels≈maxScrollExtent 返回 true，手动
  /// 滚离底部时返回 false。无 clients（首帧）视作在底部（允许首次跟随）。
  bool _isNearBottom() {
    if (!_scroll.hasClients) return true;
    final ScrollPosition position = _scroll.position;
    return position.maxScrollExtent - position.pixels <= 80;
  }

  void _onLines() {
    if (!mounted) return;
    final List<TexthookerLineEntry> lines = TexthookerService.instance.entries;
    final String? latestId = lines.isEmpty ? null : lines.last.id;
    final bool receivedNewLine =
        latestId != null && latestId != _lastObservedLineId;
    _lastObservedLineId = latestId;
    // 跟随开着但用户手动滚离底部时不硬拽回底部（否则打断上翻回看）；此时累积未读，
    // 露出「未读 N」胶囊供一键回到最新。
    final bool follow = _followLive && _isNearBottom();
    setState(() {
      if (!follow && receivedNewLine) _unreadLines++;
    });
    if (!receivedNewLine || !follow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  /// TODO-1052：查词浮层 barrier 上「桌面水平拖过阈关一层」的纯状态追踪器（与
  /// reader/audiobook、video、home_dictionary 共用 [BarrierSwipeDismissTracker]）。
  final BarrierSwipeDismissTracker _barrierSwipe = BarrierSwipeDismissTracker();

  /// texthooker 每次点词复用热槽（`reuseWarmSlot: true`），可见栈至多一层（+ 隐藏热槽）；
  /// 关一层即收起当前查词。逐层关索引取最后可见层（无可见层回退 0，与 barrier 只在有可见层
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
    _selectLine(line);
    // BUG-1028：顶层查词复用常驻热槽（reuseWarmSlot:true）而非 replaceStack 冷建，
    // 复用已预热的弹窗 WebView，消除冷启动延迟（对齐 home_dictionary_page.dart:752）。
    // 无热槽（低内存 / seed 未就绪）时 beginTop 自动退回压新层，行为不变。
    pushNestedPopup(
      query: word,
      selectionRect: rect,
      controller: _popup,
      reuseWarmSlot: true,
      autoRead: true,
    );
  }

  void _selectLine(TexthookerLineEntry line) {
    if (_activeLineId == line.id && _activeSentence == line.text) return;
    setState(() {
      _activeLineId = line.id;
      _activeSentence = line.text;
    });
  }

  /// 翻转某行收藏态（仅会话内存态，不落 DB）。service 通知 → [_onLines] setState 刷新徽章。
  void _toggleLineFavorite(TexthookerLineEntry line) {
    TexthookerService.instance.toggleLineFavorite(line.id);
  }

  /// 未读胶囊点击：滚到最新一行并清零未读计数。
  void _jumpToLatestAndClearUnread() {
    setState(() => _unreadLines = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final TexthookerService texthooker = TexthookerService.instance;
    final List<TexthookerTextThread> textThreads = texthooker.textThreads;
    final String? selectedTextThreadKey = _session.selectedTextThreadKey;
    final List<TexthookerLineEntry> lines =
        texthooker.entriesForTextThread(selectedTextThreadKey);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPopupOverlay());
    if (widget.embedded) {
      return Column(
        children: <Widget>[
          HibikiPageHeader(
            title: t.game_capture_workbench,
            subtitle: t.game_capture_description,
            leading: widget.onShowLibrary == null
                ? null
                : HibikiIconButton(
                    icon: Icons.arrow_back,
                    tooltip: t.game_back_to_library,
                    onTap: widget.onShowLibrary,
                  ),
            actions: _buildToolbarActions(context, embedded: true),
            bottom: _buildSectionTabs(),
          ),
          Expanded(
            child: _buildMonitorBody(
              context,
              lines,
              textThreads,
              selectedTextThreadKey,
            ),
          ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(t.texthooker),
        actions: _buildToolbarActions(context, embedded: false),
      ),
      body: _buildMonitorBody(
        context,
        lines,
        textThreads,
        selectedTextThreadKey,
      ),
    );
  }

  /// 嵌入模式（[HomeGamePage]）与独立模式（[Scaffold]+[AppBar]）共用的工具栏动作。
  /// 消除此前两套按钮定义（AppBar actions 与嵌入专用 actions 不一致、独立模式缺
  /// 「停止监听」与 isActive 守卫）的特殊情况：主操作直接可见（启动并捕获 / 停止监听 /
  /// 清空台词），低频开关收进「更多」菜单。[embedded] 仅决定按钮是否展开文字标签
  /// （页头模式展开、AppBar 模式纯图标），按钮集合与行为调用两模式完全一致。
  ///
  /// 「兼容性诊断」入口已删——顶部 [GameSectionTabs] 已有同入口，工具栏再放一份纯冗余。
  List<Widget> _buildToolbarActions(
    BuildContext context, {
    required bool embedded,
  }) {
    final GalHookSessionState state = _session.state;
    String? labelOf(String value) => embedded ? value : null;
    return <Widget>[
      if (Platform.isWindows)
        HibikiIconButton(
          icon: Icons.rocket_launch_outlined,
          tooltip: t.game_launch_and_capture,
          label: labelOf(t.game_launch_and_capture),
          onTap: _launchGalgameEngineHook,
        ),
      if (state.isActive)
        HibikiIconButton(
          icon: Icons.stop_circle_outlined,
          tooltip: t.game_stop_listening,
          label: labelOf(t.game_stop_listening),
          onTap: () => unawaited(_session.stopCapture()),
        ),
      HibikiIconButton(
        icon: Icons.delete_outline,
        tooltip: t.clear,
        label: labelOf(t.clear),
        onTap: TexthookerService.instance.clear,
      ),
      _buildToolbarOverflowMenu(context),
    ];
  }

  /// 低频开关收纳菜单：允许音频降级 / 显示 Hook 文本浮窗（Win）/ 外部窗口挖矿（Win）。
  /// 两个真开关（音频降级、外部窗口挖矿）用 [CheckedPopupMenuItem] 反映当前开关态；
  /// 「显示 Hook 文本浮窗」是一次性动作（showManually），用普通菜单项。onSelected 由
  /// 枚举驱动，无特殊分支；各动作调用与旧按钮完全一致。
  Widget _buildToolbarOverflowMenu(BuildContext context) {
    final GalHookSessionState state = _session.state;
    return PopupMenuButton<_GalHookToolbarMenuAction>(
      key: const ValueKey<String>('game-toolbar-more'),
      tooltip: t.game_more_actions,
      icon: const Icon(Icons.more_vert),
      onSelected: (_GalHookToolbarMenuAction action) {
        switch (action) {
          case _GalHookToolbarMenuAction.audioFallback:
            _session.setAllowAudioFallback(!state.allowAudioFallback);
          case _GalHookToolbarMenuAction.showOverlay:
            unawaited(GalHookTextOverlayController.instance.showManually());
          case _GalHookToolbarMenuAction.externalWindow:
            unawaited(_toggleExternalWindowMode());
        }
      },
      itemBuilder: (BuildContext context) =>
          <PopupMenuEntry<_GalHookToolbarMenuAction>>[
        CheckedPopupMenuItem<_GalHookToolbarMenuAction>(
          value: _GalHookToolbarMenuAction.audioFallback,
          checked: state.allowAudioFallback,
          child: Text(t.game_audio_fallback_allow),
        ),
        if (Platform.isWindows)
          PopupMenuItem<_GalHookToolbarMenuAction>(
            value: _GalHookToolbarMenuAction.showOverlay,
            child: Text(t.game_show_hook_text_window),
          ),
        if (Platform.isWindows)
          CheckedPopupMenuItem<_GalHookToolbarMenuAction>(
            value: _GalHookToolbarMenuAction.externalWindow,
            checked: state.externalWindowMode,
            child: Text(t.external_window_mining),
          ),
      ],
    );
  }

  Widget? _buildSectionTabs() {
    if (widget.onShowLibrary == null || widget.onShowDiagnostics == null) {
      return null;
    }
    return GameSectionTabs(
      selected: GameSection.monitor,
      focusIdPrefix: 'game-capture-tab',
      onSelectLibrary: widget.onShowLibrary!,
      onSelectMonitor: () {},
      onSelectDiagnostics: widget.onShowDiagnostics!,
    );
  }

  Widget _buildMonitorBody(
    BuildContext context,
    List<TexthookerLineEntry> lines,
    List<TexthookerTextThread> textThreads,
    String? selectedTextThreadKey,
  ) {
    final GalHookSessionState state = _session.state;
    // BUG-1007 根因修复：健康卡 Anki 行此前写死「未配置」，不反映真实配置。
    // 接 app 级 AnkiViewModel 的已配置判定（牌组 + 笔记类型均已选中）。
    final bool ankiConfigured = ref.watch(
      ankiViewModelProvider
          .select((AnkiUiState uiState) => uiState.isConfigured),
    );
    return Column(
      children: <Widget>[
        _buildExperimentalBanner(context),
        if (state.externalWindowMode) _buildExternalWindowBar(context),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints box) {
                final Widget live = _buildLiveLinesPanel(
                  context,
                  lines,
                  textThreads,
                  selectedTextThreadKey,
                );
                final Widget latest = _LatestLineCard(
                  line: _selectedOrLatestLine(lines),
                );
                final Widget health = _CaptureHealthCard(
                  state: state,
                  endpoints: _session.endpointStatuses,
                  ankiConfigured: ankiConfigured,
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
                                crossAxisAlignment: CrossAxisAlignment.stretch,
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
                // 窄屏不再整块丢弃 latest/health 两面板（巡检 G7），折叠成
                // 可展开区放在实时行下方，默认收起不抢纵向空间。
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _SessionOverviewCard(state: state, compact: true),
                    const SizedBox(height: 12),
                    Expanded(child: live),
                    ExpansionTile(
                      title: Text(t.game_latest_line),
                      tilePadding: EdgeInsets.zero,
                      children: <Widget>[
                        // 上限高度：卡片内自带 SingleChildScrollView，超长台词
                        // 在卡内滚动而不是把实时行区挤到 0。
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 280),
                          child: latest,
                        ),
                      ],
                    ),
                    ExpansionTile(
                      title: Text(t.game_health),
                      tilePadding: EdgeInsets.zero,
                      children: <Widget>[
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 280),
                          child: health,
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
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
    List<TexthookerTextThread> textThreads,
    String? selectedTextThreadKey,
  ) {
    // 与线程下拉正交：[lines] 已按线程过滤，这里再按 [_lineFilter] 过滤成可见列表。
    final List<TexthookerLineEntry> visibleLines = lines
        .where((TexthookerLineEntry e) => lineMatchesFilter(e, _lineFilter))
        .toList(growable: false);
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
                  // 补 onTertiaryContainer 前景（此前继承默认前景，深色主题下
                  // 对比不足）；点击 = 跳到最新一行并清零未读。
                  Material(
                    color: Theme.of(context).colorScheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(999),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: _jumpToLatestAndClearUnread,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Text(
                          '${t.game_unread_lines} $_unreadLines',
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onTertiaryContainer,
                          ),
                        ),
                      ),
                    ),
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
                IconButton(
                  tooltip: 'Hook Code · ${t.dialog_save}',
                  icon: const Icon(Icons.bookmark_add_outlined, size: 20),
                  onPressed: _saveSelectedLunaHookCode,
                ),
                IconButton(
                  tooltip: 'Hook Code · ${t.dialog_import}',
                  icon: const Icon(Icons.file_download_outlined, size: 20),
                  onPressed: _importLunaHookProfiles,
                ),
                IconButton(
                  tooltip: 'Hook Code · ${t.dialog_export}',
                  icon: const Icon(Icons.file_upload_outlined, size: 20),
                  onPressed: _exportLunaHookProfiles,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: _buildFilterChips(context, lines),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // 共享手柄可进下拉（巡检 G3：全仓唯一裸 DropdownButton）。受控组件：
                // selected 每帧由真实会话状态推导——选中线程可能被行 buffer 上限
                // 淘汰/清空后不再在 items 里，不在则回退「全部」空串哨兵（BUG-952
                // 语义保持）。
                GamepadMenuDropdown<String>(
                  key: const ValueKey<String>('game-text-thread-selector'),
                  focusId: const HibikiFocusId('game-text-thread-selector'),
                  label: t.game_text_thread,
                  enabled: textThreads.isNotEmpty,
                  selected: textThreads.any(
                    (TexthookerTextThread thread) =>
                        thread.key == selectedTextThreadKey,
                  )
                      ? selectedTextThreadKey
                      : '',
                  entries: <GamepadDropdownEntry<String>>[
                    (value: '', label: t.game_text_thread_all),
                    for (final TexthookerTextThread thread in textThreads)
                      (
                        value: thread.key,
                        label: '${thread.label} · ${thread.lineCount}',
                      ),
                  ],
                  // 每条线程第二行：有音频行数 + 最近台词预览——没有预览用户
                  // 只能对着「引擎 · 地址 · 行数」盲选（用户实拍反馈）。
                  entrySubtitle: (String key) {
                    if (key.isEmpty) return null; // 「全部」行不带预览
                    for (final TexthookerTextThread thread in textThreads) {
                      if (thread.key == key) {
                        return texthookerThreadSubtitle(
                          audioLineCount: thread.audioLineCount,
                          latestText: thread.latestText,
                          audioLabel: t.game_text_thread_audio_count(
                            count: thread.audioLineCount,
                          ),
                        );
                      }
                    }
                    return null;
                  },
                  onChanged: (String value) {
                    TexthookerTextThread? selectedThread;
                    if (value.isNotEmpty) {
                      for (final TexthookerTextThread thread in textThreads) {
                        if (thread.key == value) {
                          selectedThread = thread;
                          break;
                        }
                      }
                    }
                    setState(() {
                      _activeLineId = null;
                      _activeSentence = null;
                      _unreadLines = 0;
                    });
                    unawaited(
                      _session.selectTextThread(
                        selectedThread?.nativeThreadId,
                        threadKey: selectedThread?.key,
                      ),
                    );
                  },
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    t.game_text_thread_hint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: lines.isEmpty
                ? Center(
                    // 可滚动：窄高（折叠面板占位后）空态不再溢出。
                    child: SingleChildScrollView(
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
                    itemCount: visibleLines.length,
                    itemBuilder: (BuildContext context, int i) {
                      final TexthookerLineEntry line = visibleLines[i];
                      return _TexthookerLine(
                        line: line,
                        // 分词结果按行 id 缓存，避免每次 rebuild 重复 textToWords。
                        words: _wordCache.wordsFor(line.id, line.text),
                        selected: line.id == _activeLineId,
                        onSelectLine: _selectLine,
                        onWordTap: _onWordTap,
                        onToggleFavorite: _toggleLineFavorite,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// 实时台词筛选 chips（全部 / 有音频 / 已制卡 / 已收藏），各带对应计数（如「已制卡 3」）。
  /// [lines] 是线程过滤后的完整集合——计数从它算，与线程下拉正交叠加；一个枚举 predicate
  /// 驱动，无「有音频/已制卡/已收藏」各写一条 if 的特殊情况。
  Widget _buildFilterChips(
    BuildContext context,
    List<TexthookerLineEntry> lines,
  ) {
    final int total = lines.length;
    final int withAudio =
        lines.where((TexthookerLineEntry e) => e.hasAudio).length;
    final int mined = lines.where((TexthookerLineEntry e) => e.mined).length;
    final int favorited =
        lines.where((TexthookerLineEntry e) => e.favorited).length;
    final List<(TexthookerLineFilter, String, int, IconData)> specs =
        <(TexthookerLineFilter, String, int, IconData)>[
      (
        TexthookerLineFilter.all,
        t.game_filter_all,
        total,
        Icons.list_alt_outlined
      ),
      (
        TexthookerLineFilter.withAudio,
        t.game_filter_with_audio,
        withAudio,
        Icons.graphic_eq_outlined,
      ),
      (
        TexthookerLineFilter.mined,
        t.game_filter_mined,
        mined,
        Icons.style_outlined
      ),
      (
        TexthookerLineFilter.favorited,
        t.game_filter_favorited,
        favorited,
        Icons.star_outline,
      ),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final (
              TexthookerLineFilter filter,
              String label,
              int count,
              IconData icon
            ) in specs)
          HibikiSelectableChip(
            label: '$label $count',
            leadingIcon: icon,
            selected: _lineFilter == filter,
            focusId: HibikiFocusId('game-line-filter-${filter.name}'),
            onSelected: (_) => setState(() => _lineFilter = filter),
          ),
      ],
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

  /// 查词浮层放到根 Overlay，并把整棵浮层子树中和到净缩放 1。
  ///
  /// 这样平台 WebView 不会在缩放画布内低分辨率栅格化，且点词得到的
  /// `localToGlobal` 屏幕矩形与浮层处在同一坐标系。
  void _syncPopupOverlay() {
    if (!mounted) return;
    if (_popup.entries.isEmpty && !_popup.isSearchingUi) {
      final OverlayEntry? entry = _popupOverlayEntry;
      if (entry != null) {
        if (entry.mounted) entry.remove();
        entry.dispose();
        _popupOverlayEntry = null;
      }
      return;
    }
    if (_popupOverlayEntry != null) {
      _popupOverlayEntry!.markNeedsBuild();
      return;
    }
    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final OverlayEntry entry = OverlayEntry(builder: _buildPopupOverlay);
    _popupOverlayEntry = entry;
    overlay.insert(entry);
  }

  Widget _buildPopupOverlay(BuildContext overlayContext) {
    if (!mounted || _overlayInert) return const SizedBox.shrink();
    return HibikiAppUiScaleNeutralizer(
      child: Theme(
        data: _appModel.overrideDictionaryTheme ?? Theme.of(overlayContext),
        child: Builder(
          builder: (BuildContext context) {
            if (!mounted || _overlayInert) return const SizedBox.shrink();
            return Stack(
              clipBehavior: Clip.none,
              children: _buildPopups(context),
            );
          },
        ),
      ),
    );
  }
}

class _SessionOverviewCard extends StatelessWidget {
  const _SessionOverviewCard({required this.state, this.compact = false});

  final GalHookSessionState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final String audio = galHookAudioBackendLabel(state.audioBackend);
    final String phase = galHookSessionPhaseLabel(state.phase);
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
                      ? '$phase · $audio'
                      : '$phase · $audio'
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
                value: value.sourceLabel ??
                    texthookerLineSourceLabel(
                      value.source,
                    ),
              ),
              _MetadataRow(
                label: t.game_health_audio,
                value: value.audioBackend ??
                    texthookerLineAudioStatusLabel(value.audioStatus),
              ),
              if (value.audioResourceId != null)
                _MetadataRow(
                  label: t.game_audio_resource_id,
                  value: value.audioResourceId!,
                ),
              if (value.audioDurationMs != null)
                // 值是时长不是格式，标签用 game_audio_duration（巡检 G7）。
                _MetadataRow(
                  label: t.game_audio_duration,
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
  const _CaptureHealthCard({
    required this.state,
    required this.endpoints,
    required this.ankiConfigured,
  });

  final GalHookSessionState state;
  final List<TexthookerEndpointStatus> endpoints;

  /// Anki 输出是否已配置（牌组 + 笔记类型均已选，BUG-1007）。
  final bool ankiConfigured;

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
              value: galHookAudioBackendLabel(state.audioBackend),
              ready: state.hasAudio,
            ),
            _HealthRow(
              label: t.game_health_helper,
              value: galHookSessionPhaseLabel(state.phase),
              ready: state.isActive && state.phase != GalHookSessionPhase.error,
            ),
            // BUG-1007：接真实 Anki 配置状态，不再写死「未配置」。
            _HealthRow(
              label: t.game_health_anki,
              value: ankiConfigured
                  ? t.game_status_ready
                  : t.game_status_not_configured,
              ready: ankiConfigured,
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

/// 一行文本：日语分词成可点 span（引擎未初始化时按字符降级，widget 测试不崩）。
/// [words] 由页级 [_TexthookerWordCache] 按行 id 预分词后注入（本 widget 不再自行
/// textToWords），避免每来一行整页 rebuild 时重复分词。
class _TexthookerLine extends StatelessWidget {
  const _TexthookerLine({
    required this.line,
    required this.words,
    required this.selected,
    required this.onSelectLine,
    required this.onWordTap,
    required this.onToggleFavorite,
  });

  final TexthookerLineEntry line;
  final List<String> words;
  final bool selected;
  final ValueChanged<TexthookerLineEntry> onSelectLine;
  final ValueChanged<TexthookerLineEntry> onToggleFavorite;
  final void Function(
    TexthookerLineEntry line,
    String word,
    Rect rect,
  ) onWordTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String source =
        line.sourceLabel ?? texthookerLineSourceLabel(line.source);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: HibikiCard(
        key: ValueKey<String>('game-line-${line.id}'),
        selected: selected,
        focusId: HibikiFocusId('game-line-${line.id}'),
        onTap: () => onSelectLine(line),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${formatGameClockTime(line.receivedAt)} · $source'
                    '${line.textThreadLabel == null ? '' : ' · ${line.textThreadLabel}'}'
                    '${line.sourceSequence == null ? '' : ' · #${line.sourceSequence}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                  ),
                ),
                const SizedBox(width: 8),
                // 已制卡徽章优先于音频态并列显示（样式对齐 _LineAudioChip）。
                if (line.mined) ...<Widget>[
                  const _LineMinedChip(),
                  const SizedBox(width: 6),
                ],
                _LineAudioChip(status: line.audioStatus),
                const SizedBox(width: 4),
                // 会话内存态收藏星（不落 DB）；已收藏填充金黄星，未收藏描边星。
                HibikiIconButton(
                  icon: line.favorited ? Icons.star : Icons.star_border,
                  tooltip: line.favorited
                      ? t.game_line_unfavorite_tooltip
                      : t.game_line_favorite_tooltip,
                  size: 18,
                  enabledColor: line.favorited ? colors.tertiary : null,
                  onTap: () => onToggleFavorite(line),
                ),
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
                line.audioResourceId != null ||
                line.fallbackReason != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                <String>[
                  if (line.audioBackend != null) line.audioBackend!,
                  if (line.audioResourceId != null) line.audioResourceId!,
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
}

/// 「已制卡」徽章：样式对齐 [_LineAudioChip]，用 primary 面强调本行已成功制卡。
class _LineMinedChip extends StatelessWidget {
  const _LineMinedChip();

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.primary,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.style, size: 12, color: colors.onPrimary),
          const SizedBox(width: 4),
          Text(
            t.game_line_mined,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: colors.onPrimary),
          ),
        ],
      ),
    );
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
    // 巡检 G2（鼠标部分）：手型光标 + hover 底色让「可点查词」在桌面可发现。
    // InkWell 不抢焦点（canRequestFocus:false）——行内逐词键盘导航不在本轮范围，
    // 行级焦点站点仍由外层 HibikiCard 提供。
    return InkWell(
      canRequestFocus: false,
      hoverColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
      onTap: () {
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

/// 行分词结果缓存：行文本按 id 不可变（copyWith 只改音频/制卡/收藏态，不动 id/text），
/// 故按 id 缓存 [JapaneseLanguage.textToWords] 恒安全。每来一行整页 setState，无缓存时
/// 每行每帧都重新分词——本缓存把它降为「每行只分一次」。默认 Map 保持插入序，越界时
/// 淘汰最旧插入项（上限略高于行 buffer 上限 [TexthookerService.maxLines]，可见行不会被淘汰）。
class _TexthookerWordCache {
  static const int _maxEntries = 800;
  final Map<String, List<String>> _cache = <String, List<String>>{};

  List<String> wordsFor(String id, String text) {
    final List<String>? cached = _cache[id];
    if (cached != null) return cached;
    final List<String> words = JapaneseLanguage.instance.textToWords(text);
    _cache[id] = words;
    if (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    return words;
  }
}
