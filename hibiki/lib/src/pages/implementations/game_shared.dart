import 'package:flutter/material.dart';

import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';
import 'package:hibiki/utils.dart';

/// 游戏模块三页（库 / 捕获工作台 / 诊断）共享的枚举翻译映射、时间格式与
/// 子区导航 tab 行。巡检 PR-1 收敛点：此前 `_audioBackendLabel` 三份拷贝、
/// `_formatTime` 两份拷贝、section tab chip 行三份拷贝，且多处枚举 `.name`
/// 直接上屏（camelCase 英文暴露给 17 语言用户）。

/// 游戏页子区。[dashboard] 是游戏模块的默认首屏（游戏首页/仪表盘），排在最前，
/// 库/工作台/诊断顺延——枚举顺序即 [HomeGamePage] 的 IndexedStack 索引顺序。
enum GameSection { dashboard, library, monitor, diagnostics }

/// App 级游戏页子区导航。默认停在游戏首页（[GameSection.dashboard]）；原生 Hook
/// 浮窗可在主窗最小化时请求回到捕获工作台（写 [GameSection.monitor]）。
final ValueNotifier<GameSection> gameSectionNotifier =
    ValueNotifier<GameSection>(GameSection.dashboard);

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

/// 游戏模块三页共用的子区导航 chip 行（库 / 捕获工作台 / 诊断）。
///
/// [focusIdPrefix] 决定三枚 chip 的 focusId（`<prefix>-library` /
/// `<prefix>-capture` / `<prefix>-diagnostics`），三页各用自己的前缀，
/// 焦点 id 不冲突且与既有集成测试的 id 兼容。
class GameSectionTabs extends StatelessWidget {
  const GameSectionTabs({
    required this.selected,
    required this.focusIdPrefix,
    required this.onSelectLibrary,
    required this.onSelectMonitor,
    required this.onSelectDiagnostics,
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
  final VoidCallback onSelectDiagnostics;

  @override
  Widget build(BuildContext context) {
    return HorizontalDragScrollable(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            HibikiSelectableChip(
              label: t.game_dashboard,
              leadingIcon: Icons.dashboard_outlined,
              selected: selected == GameSection.dashboard,
              focusId: HibikiFocusId('$focusIdPrefix-dashboard'),
              onSelected: (_) => (onSelectDashboard ??
                  () => gameSectionNotifier.value = GameSection.dashboard)(),
            ),
            const SizedBox(width: 8),
            HibikiSelectableChip(
              label: t.game_library,
              leadingIcon: Icons.sports_esports_outlined,
              selected: selected == GameSection.library,
              focusId: HibikiFocusId('$focusIdPrefix-library'),
              onSelected: (_) => onSelectLibrary(),
            ),
            const SizedBox(width: 8),
            HibikiSelectableChip(
              label: t.game_capture_workbench,
              leadingIcon: Icons.sensors_outlined,
              selected: selected == GameSection.monitor,
              focusId: HibikiFocusId('$focusIdPrefix-capture'),
              onSelected: (_) => onSelectMonitor(),
            ),
            const SizedBox(width: 8),
            HibikiSelectableChip(
              label: t.game_diagnostics,
              leadingIcon: Icons.monitor_heart_outlined,
              selected: selected == GameSection.diagnostics,
              focusId: HibikiFocusId('$focusIdPrefix-diagnostics'),
              onSelected: (_) => onSelectDiagnostics(),
            ),
          ],
        ),
      ),
    );
  }
}
