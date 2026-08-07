import 'package:flutter/material.dart';

import 'package:fushi/src/focus/hibiki_focus_controller.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/sync/texthooker_ws_client.dart';
import 'package:fushi/utils.dart';

/// 游戏模块各页（首页 / 库 / 捕获工作台 / 设置 / 诊断）共享的枚举翻译映射、时间格式与
/// 子区分段导航。巡检 PR-1 收敛点：此前 `_audioBackendLabel` 三份拷贝、
/// `_formatTime` 两份拷贝、section tab 行三份拷贝，且多处枚举 `.name`
/// 直接上屏（camelCase 英文暴露给 17 语言用户）。

/// 游戏页子区。[dashboard] 是游戏模块的默认首屏（游戏首页/仪表盘），排在最前，
/// 库/工作台/诊断顺延——枚举顺序即 [HomeGamePage] 的 IndexedStack 索引顺序。
enum GameSection { dashboard, library, monitor, diagnostics, settings }

/// App 级游戏页子区导航。默认停在游戏首页（[GameSection.dashboard]）；原生 Hook
/// 浮窗可在主窗最小化时请求回到捕获工作台（写 [GameSection.monitor]）。
final ValueNotifier<GameSection> gameSectionNotifier =
    ValueNotifier<GameSection>(GameSection.dashboard);

/// 捕获工作台对用户可宣称的阶段。helper/音频源已启动不等于已经能消费台词：
/// 引擎会话必须先选定文本线程，之后才可能产生与该线程台词绑定的句级音频。
enum GalWorkbenchReadiness { idle, waitingForThread, listening }

GalWorkbenchReadiness galWorkbenchReadiness({
  required GalHookSessionState state,
  required bool hasEngineSource,
  required String? selectedTextThreadKey,
}) {
  if (!state.isActive) return GalWorkbenchReadiness.idle;
  if (hasEngineSource && selectedTextThreadKey == null) {
    return GalWorkbenchReadiness.waitingForThread;
  }
  return GalWorkbenchReadiness.listening;
}

/// 游戏启动后的捕获设置弹窗只在「本轮引擎会话已经发现线程，但用户尚未选定」时出现。
/// 将判定收敛为纯函数，避免 session/listener 的多次通知重复弹窗。
bool shouldPromptGalCaptureSetup({
  required GalHookSessionState state,
  required bool hasEngineSource,
  required String? selectedTextThreadKey,
  required int textThreadCount,
  required bool sessionAlreadyPrompted,
}) =>
    state.sessionStartedAt != null &&
    switch (state.phase) {
      GalHookSessionPhase.waitingSignals ||
      GalHookSessionPhase.running ||
      GalHookSessionPhase.degraded =>
        true,
      _ => false,
    } &&
    hasEngineSource &&
    selectedTextThreadKey == null &&
    textThreadCount > 0 &&
    !sessionAlreadyPrompted;

/// Hook 会话音频后端的用户可读标签。
String galHookAudioBackendLabel(GalHookAudioBackend backend) =>
    switch (backend) {
      GalHookAudioBackend.none => t.game_audio_backend_none,
      GalHookAudioBackend.gameResource => t.game_audio_backend_resource,
      GalHookAudioBackend.enginePcm => t.game_audio_backend_engine,
      GalHookAudioBackend.systemLoopback => t.game_audio_backend_loopback,
    };

/// Hook 会话阶段的用户可读标签（替代 `phase.name` 直接上屏）。
String galHookSessionPhaseLabel(GalHookSessionPhase phase) => switch (phase) {
      GalHookSessionPhase.idle => t.game_phase_idle,
      GalHookSessionPhase.resolving => t.game_phase_resolving,
      GalHookSessionPhase.launching => t.game_phase_launching,
      GalHookSessionPhase.attaching => t.game_phase_attaching,
      GalHookSessionPhase.injecting => t.game_phase_injecting,
      GalHookSessionPhase.waitingSignals => t.game_phase_waiting_signals,
      GalHookSessionPhase.running => t.game_phase_running,
      GalHookSessionPhase.degraded => t.game_phase_degraded,
      GalHookSessionPhase.stopping => t.game_phase_stopping,
      GalHookSessionPhase.error => t.game_phase_error,
    };

/// texthooker WebSocket 端点阶段的用户可读标签。
String texthookerEndpointPhaseLabel(TexthookerEndpointPhase phase) =>
    switch (phase) {
      TexthookerEndpointPhase.connecting => t.game_endpoint_phase_connecting,
      TexthookerEndpointPhase.connected => t.game_endpoint_phase_connected,
      TexthookerEndpointPhase.retrying => t.game_endpoint_phase_retrying,
      TexthookerEndpointPhase.stopped => t.game_endpoint_phase_stopped,
    };

/// 文本行来源的用户可读标签。
String texthookerLineSourceLabel(TexthookerLineSource source) =>
    switch (source) {
      TexthookerLineSource.engineHook => t.game_text_source_engine,
      TexthookerLineSource.websocket => t.game_text_source_websocket,
      TexthookerLineSource.unknown => t.game_text_source_unknown,
    };

/// 文本行句音频状态的用户可读标签。
String texthookerLineAudioStatusLabel(TexthookerLineAudioStatus status) =>
    switch (status) {
      TexthookerLineAudioStatus.pending => t.game_line_audio_pending,
      TexthookerLineAudioStatus.matched => t.game_line_audio_matched,
      TexthookerLineAudioStatus.encoded => t.game_line_audio_encoded,
      TexthookerLineAudioStatus.fallback => t.game_line_audio_fallback,
      TexthookerLineAudioStatus.missing => t.game_line_audio_missing,
      TexthookerLineAudioStatus.unavailable => t.game_line_audio_unavailable,
    };

/// 事件/行时间戳的 HH:mm:ss 时钟格式（原 `_formatTime` 两份拷贝收敛）。
String formatGameClockTime(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
}

/// 游戏模块共用的胶囊分段导航（首页 / 库 / 捕获工作台 / 设置）。
///
/// 兼容性诊断仍可从「设置」进入，但不再占据高频顶部页签；诊断详情打开时顶部
/// 高亮「设置」，明确它属于配置/排障路径。
///
/// 四个选项是一个焦点停靠点：左右方向键在控件内切换，鼠标和触摸仍可直接点某段。
/// [focusIdPrefix] 决定稳定 focusId `<prefix>-sections`，各页前缀互不冲突。
class GameSectionTabs extends StatelessWidget {
  const GameSectionTabs({
    required this.selected,
    required this.focusIdPrefix,
    required this.onSelectLibrary,
    required this.onSelectMonitor,
    this.onSelectSettings,
    this.onSelectDashboard,
    super.key,
  });

  /// 当前高亮的子区。
  final GameSection selected;

  /// focusId 前缀（如 `game-library-tab`）。
  final String focusIdPrefix;

  /// 游戏首页（仪表盘）页签回调。可空：未接线时回落到直接写
  /// [gameSectionNotifier]（[HomeGamePage] 监听该 notifier 完成导航），这样不改
  /// 捕获工作台 / 诊断页的构造签名也能让「首页」页签在三页里都工作。
  final VoidCallback? onSelectDashboard;

  final VoidCallback onSelectLibrary;
  final VoidCallback onSelectMonitor;
  final VoidCallback? onSelectSettings;

  @override
  Widget build(BuildContext context) {
    const List<GameSection> values = <GameSection>[
      GameSection.dashboard,
      GameSection.library,
      GameSection.monitor,
      GameSection.settings,
    ];
    void select(GameSection section) {
      switch (section) {
        case GameSection.dashboard:
          (onSelectDashboard ??
              () => gameSectionNotifier.value = GameSection.dashboard)();
          return;
        case GameSection.library:
          onSelectLibrary();
          return;
        case GameSection.monitor:
          onSelectMonitor();
          return;
        case GameSection.diagnostics:
          gameSectionNotifier.value = GameSection.diagnostics;
          return;
        case GameSection.settings:
          (onSelectSettings ??
              () => gameSectionNotifier.value = GameSection.settings)();
          return;
      }
    }

    return FushiAdjustableSegmented<GameSection>(
      values: values,
      selected: selected,
      onChanged: select,
      focusIdPrefix: focusIdPrefix,
      focusId: FushiFocusId('$focusIdPrefix-sections'),
      child: FushiSegmentedStrip<GameSection>(
        segments: <ButtonSegment<GameSection>>[
          ButtonSegment<GameSection>(
            value: GameSection.dashboard,
            label: Text(t.game_dashboard),
          ),
          ButtonSegment<GameSection>(
            value: GameSection.library,
            label: Text(t.game_library),
          ),
          ButtonSegment<GameSection>(
            value: GameSection.monitor,
            label: Text(t.game_capture_workbench),
          ),
          ButtonSegment<GameSection>(
            value: GameSection.settings,
            label: Text(t.settings),
          ),
        ],
        selected: selected,
        onChanged: select,
      ),
    );
  }
}
