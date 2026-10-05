import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/sync/texthooker_ws_client.dart';
import 'package:fushi/utils.dart';

/// 游戏模块各页（首页 / 库 / 捕获工作台 / 设置 / 诊断）共享的枚举翻译映射、时间格式与
/// 子区分段导航。巡检 PR-1 收敛点：此前 `_audioBackendLabel` 三份拷贝、
/// `_formatTime` 两份拷贝、section tab 行三份拷贝，且多处枚举 `.name`
/// 直接上屏（camelCase 英文暴露给 17 语言用户）。

/// 游戏页子区。[dashboard] 是游戏模块的默认首屏（游戏首页/仪表盘），排在最前，
/// 库/工作台/诊断顺延——枚举顺序即 [HomeGamePage] 的 IndexedStack 索引顺序
/// （[importGames] 后补，只能追加在尾部，显示顺序由 [GameSectionTabs] 决定）。
enum GameSection {
  dashboard,
  library,
  monitor,
  diagnostics,
  settings,
  importGames,

  /// 游戏资源发现（与「浏览 › 发现 › 游戏」同一个生产发现页）。2026-09-27 曾随
  /// 「浏览」模块整体搬走，2026-10-01 用户拍板加回库页子标签；追加在尾部，不移动
  /// 其它子区的 IndexedStack 索引。
  discover,
}

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
  required bool lookupRiskAcceptancePending,
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
    !lookupRiskAcceptancePending &&
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

/// 游戏页签的**视觉序**（[GameSectionTabs] 与 [HomeGamePage] 的横滑切区共用同
/// 一份真相；枚举序只管 IndexedStack 索引，显示顺序在这里）：
/// * 「导入」紧挨「设置」之前——与书 / 漫画 / 视频库页的分段顺序一致
///   （三者的「导入」视图都在「设置」前一位），肌肉记忆全 app 同构；
/// * 「发现」紧挨「导入」之前，与其它库页「发现 / 来源 / 扩展 → 导入」同序。
///   与其它库页一样自己过外部发现的合规门，不靠「iOS 当前没有游戏模块」这条
///   会变的前提；游戏没有扩展系统，不设来源 / 扩展；
/// * 诊断不设页签（从「设置」进入），所以不在此序里。
final List<GameSection> kGameSectionTabOrder = <GameSection>[
  GameSection.dashboard,
  GameSection.library,
  GameSection.monitor,
  if (StoreRestrictedCapability.externalDiscovery.isAvailable)
    GameSection.discover,
  GameSection.importGames,
  GameSection.settings,
];

/// 标记「游戏模块的分区页签已由外壳画在浮动工具栏里」（[HomeGamePage] 挂）。
///
/// 游戏的七个子区各自在自己的页头主位放一份 [GameSectionTabs]；外壳改成与视频库
/// 同构的浮动工具栏（贴合内容宽的页签胶囊 + 右侧动作组）后，子区里那一份就
/// 不该再画——在本作用域下 [GameSectionTabs] 是空占位，页头只剩把动作登记给外壳
/// 动作槽的职责。子页被独立使用（不在 [HomeGamePage] 里）时没有本作用域，照常画。
class GameSectionTabsHostScope extends InheritedWidget {
  const GameSectionTabsHostScope({required super.child, super.key});

  static bool hostedOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GameSectionTabsHostScope>() !=
      null;

  @override
  bool updateShouldNotify(GameSectionTabsHostScope oldWidget) => false;
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
    this.floating = false,
    super.key,
  });

  /// 见 [LibrarySectionTabs.floating]（外壳浮动工具栏里那一份用）。
  final bool floating;

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

  /// 页签的用户可读标签（顺序真相在 [kGameSectionTabOrder]）。
  static String _labelFor(GameSection section) => switch (section) {
        GameSection.dashboard => t.game_dashboard,
        GameSection.library => t.game_library,
        // 页签用短标签「工作台」（中文顶栏标签 ≤4 字，TODO-2937 拍板）；
        // 页标题 / 设置导航项仍用全称 [game_capture_workbench]「捕获工作台」。
        GameSection.monitor => t.game_capture_workbench_tab,
        // 「导入」段与书 / 漫画 / 视频库页的「导入」视图同名同位（2026-08-13
        // 入库入口统一定案）：游戏的单件入口（选 exe）收敛在这里，不再用 FAB。
        GameSection.importGames => t.library_view_import,
        GameSection.discover => t.library_view_discover,
        GameSection.settings => t.settings,
        // 不设页签（从「设置」进入）；防御性给全称，正常不会上屏。
        GameSection.diagnostics => t.settings,
      };

  @override
  Widget build(BuildContext context) {
    // 外壳已在浮动工具栏里画了页签（[GameSectionTabsHostScope]）：子区页头里
    // 这一份留空。
    if (!floating && GameSectionTabsHostScope.hostedOf(context)) {
      return const SizedBox.shrink();
    }
    void select(GameSection section) {
      switch (section) {
        case GameSection.dashboard:
          (onSelectDashboard ??
              () => gameSectionNotifier.value = GameSection.dashboard)();
          return;
        case GameSection.library:
          onSelectLibrary();
          return;
        case GameSection.importGames:
          gameSectionNotifier.value = GameSection.importGames;
          return;
        case GameSection.discover:
          gameSectionNotifier.value = GameSection.discover;
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

    return LibrarySectionTabs<GameSection>(
      tabs: <LibrarySectionTab<GameSection>>[
        for (final GameSection section in kGameSectionTabOrder)
          LibrarySectionTab<GameSection>(
            value: section,
            label: _labelFor(section),
          ),
      ],
      // 诊断不设页签（从「设置」进入），停在诊断时高亮「设置」。
      selected: selected == GameSection.diagnostics
          ? GameSection.settings
          : selected,
      onChanged: select,
      focusIdPrefix: focusIdPrefix,
      floating: floating,
    );
  }
}
