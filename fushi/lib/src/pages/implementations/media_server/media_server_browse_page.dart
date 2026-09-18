import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_server_list_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_services.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart'
    show ShortcutBindingScope;
import 'package:fushi/src/shortcuts/gamepad_forwarding_action.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent, focusedEditableText;
import 'package:fushi/src/shortcuts/input_binding.dart'
    show GamepadButton, activeModifierKeys;
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/utils.dart';

export 'package:fushi/src/pages/implementations/media_server/media_server_server_list_view.dart'
    show MediaServerEntry;
export 'package:fushi/src/pages/implementations/media_server/media_server_session.dart'
    show MediaServerPlayHandler, MediaServerPlayRequest;

/// 视频页「媒体服务器」分区：服务器列表 → 服务器首页 → 库网格 / 搜索 / 详情 → 播放。
///
/// 前三层是**分区内**的嵌套 [Navigator]：分区页签始终在上方、切到别的分区再切回来
/// 栈原样保留（壳把本页 Offstage 保活），每层的滚动位置随路由存活。播放页不在
/// 这条栈里——它要压在整个 app 之上，走根 Navigator。
///
/// **返回键**：全局 `globalBack`（Escape / 手柄 B / 可绑定的鼠标侧键）在根路由不可
/// pop 时被最外层的处理器直接丢掉（`_handleGlobalBack` 的 `!nav.canPop()` 门），
/// 永远走不到本页；所以本页自己在事件冒泡路上先接一手：嵌套栈能退就退一层并消费，
/// 退到底就放行（让别的语义照旧）。三条通道各接一处：
/// - 键盘（含 Android 把手柄 B 翻译成的键事件）：[Focus.onKeyEvent]，按注册表解析
///   （没有注册表的宿主 / 测试回退成裸 Escape）；
/// - 桌面轮询手柄：[Actions] 里的 [GamepadButtonIntent]；
/// - Android 系统返回：[NavigatorPopHandler]（它自己按嵌套栈深度翻转 `canPop`）。
///
/// 本页 build 路径**不读 Riverpod**：服务器清单、播放出口、设置入口全走构造参数，
/// 宿主测试不必挂 ProviderScope。
class MediaServerBrowsePage extends StatefulWidget {
  const MediaServerBrowsePage({
    required this.navigation,
    required this.repo,
    required this.loadServers,
    this.onPlay,
    this.onOpenSettings,
    this.systemBackActive = true,
    super.key,
  });

  /// 分区页签（由视频壳传入，放服务器列表页头）。
  final Widget navigation;
  final VideoBookRepository repo;

  /// 已登录服务器清单。生产由壳从 SyncRepository 装配；测试给内存 fake。
  final Future<List<MediaServerEntry>> Function() loadServers;

  /// 播放出口。null = 生产缺省：根 Navigator push `VideoFushiPage.neutralizedRemote`。
  final MediaServerPlayHandler? onPlay;

  /// 空态「去设置添加服务器」。null = 生产缺省：push 服务设置页。
  final VoidCallback? onOpenSettings;

  /// 本页此刻是否是用户看得见的那个分区。壳用 [Offstage] 保活本页、HomePage 又用
  /// IndexedStack 保活视频 tab，而 [NavigatorPopHandler] 的 PopScope 登记在 HomePage
  /// 根路由上、不随 Offstage 失效：嵌套栈深度 > 1（单台服务器一进分区就自动进首页，
  /// 深度立刻是 2）时，用户切去别的分区 / 别的 tab 再按 Android 返回，会静默 pop 这条
  /// 看不见的栈、还与设置 tab 的 PopScope 一起被遍历。键盘 / 手柄两条通道已被壳的
  /// ExcludeFocus 隔离，只有系统返回不是焦点驱动的，所以要按可见性显式关掉。
  final bool systemBackActive;

  @override
  State<MediaServerBrowsePage> createState() => _MediaServerBrowsePageState();
}

class _MediaServerBrowsePageState extends State<MediaServerBrowsePage> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>(
    debugLabel: 'media-server-browse',
  );

  void _play(BuildContext context, MediaServerPlayRequest request) {
    final MediaServerPlayHandler? injected = widget.onPlay;
    if (injected != null) {
      injected(context, request);
      return;
    }
    Navigator.of(context, rootNavigator: true).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => VideoFushiPage.neutralizedRemote(
          info: request.info,
          repo: widget.repo,
          client: request.browser.playbackClient,
          // 与 home_video_page._openRemote 同口径：多于一个成员才建剧集面板。
          remoteCollectionMembers: request.hasCollection
              ? request.members
              : null,
          initialEpisodeIndex: request.hasCollection
              ? request.initialIndex
              : null,
        ),
      ),
    );
  }

  void _openSettings() {
    final VoidCallback? injected = widget.onOpenSettings;
    if (injected != null) {
      injected();
      return;
    }
    Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            SettingsDetailPage(destination: buildServicesDestination()),
      ),
    );
  }

  /// 嵌套栈能退一层就退，并报告是否退了。
  bool _popNested() {
    final NavigatorState? nav = _navigatorKey.currentState;
    if (nav == null || !nav.canPop()) return false;
    nav.pop();
    return true;
  }

  KeyEventResult _handleKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // 手柄键事件走 [GamepadButtonIntent] 那条通道（全局 wrapper 先把它翻成 Intent
    // 派给焦点子树），这里只管键盘，免得同一次按下被两处各退一层。
    if (GamepadButton.fromKeyEvent(event) != null) {
      return KeyEventResult.ignored;
    }
    final FushiShortcutRegistry? registry = ShortcutBindingScope.maybeOf(
      context,
    );
    final bool isBack;
    if (registry == null) {
      isBack = event.logicalKey == LogicalKeyboardKey.escape;
    } else {
      // 与 `_handleGlobalBack` 同款判据（含 IME 激活时的物理键回退，TODO-847）。
      final PhysicalKeyboardKey? imeFallbackPhysicalKey =
          focusedEditableText() == null ? event.physicalKey : null;
      isBack =
          registry.resolveKeyboard(
            event.logicalKey,
            modifiers: activeModifierKeys(),
            scope: ShortcutScope.universal,
            physicalKey: imeFallbackPhysicalKey,
          ) ==
          ShortcutAction.globalBack;
    }
    if (!isBack) return KeyEventResult.ignored;
    // 搜索框里按 Escape 是「清焦点 / 收起」的既有语义，不抢来退层。
    if (focusedEditableText() != null) return KeyEventResult.ignored;
    return _popNested() ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  bool _handleGamepad(GamepadButtonIntent intent) {
    final FushiShortcutRegistry? registry = ShortcutBindingScope.maybeOf(
      context,
    );
    final bool isBack = registry == null
        ? intent.button == GamepadButton.b
        : registry.resolveGamepad(
                intent.button,
                scope: ShortcutScope.universal,
              ) ==
              ShortcutAction.globalBack;
    if (!isBack) return false;
    return _popNested();
  }

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        // 只认「返回」；其余按钮显式转发给祖先——裸 CallbackAction 会让上溯停在
        // 本层，焦点落在分区内任一卡片时 home 的 LT/RT 换 tab 与 Y 搜索全失灵
        // （[GamepadButtonForwardingAction] 类文档与 games_library_gamepad_guard）。
        GamepadButtonIntent: GamepadButtonForwardingAction(
          ancestorContext: context,
          handle: (GamepadButton button) =>
              _handleGamepad(GamepadButtonIntent(button)),
        ),
      },
      child: Focus(
        // 纯观察层：不夺焦、不进 Tab 遍历，只在键盘事件冒泡路上看一眼。
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _handleKey,
        child: NavigatorPopHandler(
          enabled: widget.systemBackActive,
          onPopWithResult: (void _) => _popNested(),
          // 根 MaterialApp 的 HeroController 不能同时挂两个 Navigator；分区内不做
          // Hero 动画，显式断开。
          child: HeroControllerScope.none(
            child: Navigator(
              key: _navigatorKey,
              onGenerateRoute: (RouteSettings settings) =>
                  adaptivePageRoute<void>(
                    context: context,
                    settings: settings,
                    builder: (_) => MediaServerListView(
                      navigation: widget.navigation,
                      loadServers: widget.loadServers,
                      play: _play,
                      onOpenSettings: _openSettings,
                    ),
                  ),
            ),
          ),
        ),
      ),
    );
  }
}
