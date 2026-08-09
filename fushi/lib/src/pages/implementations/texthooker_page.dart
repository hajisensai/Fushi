import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:fushi/src/mining/gal_hook_failure_text.dart';
import 'package:fushi/src/mining/magpie_upscaling_service.dart';
import 'package:fushi/src/mining/magpie_upscaling_text.dart';
import 'package:fushi/src/mining/gal_audio_tracks_panel.dart';
import 'package:fushi/src/mining/gal_hook_mining_coordinator.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/galgame_helper_installer.dart';
import 'package:fushi/src/mining/galgame_hook_code_profile.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:fushi/src/pages/implementations/gal_capture_setup_dialog.dart';
import 'package:fushi/src/pages/implementations/game_shared.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/sync/texthooker_ws_client.dart';
import 'package:fushi/src/utils/misc/desktop_audio_playback.dart';
import 'package:fushi/src/utils/misc/swipe_dismiss_wrapper.dart';
import 'package:fushi/media.dart';
import 'package:fushi/utils.dart';

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
enum _GalHookToolbarMenuAction {
  audioFallback,
  health,
  showOverlay,
  externalWindow,
}

/// texthooker 捕获工作台：实时展示 WebSocket 收到的文本行，逐词查词 + 挖词。
///
/// 订阅单例 [TexthookerService]（ChangeNotifier）实时刷新文本行；每行经日语分词
/// 成可点 span，点击后经 [DictionaryPageMixin.pushNestedPopup] 弹查词浮层，挖词
/// 复用 mixin 的 Anki 逻辑。
class TexthookerPage extends ConsumerStatefulWidget {
  const TexthookerPage({
    super.key,
    this.embedded = false,
    this.captureSetupEnabled = true,
    this.onShowLibrary,
    this.onShowDiagnostics,
  });

  /// 嵌入 [HomeGamePage] 时不再创建第二层 Scaffold/AppBar。
  final bool embedded;
  final bool captureSetupEnabled;
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
  bool _popupOverlayRebuildScheduled = false;
  String? _activeLineId;
  String? _activeSentence;
  bool _followLive = true;
  int _unreadLines = 0;
  String? _lastObservedLineId;

  /// galgame 引擎-hook 启动的**再入守卫**：一次启动含选文件、位数探测、helper 确认/下载对话框、
  /// 注入会话等多个 await，可持续数秒。没有守卫时重复点击会叠出多个下载确认对话框。
  bool _launchingGalHook = false;

  /// 每个捕获会话只自动弹一次首次设置；手动关闭后不反复打扰。新会话由
  /// sessionStartedAt 区分，候选线程出现且仍未选中时才弹，避免空白弹窗。
  DateTime? _captureSetupShownForSession;
  bool _captureSetupDialogOpen = false;
  bool _captureSetupDialogScheduled = false;

  /// 实时台词列表的筛选维度（全部 / 有音频 / 已制卡 / 已收藏）。与线程下拉正交叠加。
  TexthookerLineFilter _lineFilter = TexthookerLineFilter.all;

  /// 正在行内试听的行 id；null = 未在试听（样式对齐诊断页逐轨试听）。
  String? _previewingLineId;

  /// 试听播完把按钮从「停止」复位回「播放」的定时器。资源原件时长未知（durationMs
  /// 0）时按 [_kLinePreviewMaxMs] 上限兜底复位。
  Timer? _linePreviewResetTimer;

  /// 资源原件（OGG/WAV）时长未知时的复位上限：galgame 单句语音极少超过它。
  static const int _kLinePreviewMaxMs = 15000;

  /// 行内试听 / 停止：经 controller 取该行已配音频（game_resource 原件直接播，
  /// PCM/loopback 冻结切片拼 WAV），只读不改行状态、不碰制卡链路。
  Future<void> _toggleLinePreview(TexthookerLineEntry line) async {
    if (_previewingLineId == line.id) {
      _linePreviewResetTimer?.cancel();
      setState(() => _previewingLineId = null);
      await DesktopAudioPlayback.stop();
      return;
    }
    final GalTrackPreview? preview =
        await _session.exportLineAudioPreview(line.id);
    if (!mounted) return;
    if (preview == null) {
      FushiToast.show(
        msg: t.game_line_preview_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    final bool started = await DesktopAudioPlayback.playFile(preview.filePath);
    if (!mounted) return;
    if (!started) {
      FushiToast.show(
        msg: t.game_line_preview_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    _linePreviewResetTimer?.cancel();
    setState(() => _previewingLineId = line.id);
    final int resetMs =
        preview.durationMs > 0 ? preview.durationMs + 300 : _kLinePreviewMaxMs;
    _linePreviewResetTimer = Timer(
      Duration(milliseconds: resetMs),
      () {
        if (mounted) setState(() => _previewingLineId = null);
      },
    );
  }

  /// 为单条台词改选语音轨（BUG-1102 的用户裁决出口）。
  ///
  /// 会话级「活跃音轨」选择只改自动选源的默认值，且只在引擎 PCM 是当前音源时生效；
  /// 用户对**某一句**说「这句应该用这条轨」是与手动补录同级的裁决，走
  /// [GalHookSessionController.setLineVoiceTrack] 独立取音。列表复用会话已有的音轨
  /// 快照，并保留逐轨试听，让用户先听再定。
  Future<void> _pickLineTrack(TexthookerLineEntry line) async {
    final List<GalAudioTrack> tracks = _session.state.audioTracks;
    if (tracks.isEmpty) {
      FushiToast.show(
        msg: t.game_no_tracks,
        severity: ToastSeverity.error,
      );
      return;
    }
    final int? picked = await showAppDialog<int>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setDialogState) =>
            SimpleDialog(
          title: Text(t.game_line_track_dialog_title),
          children: <Widget>[
            for (final GalAudioTrack track in tracks)
              Builder(
                builder: (BuildContext context) {
                  final bool excluded = _session.state.excludedAudioSourcePtrs
                      .contains(track.sourcePtr);
                  // BUG-1425：行骨架走共享 MD3 组件，不再裸 ListTile。本文件的
                  // reviewed 豁免只覆盖「hook 状态胶囊是实时内容指示器」，从不覆盖
                  // 对话框行骨架。`ListTile.enabled` 的两个作用分开落地：不可选走
                  // onTap: null（本来就有），置灰走显式 disabled 前景色。
                  final Color disabledColor = FushiDesignTokens.of(context)
                      .surfaces
                      .onSurface
                      .withValues(alpha: 0.38);
                  return FushiListItem(
                    leading: Icon(
                      excluded ? Icons.music_off_outlined : Icons.graphic_eq,
                      color: excluded ? disabledColor : null,
                    ),
                    title: Text(
                      '${t.game_track_voice} ${track.orderIndex + 1} · '
                      '${track.format.sampleRate} Hz · '
                      '${track.format.channels} ch',
                      style: excluded ? TextStyle(color: disabledColor) : null,
                    ),
                    subtitle: Text(
                      <String>[
                        '${t.game_track_clips} ${track.clipCount}',
                        '${t.game_track_energy} '
                            '${track.avgEnergy.toStringAsFixed(1)}',
                        if (excluded) t.game_track_bgm,
                      ].join(' · '),
                      style: excluded ? TextStyle(color: disabledColor) : null,
                    ),
                    trailing: Wrap(
                      spacing: 4,
                      children: <Widget>[
                        FushiIconButton(
                          icon: Icons.play_circle_outline,
                          tooltip: t.game_track_preview,
                          onTap: () => unawaited(
                            _previewLineTrackInDialog(
                              line.id,
                              track.sourcePtr,
                            ),
                          ),
                        ),
                        FushiIconButton(
                          icon:
                              excluded ? Icons.undo : Icons.music_off_outlined,
                          tooltip: excluded
                              ? t.game_track_restore
                              : t.game_track_exclude_bgm,
                          onTap: () {
                            _session.setTrackExcluded(
                              track.sourcePtr,
                              !excluded,
                            );
                            setDialogState(() {});
                          },
                        ),
                      ],
                    ),
                    // 已明确标为 BGM 的轨不能再被误点成这句语音；仍可试听与恢复。
                    onTap: excluded
                        ? null
                        : () =>
                            Navigator.of(dialogContext).pop(track.sourcePtr),
                  );
                },
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final bool applied = await _session.setLineVoiceTrack(line.id, picked);
    if (!mounted) return;
    FushiToast.show(
      msg: applied ? t.game_line_track_applied : t.game_line_track_failed,
      severity: applied ? ToastSeverity.success : ToastSeverity.error,
    );
  }

  /// 选轨对话框里的逐轨试听：与确认选择共用当前行时间戳，避免试听偷播最新一句。
  Future<void> _previewLineTrackInDialog(String lineId, int sourcePtr) async {
    final GalTrackPreview? preview =
        await _session.exportLineTrackPreview(lineId, sourcePtr);
    if (preview == null) {
      FushiToast.show(
        msg: t.game_track_preview_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    if (!await DesktopAudioPlayback.playFile(preview.filePath)) {
      FushiToast.show(
        msg: t.game_track_preview_failed,
        severity: ToastSeverity.error,
      );
    }
  }

  /// 会话音轨对话框：内容复用 [GalAudioTracksPanel]（与诊断页同一份），随会话
  /// 状态实时刷新。逐轨试听按最近一条台词时间戳整句抓取（与诊断页同语义——这里
  /// 是会话级判断「哪条轨是语音/BGM」，不针对具体某句；针对某句改轨走行内改轨）。
  Future<void> _showSessionTrackPanel() async {
    unawaited(_session.refreshAudioTracks());
    int? previewingPtr;
    Timer? previewReset;
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            Future<void> handlePreview(GalAudioTrack track) async {
              if (previewingPtr == track.sourcePtr) {
                previewReset?.cancel();
                setDialogState(() => previewingPtr = null);
                await DesktopAudioPlayback.stop();
                return;
              }
              final GalTrackPreview? preview =
                  await _session.exportTrackPreview(track.sourcePtr);
              if (!dialogContext.mounted) return;
              if (preview == null) {
                FushiToast.show(
                  msg: t.game_track_preview_failed,
                  severity: ToastSeverity.error,
                );
                return;
              }
              final bool started =
                  await DesktopAudioPlayback.playFile(preview.filePath);
              if (!dialogContext.mounted) return;
              if (!started) {
                FushiToast.show(
                  msg: t.game_track_preview_failed,
                  severity: ToastSeverity.error,
                );
                return;
              }
              previewReset?.cancel();
              setDialogState(() => previewingPtr = track.sourcePtr);
              previewReset = Timer(
                Duration(milliseconds: preview.durationMs + 300),
                () {
                  if (dialogContext.mounted) {
                    setDialogState(() => previewingPtr = null);
                  }
                },
              );
            }

            return AlertDialog(
              title: Text(t.game_audio_tracks),
              content: SizedBox(
                width: 520,
                child: ListenableBuilder(
                  listenable: _session,
                  builder: (BuildContext context, Widget? child) {
                    return SingleChildScrollView(
                      child: GalAudioTracksPanel(
                        state: _session.state,
                        onSelectVoice: _session.selectVoiceTrack,
                        onToggleExcluded: _session.setTrackExcluded,
                        onPreviewTrack: (GalAudioTrack track) =>
                            unawaited(handlePreview(track)),
                        previewingSourcePtr: previewingPtr,
                      ),
                    );
                  },
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(t.dialog_close),
                ),
              ],
            );
          },
        );
      },
    );
    previewReset?.cancel();
    unawaited(DesktopAudioPlayback.stop());
  }

  /// 行内补录开/收：missing/兜底行的一键补救。开窗后回游戏里点一次语音重播，
  /// 再点停止（或等窗口到点自动收束）。与浮窗「重播并录音」同一条控制器出口，
  /// 结果标注 manual_recapture，自动配对不得再覆盖（用户裁决优先）。
  Future<void> _toggleLineRecapture(TexthookerLineEntry line) async {
    if (_session.recapturingLineId == line.id) {
      final bool ok = await _session.finishLineRecapture();
      FushiToast.show(
        msg: ok ? t.game_hook_recapture_saved : t.game_hook_recapture_empty,
        // 补录窗口空手而归不是崩溃，是「这次没录到」——warning 而非 error。
        severity: ok ? ToastSeverity.success : ToastSeverity.warning,
      );
      return;
    }
    final bool started = await _session.startLineRecapture(line.id);
    FushiToast.show(
      msg: started
          ? t.game_hook_recapture_started
          : t.game_hook_recapture_unavailable,
      // 开录是「去游戏里重播这句」的操作指示（info）；开不起来是能力缺失（error）。
      severity: started ? ToastSeverity.info : ToastSeverity.error,
    );
  }

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
      _maybeScheduleCaptureSetupDialog();
    });
  }

  @override
  void didUpdateWidget(TexthookerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.captureSetupEnabled && widget.captureSetupEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _maybeScheduleCaptureSetupDialog();
      });
    }
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
    _linePreviewResetTimer?.cancel();
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
      _schedulePopupOverlayRebuild();
    }
  }

  /// A dependency change is delivered while this page itself is rebuilding.
  /// The popup lives in the root Overlay, which is an ancestor rather than a
  /// descendant of this element, so dirtying its entry synchronously from
  /// [didChangeDependencies] violates Flutter's build ordering and can corrupt
  /// the subsequent LayoutBuilder dirty queue. Coalesce visibility changes and
  /// update the overlay only after the current frame has finished building.
  void _schedulePopupOverlayRebuild() {
    if (_popupOverlayRebuildScheduled) return;
    _popupOverlayRebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _popupOverlayRebuildScheduled = false;
      if (!mounted) return;
      final OverlayEntry? entry = _popupOverlayEntry;
      if (entry != null && entry.mounted) {
        entry.markNeedsBuild();
      }
    });
  }

  /// 测试可见：查词浮层当前是否被置为 inert（隐藏 tab / 失活时收起）。BUG-953 守卫用。
  @visibleForTesting
  bool get debugOverlayInert => _overlayInert;

  /// Installs the root-overlay host without starting a dictionary lookup.
  ///
  /// This is intentionally limited to tests: a real lookup also creates a
  /// platform WebView, while the overlay lifecycle regression can be exercised
  /// with an empty host.
  @visibleForTesting
  void debugMountPopupOverlayForTesting() {
    if (_popupOverlayEntry != null) return;
    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final OverlayEntry entry = OverlayEntry(builder: _buildPopupOverlay);
    _popupOverlayEntry = entry;
    overlay.insert(entry);
  }

  /// BUG-1137：texthooker 页制出的卡归「游戏」分类标签——外部窗口模式走
  /// [GalHookMiningCoordinator]（自带 game 来源），fallback 纯文本卡走 mixin 的
  /// super.onMineEntry / onUpdateEntry，也必须同标 game，不能吃默认 book。
  /// 统计口径（[dictionarySourceType]）不动，标签与统计是两个维度。
  @override
  AnkiMiningSource get miningSource => AnkiMiningSource.game;

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
      FushiToast.showMine(
        msg: t.game_hook_line_unavailable,
        status: MineToastStatus.failed,
      );
      return const MinePopupResult();
    }
    final Map<String, String> effectiveFields = Map<String, String>.from(fields)
      ..['sentence'] = entry.text;
    FushiToast.showMine(
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
        // 顶格档的动图参数随格式变，必须一并传入解析（见 MiningAnimatedFormat）。
        // gal 窗口动图当前不吃清晰度档（`captureWindowGifBytes` 用自己的
        // fps/maxWidth），所以这里传不传都一样——传是为了让两个 gal 入口与视频侧
        // 逐字同形，免得哪天 gal 接上档位时又漏一处。
        format: mixinAppModel.galMiningAnimatedFormat,
      ),
      repo: repo,
      updateNoteId: updateNoteId,
      addTitleTag: mixinAppModel.autoAddBookNameToTags,
      imageMode: mixinAppModel.galMiningImageMode,
      animatedFormat: mixinAppModel.galMiningAnimatedFormat,
    );
    if (result.aborted) {
      FushiToast.showMine(
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
    FushiToast.showMine(msg: described.message, status: described.status);
    if (result.sentenceAudioMissing) {
      // 卡片建成了、只是缺句子音频 = 部分成功。
      FushiToast.show(
        msg: t.game_card_sentence_audio_missing,
        severity: ToastSeverity.warning,
      );
    }
    if (result.unmappedTokens.isNotEmpty) {
      // 冒号统一全角（与上方 external_window_capture_failed toast 一致）。
      FushiToast.show(
        msg: '${t.game_card_mapping_missing}：'
            '${result.unmappedTokens.join(', ')}',
        severity: ToastSeverity.warning,
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
    final ExternalWindowInfo? picked = await _showExternalWindowPicker();
    // 选回当前已绑定的那个窗口是 no-op，不是「重新绑定」：bindWindow 在捕获模式下会
    // startAttachedCapture 重启整条会话（launch 会话会因此退化成 attach，正在跑的
    // engine hook 与已收台词一起丢）。预选中当前游戏后回车确认是最自然的操作，绝不能
    // 因此把会话打断。
    if (picked == null || picked.hwnd == _session.state.boundWindow?.hwnd) {
      return;
    }
    await _session.bindWindow(picked);
  }

  /// 只负责「选」：列出可捕获窗口交给用户挑一个，绑定还是直接起捕获由调用方决定。
  /// 拆出来是因为「附着并捕获」与「绑定窗口」对同一份列表有两种不同的后续处置，
  /// 把处置塞进选择器会逼出模式参数。
  Future<ExternalWindowInfo?> _showExternalWindowPicker() async {
    if (!Platform.isWindows) {
      FushiToast.show(
        msg: t.external_window_unsupported,
        severity: ToastSeverity.error,
      );
      return null;
    }
    final List<ExternalWindowInfo> windows =
        await WindowCaptureChannel.listWindows();
    if (windows.isEmpty) {
      FushiToast.show(
        msg: t.external_window_no_windows,
        severity: ToastSeverity.error,
      );
      return null;
    }
    if (!context.mounted) return null;
    // BUG-1049：Hibiki 自己启动的游戏必须在这份列表里「已经选好」。会话知道游戏 pid，
    // 却把它和一屏无关窗口平铺在一起，等于让用户替 app 认自己刚拉起的进程。按 pid
    // 把它排到第一条、标注出来并预置焦点：打开即落在正确的窗口上，回车就绑。
    final int? gamePid = _session.state.gamePid;
    final int? boundHwnd = _session.state.boundWindow?.hwnd;
    final List<ExternalWindowInfo> ordered = <ExternalWindowInfo>[
      ...windows
          .where((ExternalWindowInfo w) => gamePid != null && w.pid == gamePid),
      ...windows
          .where((ExternalWindowInfo w) => gamePid == null || w.pid != gamePid),
    ];
    final ExternalWindowInfo? picked = await showAppDialog<ExternalWindowInfo>(
      context: context,
      // BUG-1474：这个 SimpleDialog 原先一条尺寸约束都没有，走 Flutter 默认的
      // minWidth 280 + intrinsic 宽度——窗口标题（往往是「游戏名 - 章节 - 存档」这类
      // 长串）一律被挤成一行省略号。同文件的音轨弹窗早就用 SizedBox(width: 520)，
      // 这里照同一规格给出可用宽度。
      builder: (BuildContext ctx) => SimpleDialog(
        title: Text(t.external_window_select),
        children: <Widget>[
          for (final ExternalWindowInfo window in ordered)
            // BUG-1425：行骨架走共享 MD3 组件，不再裸 ListTile（豁免理由只覆盖
            // hook 状态胶囊）。autofocus 是 BUG-1049 的焦点驱动行为，随之收进
            // [FushiListItem]，不能在收口时悄悄丢掉。
            SizedBox(
              width: 560,
              child: FushiListItem(
                // 焦点驱动纪律：这一项拿到初始焦点，Tab/方向键从它开始，Enter 直接确认。
                autofocus: gamePid != null
                    ? window.pid == gamePid
                    : window.hwnd == boundHwnd,
                // BUG-1184 定的规矩：放宽标题行数必须逐调用点显式做，不改默认值。
                // 这里父容器高度自由（SimpleDialog 的 children 列），放宽安全。
                titleMaxLines: 2,
                title: Text(
                  window.title.isEmpty ? '#${window.hwnd}' : window.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: gamePid != null && window.pid == gamePid
                    ? Text(
                        t.external_window_current_game,
                        style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                              color: Theme.of(ctx).colorScheme.primary,
                            ),
                      )
                    : null,
                onTap: () => Navigator.of(ctx).pop(window),
              ),
            ),
        ],
      ),
    );
    return picked;
  }

  /// 附着到**已在运行**的游戏：与「启动并捕获」并列的一级入口。
  ///
  /// 底层能力一直都在（injector `--pid` attach + [GalHookSessionController.
  /// startAttachedCapture] 的完整注入编排），但此前唯一入口是「更多」溢出菜单里
  /// 那个叫「外部窗口挖矿」的模式开关——名字看不出是「附着到已经在跑的游戏」，
  /// 等于把一条主路径藏进溢出菜单，用户只能每次都让 Hibiki 把游戏拉起来。
  ///
  /// 直接调 [GalHookSessionController.startAttachedCapture]，不拼
  /// 「[GalHookSessionController.bindWindow] + [GalHookSessionController
  /// .setExternalWindowMode]」两步：那两个方法各自都会在另一半就位时触发
  /// startAttachedCapture，连着调会起两次会话，第二次把第一次刚装好的 engine hook
  /// 和已收台词一起丢掉。startAttachedCapture 自己就把 externalWindowMode /
  /// boundWindow / gamePid 一次设对。
  Future<void> _attachToRunningGame() async {
    final ExternalWindowInfo? picked = await _showExternalWindowPicker();
    if (picked == null) return;
    final GalHookSessionState state = _session.state;
    // 已经在捕获这个窗口：重来一遍只会丢掉正在跑的 hook 与已收台词，什么都不做。
    if (state.isActive &&
        state.externalWindowMode &&
        state.boundWindow?.hwnd == picked.hwnd) {
      return;
    }
    await _session.startAttachedCapture(picked);
  }

  /// galgame 引擎-hook（launch 模式）：页面只发起会话；位数解析、注入器选择、窗口绑定、
  /// 音频源回退都在 [GalHookSessionController]。KiriKiriZ 仍走早注入；SiglusEngine 由
  /// injector 自动改为 Enigma-safe 延迟附着，并通过 raw-only Ogg 路径提供制卡音频。
  Future<void> _launchGalgameEngineHook() async {
    if (_launchingGalHook) return; // 再入守卫：启动进行中，忽略重复点击（避免多开确认对话框）。
    _launchingGalHook = true;
    try {
      if (!Platform.isWindows) {
        FushiToast.show(
          msg: t.external_window_unsupported,
          severity: ToastSeverity.error,
        );
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
      // BUG-1448：见 games_library_page 同处注释——「injector 在不在」不是判据，
      // 「版本对不对」才是。这道前置门会让随包新组件永远换不进去。
      if (!context.mounted) return;
      final bool installed = await GalgameHelperInstaller().ensureInjector(
        is32Bit: is32Bit,
        context: context,
      );
      if (!installed || !mounted) return;
      FushiToast.show(
        msg: t.game_capture_launching,
        severity: ToastSeverity.info,
      );
      // 这条入口只拿到一个裸 exe 路径、不经过游戏库条目，但同一个 exe 就是同一个游戏：
      // 按路径回查库里已配置的启动参数与工作目录，让「从库里启动」和「从工作台启动并
      // 捕获」用同一份配置。库里没有这个 exe（临时选的文件）→ 空配置 = 旧行为。
      final GalgameEntry? known = findGalgameByExePath(
        _appModel.galgameRepo.games,
        executable,
      );
      final GalHookLaunchResult result = await _session.launchGame(
        executable,
        launchArguments: known?.launchArgumentTokens ?? const <String>[],
        workdir: known?.workdir ?? '',
        gameId: known?.id,
        gameTitle: known?.displayName,
      );
      if (!mounted) return;
      // 与游戏库页共用同一条结果播报（BUG-1089）。旧实现在这里自己判 `boundWindow`
      // 并说「捕获已运行；尚未找到游戏窗口」——避重就轻：窗口没出现往往意味着游戏
      // 主线程还挂着、根本没跑起来，说成「已运行」会让用户以为没事。
      final GalHookSessionState state = _session.state;
      final GalHookLaunchOutcome outcome = classifyGalHookLaunchOutcome(
        result: result,
        hasBoundWindow: state.boundWindow != null,
        injectorFailure: state.injectorFailure,
      );
      // message 为 null = 本次启动已被更新的操作取代，不该播报（BUG-1142）。
      final String? message = galHookLaunchOutcomeMessage(
        outcome: outcome,
        result: result,
        failure: state.injectorFailure,
        lastError: state.lastError,
        injectorDetail: state.injectorDetail,
      );
      // BUG-1089 的着色面：outcome 已经把「跑起来了 / 只剩整机混音兜底 / 根本没起来」
      // 分好了，toast 的颜色跟着同一份判定走，别再让三种结局长成同一条无色提示。
      if (message != null) {
        FushiToast.show(
          msg: message,
          severity: switch (outcome) {
            GalHookLaunchOutcome.running => ToastSeverity.success,
            GalHookLaunchOutcome.degradedLoopback => ToastSeverity.warning,
            GalHookLaunchOutcome.failed ||
            GalHookLaunchOutcome.windowMissing =>
              ToastSeverity.error,
            // message 为 null 时根本不播报，这里走不到。
            GalHookLaunchOutcome.superseded => ToastSeverity.neutral,
          },
        );
      }
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
      FushiToast.show(
        msg: 'Hook Code · ${t.dialog_import}',
        severity: ToastSeverity.success,
      );
    } on FormatException {
      FushiToast.show(
        msg: t.audiobook_import_error,
        severity: ToastSeverity.error,
      );
    } catch (_) {
      FushiToast.show(
        msg: t.audiobook_import_error,
        severity: ToastSeverity.error,
      );
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
      FushiToast.show(
        msg: 'Hook Code · ${t.dialog_export}',
        severity: ToastSeverity.success,
      );
    } catch (_) {
      FushiToast.show(
        msg: t.audiobook_import_error,
        severity: ToastSeverity.error,
      );
    }
  }

  Future<void> _saveSelectedLunaHookCode() async {
    final String? executable = _session.currentLaunchExecutable;
    final TexthookerTextThread? thread = _session.selectedTextThread;
    final String? hookCode = thread?.hookCode;
    if (executable == null || hookCode == null || hookCode.trim().isEmpty) {
      // 没选文本线程就点保存＝前置条件不满足、什么都没存下，必须让用户看出这次没成。
      FushiToast.show(
        msg: t.game_text_thread_hint,
        severity: ToastSeverity.error,
      );
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
      FushiToast.show(
        msg: 'Hook Code · ${t.dialog_save}',
        severity: ToastSeverity.success,
      );
    } catch (_) {
      FushiToast.show(
        msg: t.audiobook_import_error,
        severity: ToastSeverity.error,
      );
    }
  }

  void _onSessionChanged() {
    if (!mounted) return;
    setState(() {});
    _maybeScheduleCaptureSetupDialog();
  }

  /// 外部窗口挖矿模式条：展示已绑定窗口标题 + 重选/解绑；未绑定时点击选窗口。
  Widget _buildExternalWindowBar(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final ExternalWindowInfo? bound = _session.state.boundWindow;
    return Material(
      // 走共享设计 token 的语义 overlay 面（顶层容器面调性），不在页面里直接引原始
      // ColorScheme 面 token（MD3 守卫要求 ordinary chrome 走共享组件）。
      color: FushiDesignTokens.of(context).surfaces.overlay,
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
                FushiIconButton(
                  icon: Icons.link_off,
                  size: 18,
                  tooltip: t.external_window_unbind,
                  onTap: () => unawaited(_session.bindWindow(null)),
                ),
              FushiIconButton(
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
    _maybeScheduleCaptureSetupDialog();
    if (!receivedNewLine || !follow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _maybeScheduleCaptureSetupDialog() {
    if (!mounted ||
        !widget.captureSetupEnabled ||
        !TickerMode.of(context) ||
        _captureSetupDialogOpen ||
        _captureSetupDialogScheduled) {
      return;
    }
    final GalHookSessionState state = _session.state;
    final DateTime? sessionStartedAt = state.sessionStartedAt;
    if (!shouldPromptGalCaptureSetup(
      state: state,
      hasEngineSource: _session.hasEngineSource,
      selectedTextThreadKey: _session.selectedTextThreadKey,
      textThreadCount: _session.textThreads.length,
      sessionAlreadyPrompted: _captureSetupShownForSession == sessionStartedAt,
    )) {
      return;
    }
    _captureSetupDialogScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _captureSetupDialogScheduled = false;
      if (!mounted || !widget.captureSetupEnabled || !TickerMode.of(context)) {
        return;
      }
      final GalHookSessionState latest = _session.state;
      if (latest.sessionStartedAt != sessionStartedAt ||
          !shouldPromptGalCaptureSetup(
            state: latest,
            hasEngineSource: _session.hasEngineSource,
            selectedTextThreadKey: _session.selectedTextThreadKey,
            textThreadCount: _session.textThreads.length,
            sessionAlreadyPrompted: false,
          )) {
        return;
      }
      _captureSetupShownForSession = sessionStartedAt;
      _captureSetupDialogOpen = true;
      await showAppDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) => GalCaptureSetupDialog(
          session: _session,
          onSelectThread: (TexthookerTextThread thread) =>
              _session.selectTextThread(
            thread.nativeThreadId,
            threadKey: thread.key,
            remember: true,
          ),
        ),
      );
      _captureSetupDialogOpen = false;
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
      sensitivity: ReaderFushiSource.instance.dismissSwipeSensitivity,
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
    final bool captureSetupVisible = TickerMode.of(context);
    final List<TexthookerTextThread> textThreads = _session.textThreads;
    final String? selectedTextThreadKey = _session.selectedTextThreadKey;
    final List<TexthookerLineEntry> lines = _session.workbenchLines;
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPopupOverlay());
    if (captureSetupVisible && widget.captureSetupEnabled) {
      _maybeScheduleCaptureSetupDialog();
    }
    if (widget.embedded) {
      final List<Widget> actions =
          _buildToolbarActions(context, embedded: true);
      final Widget? sectionTabs = _buildSectionTabs();
      return Column(
        children: <Widget>[
          if (sectionTabs != null)
            FushiPageHeader.customTitle(
              title: sectionTabs,
              actions: actions,
            )
          else
            FushiPageHeader(
              title: t.game_capture_workbench,
              subtitle: t.game_capture_description,
              leading: widget.onShowLibrary == null
                  ? null
                  : FushiIconButton(
                      icon: Icons.arrow_back,
                      tooltip: t.game_back_to_library,
                      onTap: widget.onShowLibrary,
                    ),
              actions: actions,
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
  /// 「兼容性诊断」入口已删——它收进游戏「设置」，工具栏再放一份纯冗余。
  List<Widget> _buildToolbarActions(
    BuildContext context, {
    required bool embedded,
  }) {
    final GalHookSessionState state = _session.state;
    String? labelOf(String value) => embedded ? value : null;
    return <Widget>[
      if (Platform.isWindows)
        FushiIconButton(
          icon: Icons.rocket_launch_outlined,
          tooltip: t.game_launch_and_capture,
          label: labelOf(t.game_launch_and_capture),
          onTap: _launchGalgameEngineHook,
        ),
      // 「游戏已经自己在跑」是和「让 Hibiki 拉起游戏」同等常见的起点（Steam / 启动器 /
      // 转区工具拉起的进程都属此列），attach 能力也一直都在，只是入口此前藏在「更多」
      // 菜单的模式开关里。两条起点并列摆出来，用户不必再为了捕获而重启游戏。
      if (Platform.isWindows)
        FushiIconButton(
          icon: Icons.cable_outlined,
          tooltip: t.game_attach_and_capture,
          label: labelOf(t.game_attach_and_capture),
          focusId: const FushiFocusId('game-toolbar-attach'),
          onTap: _attachToRunningGame,
        ),
      if (state.isActive)
        FushiIconButton(
          icon: Icons.stop_circle_outlined,
          tooltip: t.game_stop_listening,
          label: labelOf(t.game_stop_listening),
          onTap: () => unawaited(_session.stopCapture()),
        ),
      // 会话音轨面板直达入口：排除 BGM 是会话级操作，此前只能从「某一句的
      // 选轨对话框」绕进去（先随便找一句才能排除，入口藏反了）。
      if (Platform.isWindows &&
          state.isActive &&
          _session.selectedTextThreadKey != null)
        FushiIconButton(
          icon: Icons.multitrack_audio_outlined,
          tooltip: t.game_audio_tracks,
          label: labelOf(t.game_audio_tracks),
          focusId: const FushiFocusId('game-toolbar-tracks'),
          onTap: () => unawaited(_showSessionTrackPanel()),
        ),
      FushiIconButton(
        icon: Icons.delete_outline,
        tooltip: t.clear,
        label: labelOf(t.clear),
        onTap: TexthookerService.instance.clear,
      ),
      _buildToolbarOverflowMenu(context),
    ];
  }

  /// 低频开关收纳菜单：音频降级策略 / 显示 Hook 文本浮窗（Win）/ 外部窗口挖矿（Win）。
  /// 「外部窗口挖矿」是真开关，用 [CheckedPopupMenuItem] 反映当前开关态；「显示 Hook
  /// 文本浮窗」是一次性动作（showManually），用普通菜单项；「音频降级策略」是三选一
  /// （[GalAudioFallbackPolicy]），菜单项直接显示当前档位、点开是带说明的单选对话框
  /// ——三档代价各不相同（收 BGM / 丢音频 / 不出卡），不做「点一下换一档」的循环钮。
  /// onSelected 由枚举驱动，无特殊分支；各动作调用与旧按钮完全一致。
  Widget _buildToolbarOverflowMenu(BuildContext context) {
    final GalHookSessionState state = _session.state;
    return PopupMenuButton<_GalHookToolbarMenuAction>(
      key: const ValueKey<String>('game-toolbar-more'),
      tooltip: t.game_more_actions,
      icon: const Icon(Icons.more_vert),
      onSelected: (_GalHookToolbarMenuAction action) {
        switch (action) {
          case _GalHookToolbarMenuAction.audioFallback:
            unawaited(_showAudioFallbackPolicyDialog());
          case _GalHookToolbarMenuAction.health:
            unawaited(_showHealthDialog());
          case _GalHookToolbarMenuAction.showOverlay:
            unawaited(GalHookTextOverlayController.instance.showManually());
          case _GalHookToolbarMenuAction.externalWindow:
            unawaited(_toggleExternalWindowMode());
        }
      },
      itemBuilder: (BuildContext context) =>
          <PopupMenuEntry<_GalHookToolbarMenuAction>>[
        PopupMenuItem<_GalHookToolbarMenuAction>(
          value: _GalHookToolbarMenuAction.audioFallback,
          child: Text('${t.game_audio_fallback_policy} · '
              '${_audioFallbackPolicyLabel(state.audioFallbackPolicy)}'),
        ),
        // 健康状态从右栏常驻卡改为按需打开：它是「偶尔查一眼」的静态信息，
        // 不值得长期占着逐句操作要用的横向空间（完整版仍在「兼容性诊断」页签）。
        PopupMenuItem<_GalHookToolbarMenuAction>(
          value: _GalHookToolbarMenuAction.health,
          child: Text(t.game_health),
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

  /// 三档选择对话框。每档都写清代价——这不是「高级选项」，是用户每局都要按游戏
  /// 有没有逐句语音来定的判断。
  Future<void> _showAudioFallbackPolicyDialog() async {
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(t.game_audio_fallback_policy),
        content: SizedBox(
          width: 460,
          child: ListenableBuilder(
            listenable: _session,
            builder: (BuildContext context, Widget? child) {
              final GalAudioFallbackPolicy current =
                  _session.state.audioFallbackPolicy;
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (final GalAudioFallbackPolicy policy
                        in GalAudioFallbackPolicy.values)
                      RadioListTile<GalAudioFallbackPolicy>(
                        value: policy,
                        groupValue: current,
                        title: Text(_audioFallbackPolicyLabel(policy)),
                        subtitle: Text(_audioFallbackPolicyDescription(policy)),
                        onChanged: (GalAudioFallbackPolicy? picked) {
                          if (picked != null) {
                            _session.setAudioFallbackPolicy(picked);
                          }
                        },
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(t.dialog_close),
          ),
        ],
      ),
    );
  }

  String _audioFallbackPolicyLabel(GalAudioFallbackPolicy policy) =>
      switch (policy) {
        GalAudioFallbackPolicy.full => t.game_audio_fallback_full,
        GalAudioFallbackPolicy.cleanOnly => t.game_audio_fallback_clean,
        GalAudioFallbackPolicy.resourceOnly => t.game_audio_fallback_resource,
      };

  String _audioFallbackPolicyDescription(GalAudioFallbackPolicy policy) =>
      switch (policy) {
        GalAudioFallbackPolicy.full => t.game_audio_fallback_full_hint,
        GalAudioFallbackPolicy.cleanOnly => t.game_audio_fallback_clean_hint,
        GalAudioFallbackPolicy.resourceOnly =>
          t.game_audio_fallback_resource_hint,
      };

  /// 会话健康状态对话框（原右栏常驻卡的新家）。内容仍是 [_CaptureHealthCard]，
  /// 随会话状态实时刷新；Anki 配置态来自 app 级 AnkiViewModel（BUG-1007 的接线）。
  Future<void> _showHealthDialog() async {
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(t.game_health),
        content: SizedBox(
          width: 460,
          child: ListenableBuilder(
            listenable: _session,
            builder: (BuildContext context, Widget? child) =>
                SingleChildScrollView(
              child: _CaptureHealthCard(
                state: _session.state,
                endpoints: _session.endpointStatuses,
                // BUG-1007 根因修复：健康卡 Anki 行此前写死「未配置」，不反映真实
                // 配置。接 app 级 AnkiViewModel 的已配置判定（牌组 + 笔记类型均已选）。
                ankiConfigured: ref.watch(
                  ankiViewModelProvider.select(
                    (AnkiUiState uiState) => uiState.isConfigured,
                  ),
                ),
              ),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(t.dialog_close),
          ),
        ],
      ),
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
    );
  }

  Widget _buildMonitorBody(
    BuildContext context,
    List<TexthookerLineEntry> lines,
    List<TexthookerTextThread> textThreads,
    String? selectedTextThreadKey,
  ) {
    final GalHookSessionState state = _session.state;
    final GalWorkbenchReadiness readiness = galWorkbenchReadiness(
      state: state,
      hasEngineSource: _session.hasEngineSource,
      selectedTextThreadKey: selectedTextThreadKey,
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
                // 右栏改成逐句音轨面板（原「最新台词」只读卡 + 「健康状态」静态卡
                // 让位）：正文与音频元信息并进本面板，健康状态移到工具栏「更多」→
                // 对话框（同页签栏的「兼容性诊断」也有完整版），把这块常驻空间还给
                // 「听 → 判断 → 排除 BGM」这条真正需要反复操作的动线。
                final Widget lineTracks =
                    readiness == GalWorkbenchReadiness.waitingForThread
                        ? const _ThreadSelectionRequiredCard()
                        : _LineTracksCard(
                            session: _session,
                            line: _selectedOrLatestLine(lines),
                          );
                if (box.maxWidth >= 1280) {
                  return Column(
                    children: <Widget>[
                      _SessionOverviewCard(
                        state: state,
                        readiness: readiness,
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Expanded(flex: 7, child: live),
                            const SizedBox(width: 12),
                            Expanded(flex: 4, child: lineTracks),
                          ],
                        ),
                      ),
                    ],
                  );
                }
                if (box.maxWidth >= 840) {
                  return Column(
                    children: <Widget>[
                      _SessionOverviewCard(
                        state: state,
                        readiness: readiness,
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Expanded(flex: 2, child: live),
                            const SizedBox(width: 12),
                            Expanded(child: lineTracks),
                          ],
                        ),
                      ),
                    ],
                  );
                }
                // 窄屏不整块丢弃逐句音轨面板（巡检 G7），折叠成可展开区放在实时行
                // 下方，默认收起不抢纵向空间。
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _SessionOverviewCard(
                      state: state,
                      readiness: readiness,
                      compact: true,
                    ),
                    const SizedBox(height: 12),
                    Expanded(child: live),
                    ExpansionTile(
                      title: Text(t.game_line_tracks),
                      tilePadding: EdgeInsets.zero,
                      children: <Widget>[
                        // 上限高度：卡片内自带 SingleChildScrollView，超长台词/多轨
                        // 在卡内滚动而不是把实时行区挤到 0。
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 320),
                          child: lineTracks,
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
    // 重名线程（同 hookName + 地址、不同调用上下文）补 `#N` 序号，供下拉区分。
    final Map<String, String> threadDisplayLabels =
        assignThreadDisplayLabels(textThreads);
    return FushiCard(
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
                  focusId: const FushiFocusId('game-text-thread-selector'),
                  label: t.game_text_thread,
                  enabled: textThreads.isNotEmpty,
                  selected: textThreads.any(
                    (TexthookerTextThread thread) =>
                        thread.key == selectedTextThreadKey,
                  )
                      ? selectedTextThreadKey
                      : '',
                  entries: <GamepadDropdownEntry<String>>[
                    // v12：空值不再是「全部线程」——不选就一行都不发布。标签必须如实
                    // 说明，否则用户会以为不选也在抓，然后奇怪为什么没有台词。
                    (value: '', label: t.game_text_thread_unset),
                    for (final TexthookerTextThread thread in textThreads)
                      (
                        value: thread.key,
                        // 同一 hook 面在不同调用上下文会报成多条同 label 线程；
                        // assignThreadDisplayLabels 给重名线程补 `#N` 序号，避免下拉
                        // 里出现一整列一模一样的 `TextRender · 0x… · 0`。
                        // 行数用 observedLineCount（native 观测总行数）而不是已发布
                        // 行数：v12 起未被选中的线程一行都不发布，用已发布行数会让
                        // 每条候选都显示 `· 0`，用户还是没法判断该选哪条。
                        label:
                            '${threadDisplayLabels[thread.key] ?? thread.label}'
                            ' · ${thread.observedLineCount}',
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
                          // 预览优先取已发布台词，回落 native 预览行——未被选中的
                          // 线程只有后者，而那正是用户挑线程时唯一能看的东西。
                          latestText: thread.displayPreviewText,
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
                        // 用户亲自选的线程记进本游戏记忆，下次开同一个游戏自动选回。
                        remember: true,
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
                        previewingAudio: line.id == _previewingLineId,
                        // 逐行改音轨要求：会话内有 engine helper、有可选音轨快照，
                        // 且这行属于当前会话（历史会话的时间戳早已失效）。
                        canPickTrack: _session.hasEngineSource &&
                            _session.state.audioTracks.isNotEmpty &&
                            _session.isLineInCurrentSession(line),
                        canRecapture: Platform.isWindows &&
                            _session.state.isActive &&
                            _session.isLineInCurrentSession(line),
                        recapturing: _session.recapturingLineId == line.id,
                        onSelectLine: _selectLine,
                        onWordTap: _onWordTap,
                        onToggleFavorite: _toggleLineFavorite,
                        onPreviewAudio: (TexthookerLineEntry l) =>
                            unawaited(_toggleLinePreview(l)),
                        onPickTrack: (TexthookerLineEntry l) =>
                            unawaited(_pickLineTrack(l)),
                        onRecapture: (TexthookerLineEntry l) =>
                            unawaited(_toggleLineRecapture(l)),
                        onCopy: (TexthookerLineEntry l) =>
                            _appModel.copyToClipboard(l.text),
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
          FushiSelectableChip(
            label: '$label $count',
            leadingIcon: icon,
            selected: _lineFilter == filter,
            focusId: FushiFocusId('game-line-filter-${filter.name}'),
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
      // BUG-1327：对话框期间连 barrier 一起撤——浮层子树挂在根 Overlay，排在
      // showAppDialog 推的路由之上，全屏 barrier 会把落在对话框上的点击吃掉并判成
      // 「点弹窗外面」关栈。判据收口在 [shouldShowLookupDismissBarrier]。
      if (shouldShowLookupDismissBarrier(
        hasVisiblePopup: _popup.hasVisiblePopup,
        isSearching: _popup.isSearchingUi,
        hiddenByDialog: lookupPopupHiddenByDialog,
      ))
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => popNestedPopupAt(_topVisiblePopupIndex, _popup),
            onHorizontalDragStart: ReaderFushiSource.instance.enableSwipeToClose
                ? _onBarrierHorizontalDragStart
                : null,
            onHorizontalDragUpdate:
                ReaderFushiSource.instance.enableSwipeToClose
                    ? _onBarrierHorizontalDragUpdate
                    : null,
            onHorizontalDragEnd: ReaderFushiSource.instance.enableSwipeToClose
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
    return FushiAppUiScaleNeutralizer(
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
  const _SessionOverviewCard({
    required this.state,
    required this.readiness,
    this.compact = false,
  });

  final GalHookSessionState state;
  final GalWorkbenchReadiness readiness;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final bool waitingForThread =
        readiness == GalWorkbenchReadiness.waitingForThread;
    final String audio = galHookAudioBackendLabel(state.audioBackend);
    final String phase = galHookSessionPhaseLabel(state.phase);
    final String? format = state.audioFormat == null
        ? null
        : '${state.audioFormat!.sampleRate} Hz · '
            '${state.audioFormat!.channels} ch · '
            '${state.audioFormat!.bitsPerSample} bit';
    return FushiCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: <Widget>[
          Icon(
            waitingForThread
                ? Icons.forum_outlined
                : state.isActive
                    ? Icons.sensors
                    : Icons.sensors_off_outlined,
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
                  waitingForThread
                      ? t.game_session_waiting_thread
                      : state.isActive
                          ? t.game_session_listening
                          : t.game_session_idle,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  waitingForThread
                      ? '$phase · ${t.game_text_thread_unset}'
                      : compact
                          ? '$phase · $audio'
                          : '$phase · $audio'
                              '${format == null ? '' : ' · $format'}',
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                // 降级原因：优先显示结构化失败的可执行处置（「游戏以管理员身份运行，
                // 请同样以管理员身份启动 Hibiki」之类）。旧实现把 `engine_attach_failed`
                // 这种内部代码原样甩给用户，等于什么都没说。没有结构化原因时才退回代码。
                //
                // **窄屏也必须显示**：右侧 _StatusPill 在 compact 下照常亮「已降级」，
                // 若同时把原因藏掉，用户看到的就是「出事了 + 不告诉你出了什么事」，
                // 比两个都不显示更难排查。compact 要省的是次要信息（采样率/声道/位深，
                // 见上面的 format），不是唯一的诊断线索。只收窄行数，不整行丢弃。
                if (state.fallbackReason != null)
                  Text(
                    // BUG-1100：先看注入失败的可执行处置，再看降级原因自己的人话文案；
                    // 两张表都没有才回退内部代码。
                    galHookFallbackHeadline(
                      failure: state.injectorFailure,
                      fallbackReason: state.fallbackReason!,
                    ),
                    maxLines: compact ? 2 : 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.tertiary,
                        ),
                  ),
                // native 一手证据**独立一行**（BUG-1446）。这张卡以前只渲染上面那句处置，
                // 把 `injectorDetail` 整个丢了：`protocol_mismatch` 时 native 侧
                // `ProtocolMismatchDetail` 生成的**双方版本对照**（`shm=12/want 13` 之类，
                // 经 voice_hook_reader.cpp → flutter_window.cpp → injectorDetail 一路带上来）
                // 是这条失败唯一能一次确诊的事实，却恰好在用户最常盯着的位置被抹掉，
                // 只剩一句「先彻底关掉游戏再重开一次」——照做也不会好，因为真正漂开的是谁
                // 根本没显示。它必须自己占一行：上面那句处置有八十多字，缀在尾部会被
                // ellipsis 整段吃掉（compact 只有 2 行），修了等于没修。
                if (state.injectorDetail.trim().isNotEmpty)
                  Text(
                    state.injectorDetail.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                  ),
              ],
            ),
          ),
          _StatusPill(
            label: waitingForThread
                ? t.game_status_waiting
                : state.isDegraded
                    ? t.game_line_audio_fallback
                    : (state.isActive
                        ? t.game_status_ready
                        : t.game_status_waiting),
            ready: !waitingForThread && state.isActive && !state.isDegraded,
          ),
        ],
      ),
    );
  }
}

/// 未选台词线程时替代「本句音轨」面板：没有句子身份就不存在可归属的句级音频，
/// 不能继续展示一个看似已就绪的音轨工作区。
class _ThreadSelectionRequiredCard extends StatelessWidget {
  const _ThreadSelectionRequiredCard();

  @override
  Widget build(BuildContext context) {
    return FushiCard(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.multitrack_audio_outlined,
                size: 40,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 12),
              Text(
                t.game_session_waiting_thread,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                t.game_audio_requires_thread,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 逐句音轨面板：右栏的常驻主面板（取代原「最新台词」只读卡）。
///
/// 「哪条轨是 BGM」是**逐句**才能判断的事——会话级音轨快照用最近一条台词的时间戳，
/// 用户看着它排除 BGM 等于盲操作。本面板按**当前选中行自己的时间戳**取快照
/// （[GalHookSessionController.tracksForLine]），于是每条轨的片段数/能量都是这一句
/// 说话瞬间的真实情况：试听→确认是 BGM→当场排除，排除立刻对后续所有句生效并
/// 记进本游戏记忆。同时保留原「最新台词」的核心信息（正文 + 音频来源/时长），
/// 不丢可读性。
class _LineTracksCard extends StatefulWidget {
  const _LineTracksCard({required this.session, required this.line});

  final GalHookSessionController session;
  final TexthookerLineEntry? line;

  @override
  State<_LineTracksCard> createState() => _LineTracksCardState();
}

class _LineTracksCardState extends State<_LineTracksCard> {
  List<GalAudioTrack> _tracks = const <GalAudioTrack>[];

  /// 已取过快照的行 id：同一行不重复拉，换行才重取。
  String? _tracksLineId;
  bool _loading = false;
  int? _previewingSourcePtr;
  Timer? _previewResetTimer;

  @override
  void initState() {
    super.initState();
    _syncTracks();
  }

  @override
  void didUpdateWidget(_LineTracksCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTracks();
  }

  @override
  void dispose() {
    _previewResetTimer?.cancel();
    super.dispose();
  }

  Future<void> _syncTracks({bool force = false}) async {
    final TexthookerLineEntry? line = widget.line;
    if (line == null) {
      if (_tracks.isNotEmpty || _tracksLineId != null) {
        setState(() {
          _tracks = const <GalAudioTrack>[];
          _tracksLineId = null;
        });
      }
      return;
    }
    if (!force && _tracksLineId == line.id) return;
    if (_loading) return;
    _loading = true;
    final List<GalAudioTrack> tracks =
        await widget.session.tracksForLine(line.id);
    _loading = false;
    if (!mounted) return;
    setState(() {
      _tracks = tracks;
      _tracksLineId = line.id;
    });
  }

  Future<void> _preview(String lineId, GalAudioTrack track) async {
    if (_previewingSourcePtr == track.sourcePtr) {
      _previewResetTimer?.cancel();
      setState(() => _previewingSourcePtr = null);
      await DesktopAudioPlayback.stop();
      return;
    }
    final GalTrackPreview? preview =
        await widget.session.exportLineTrackPreview(lineId, track.sourcePtr);
    if (!mounted) return;
    if (preview == null) {
      FushiToast.show(
        msg: t.game_track_preview_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    final bool started = await DesktopAudioPlayback.playFile(preview.filePath);
    if (!mounted) return;
    if (!started) {
      FushiToast.show(
        msg: t.game_track_preview_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    _previewResetTimer?.cancel();
    setState(() => _previewingSourcePtr = track.sourcePtr);
    _previewResetTimer = Timer(
      Duration(milliseconds: preview.durationMs + 300),
      () {
        if (mounted) setState(() => _previewingSourcePtr = null);
      },
    );
  }

  Future<void> _useForLine(String lineId, int sourcePtr) async {
    final bool applied = await widget.session.setLineVoiceTrack(
      lineId,
      sourcePtr,
    );
    if (!mounted) return;
    FushiToast.show(
      msg: applied ? t.game_line_track_applied : t.game_line_track_failed,
      severity: applied ? ToastSeverity.success : ToastSeverity.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    final TexthookerLineEntry? line = widget.line;
    final GalHookSessionState state = widget.session.state;
    final int? lineVoicePtr =
        line == null ? null : widget.session.lineVoiceSourcePtr(line.id);
    return FushiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.graphic_eq, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t.game_line_tracks,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              FushiIconButton(
                icon: Icons.refresh,
                tooltip: t.game_refresh_tracks,
                size: 18,
                focusId: const FushiFocusId('game-line-tracks-refresh'),
                onTap: () => unawaited(_syncTracks(force: true)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (line == null)
                    Text(t.game_no_active_line)
                  else ...<Widget>[
                    // 正文 + 音频元信息：原「最新台词」卡的核心内容，不因换面板丢失。
                    Text(
                      line.text,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            height: 1.5,
                          ),
                    ),
                    const SizedBox(height: 10),
                    _MetadataRow(
                      label: t.game_health_audio,
                      value: line.audioBackend ??
                          texthookerLineAudioStatusLabel(line.audioStatus),
                    ),
                    if (line.audioDurationMs != null)
                      _MetadataRow(
                        label: t.game_audio_duration,
                        value:
                            '${(line.audioDurationMs! / 1000).toStringAsFixed(2)}s',
                      ),
                    if (line.fallbackReason != null)
                      _MetadataRow(
                        label: t.game_line_audio_fallback,
                        value: line.fallbackReason!,
                      ),
                    const Divider(height: 24),
                    Text(
                      t.game_line_tracks_hint,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 4),
                    if (_tracks.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(t.game_no_tracks),
                      )
                    else
                      for (final GalAudioTrack track in _tracks)
                        GalTrackTile(
                          track: track,
                          // 这里的「选中」是**本句**用哪条轨，不是会话级默认选源。
                          selected: lineVoicePtr == track.sourcePtr,
                          excluded: state.excludedAudioSourcePtrs
                              .contains(track.sourcePtr),
                          previewing: _previewingSourcePtr == track.sourcePtr,
                          // 逐行选轨与逐行排除都绕开「当前后端是否消费会话级选源」
                          // 那道自动门（它防的是自动误配），只要有 engine 就能用。
                          selectable: widget.session.hasEngineSource,
                          selectTooltip: t.game_line_track_use,
                          onSelect: () =>
                              unawaited(_useForLine(line.id, track.sourcePtr)),
                          onPreview: () => unawaited(_preview(line.id, track)),
                          onToggleExcluded: (bool excluded) => widget.session
                              .setTrackExcluded(track.sourcePtr, excluded),
                        ),
                  ],
                ],
              ),
            ),
          ),
        ],
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
    return FushiCard(
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
            // 窗口超分：与上面的「窗口」相邻，因为说的是同一个游戏窗口。整行在用户
            // 关掉超分 / 没在跑时自动消失，不给不关心的人制造噪音。
            const _UpscalingHealthRows(),
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

/// 健康卡里的「窗口超分」两行：状态行 + 可执行处置行。
///
/// 为什么处置要单独一行而不是塞进 `_HealthRow.value`：`value` 是 `maxLines: 1` 的右对齐
/// 短值，装不下「按 Win+Shift+A，下次启动就自动放大了」这种话。而只说「未开启」不说
/// 怎么办，正是「装完第一次没反应」变成用户报 bug 的原因。
///
/// 文案一律经 `magpie_upscaling_text.dart` 翻成人话，**绝不把 `bootstrapFailed` 这类
/// 内部枚举名甩到界面上**（同 `gal_hook_failure_text.dart` 的纪律）。
class _UpscalingHealthRows extends StatelessWidget {
  const _UpscalingHealthRows();

  @override
  Widget build(BuildContext context) {
    final MagpieUpscalingService? service =
        GalHookSessionController.instance.magpieUpscaling;
    // 没注入编排器（非 Windows / 测试替身）时整块不存在。
    if (service == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: service,
      builder: (BuildContext context, Widget? child) {
        final MagpieUpscalingReport report = service.report;
        if (!magpieUpscalingWorthShowing(report)) {
          return const SizedBox.shrink();
        }
        // 只有真的收到 Magpie 的「缩放开始」广播才算就绪。拉起了进程不等于放大了，
        // 不拿意图冒充结果。
        final bool on = report.status == MagpieUpscalingStatus.active &&
            report.scalingActive;
        final String? hint = magpieUpscalingActionHint(report);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _HealthRow(
              label: t.game_health_upscaling,
              value: magpieUpscalingStatusLabel(report),
              ready: on,
            ),
            if (hint != null)
              Padding(
                padding: const EdgeInsets.only(left: 25, bottom: 6),
                child: Text(
                  hint,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.tertiary,
                      ),
                ),
              ),
          ],
        );
      },
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
    required this.previewingAudio,
    required this.canPickTrack,
    required this.canRecapture,
    required this.recapturing,
    required this.onSelectLine,
    required this.onWordTap,
    required this.onToggleFavorite,
    required this.onPreviewAudio,
    required this.onPickTrack,
    required this.onRecapture,
    required this.onCopy,
  });

  final TexthookerLineEntry line;
  final List<String> words;
  final bool selected;

  /// 本行是否正被行内试听（播放按钮显示为停止）。
  final bool previewingAudio;

  /// 是否显示「改音轨」按钮：会话有 engine helper、有音轨快照、且本行属于当前会话。
  final bool canPickTrack;

  /// 是否显示「补录」按钮：Windows 会话进行中且本行属于当前会话。
  final bool canRecapture;

  /// 本行是否正开着补录窗口（按钮显示为停止收束）。
  final bool recapturing;
  final ValueChanged<TexthookerLineEntry> onSelectLine;
  final ValueChanged<TexthookerLineEntry> onToggleFavorite;

  /// 行内试听已配音频（仅 [TexthookerLineEntry.hasAudio] 行显示按钮）。
  final ValueChanged<TexthookerLineEntry> onPreviewAudio;

  /// 为本行单独改选语音轨（自动配对配错时的用户裁决出口）。
  final ValueChanged<TexthookerLineEntry> onPickTrack;

  /// 开/收本行补录窗口（missing/兜底行的一键补救，与浮窗「重播并录音」同出口）。
  final ValueChanged<TexthookerLineEntry> onRecapture;

  /// 把整句复制到剪贴板（用户诉求：方便丢给 AI 分析）。
  final ValueChanged<TexthookerLineEntry> onCopy;
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
      child: FushiCard(
        key: ValueKey<String>('game-line-${line.id}'),
        selected: selected,
        focusId: FushiFocusId('game-line-${line.id}'),
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
                _LineAudioChip(
                  status: line.audioStatus,
                  backend: line.audioBackend,
                  fallbackReason: line.fallbackReason,
                ),
                const SizedBox(width: 4),
                // 行内试听已配音频（用户实拍：音频就绪却听不了）。仅 hasAudio 行显示；
                // 试听中变停止钮。样式对齐收藏星。
                if (line.hasAudio) ...<Widget>[
                  FushiIconButton(
                    icon: previewingAudio
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline,
                    tooltip: previewingAudio
                        ? t.game_track_preview_stop
                        : t.game_line_preview_tooltip,
                    size: 18,
                    enabledColor: previewingAudio ? colors.primary : null,
                    focusId: FushiFocusId('game-line-preview-${line.id}'),
                    onTap: () => onPreviewAudio(line),
                  ),
                  const SizedBox(width: 4),
                ],
                // 逐行改音轨（BUG-1102）：自动选源在真机上会误选 BGM/旁白轨，
                // 用户必须能对**这一句**直接指定用哪条轨重抓。
                if (canPickTrack) ...<Widget>[
                  FushiIconButton(
                    icon: Icons.multitrack_audio_outlined,
                    tooltip: t.game_line_track_tooltip,
                    size: 18,
                    focusId: FushiFocusId('game-line-track-${line.id}'),
                    onTap: () => onPickTrack(line),
                  ),
                  const SizedBox(width: 4),
                ],
                // 行内补录：missing/兜底行的一键补救此前只在浮窗有入口，工作台里
                // 用户对着红标没有任何补救手段。录音中变停止钮（收束并落定）。
                if (canRecapture) ...<Widget>[
                  FushiIconButton(
                    icon: recapturing
                        ? Icons.stop_circle_outlined
                        : Icons.mic_none_outlined,
                    tooltip: recapturing
                        ? t.game_line_recapture_stop
                        : t.game_line_recapture,
                    size: 18,
                    enabledColor: recapturing ? colors.error : null,
                    focusId: FushiFocusId('game-line-recapture-${line.id}'),
                    onTap: () => onRecapture(line),
                  ),
                  const SizedBox(width: 4),
                ],
                FushiIconButton(
                  icon: Icons.copy_all_outlined,
                  tooltip: t.game_line_copy_tooltip,
                  size: 18,
                  focusId: FushiFocusId('game-line-copy-${line.id}'),
                  onTap: () => onCopy(line),
                ),
                const SizedBox(width: 4),
                // 会话内存态收藏星（不落 DB）；已收藏填充金黄星，未收藏描边星。
                FushiIconButton(
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
  const _LineAudioChip({
    required this.status,
    this.backend,
    this.fallbackReason,
  });

  final TexthookerLineAudioStatus status;

  /// 音频来源（engine_pcm / game_resource / system_loopback），用于把「整机混音
  /// 兜底（可能混 BGM）」从正常绿标里分出来提示。
  final String? backend;

  /// 语义化 fallbackReason（见 [kGalLineNoVoiceReason] / [kGalOverlongSliceSuspectReason]
  /// / [kGalCleanSourceSuppressedReason]）：「无配音」灰标不吓人、「超长可疑切片」亮黄
  /// 提醒、「已按策略抑制混音」如实说明是用户的策略挡掉了唯一可用音源。
  final String? fallbackReason;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    // 语义化 reason 优先于通用状态：无配音是常态不是故障；超长切片是可疑不是正常。
    if (status == TexthookerLineAudioStatus.missing &&
        fallbackReason == kGalLineNoVoiceReason) {
      return _chip(
        context,
        t.game_line_audio_no_voice,
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
      );
    }
    // 「已按干净源策略抑制」绝不能和「无配音」共用灰标：前者是「没证据」，后者是
    // 「有证据判定没配音」。混成一句会让用户以为游戏这句本来就没语音。
    if (status == TexthookerLineAudioStatus.missing &&
        fallbackReason == kGalCleanSourceSuppressedReason) {
      return Tooltip(
        message: t.game_line_audio_suppressed_hint,
        child: _chip(
          context,
          t.game_line_audio_suppressed,
          colors.secondaryContainer,
          colors.onSecondaryContainer,
        ),
      );
    }
    if (fallbackReason == kGalOverlongSliceSuspectReason) {
      return Tooltip(
        message: t.game_line_audio_overlong_hint,
        child: _chip(
          context,
          t.game_line_audio_overlong,
          colors.tertiaryContainer,
          colors.onTertiaryContainer,
        ),
      );
    }
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
    final Widget chip =
        _chip(context, appearance.$1, appearance.$2, appearance.$3);
    // loopback 是整机混音兜底：状态标签照旧，但悬停要说清「可能混入 BGM」。
    if (backend == 'system_loopback') {
      return Tooltip(message: t.game_line_audio_loopback_hint, child: chip);
    }
    return chip;
  }

  Widget _chip(
    BuildContext context,
    String label,
    Color background,
    Color foreground,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style:
            Theme.of(context).textTheme.labelSmall?.copyWith(color: foreground),
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
    // 行级焦点站点仍由外层 FushiCard 提供。
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
