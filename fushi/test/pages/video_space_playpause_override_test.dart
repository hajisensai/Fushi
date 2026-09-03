import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/panel_focus_scope.dart';
import 'package:fushi/src/media/video/video_player_shortcuts.dart';
import 'package:fushi/src/shortcuts/global_navigation.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 键盘通道的挂载位（负向对照靠它表达「拓扑挂错了」，而不是「干脆没挂」）。
enum _ChannelMount {
  /// 与生产 `_wrapVideoGamepadControls` 同位：窗口 `build()` 与全屏路由
  /// `pageBuilder` 的唯一共同外层。
  route,

  /// 回归形状：挂在页面 Scaffold 上——全屏路由不在它的祖先链上。
  scaffold,
}

/// 回归守卫（TODO-755 回归 c152fcd91 / BUG-1864）：面板持焦后视频快捷键失效。
///
/// 根因两层：
/// ① 全局导航层 [wrapWithGlobalNavigation] 无条件把裸空格中和成 [DoNothingIntent]
///    （`global_navigation.dart`，[DoNothingAction.consumesKey] 为 true → 真消费按键），
///    所以视频页**必须**在它之下、离视频更近的地方自己接住裸空格；
/// ② 而「接住的地方」历史上一直不是整页：先是 media_kit controls 的
///    `keyboardShortcuts`（只包 `AdaptiveVideoControls` 子树），后是页面 Scaffold 上的
///    局部覆盖（全屏是推到根 navigator 的独立路由、不经过 Scaffold）。焦点一落到那两个
///    子树之外（[PanelFocusScope] 把焦点领进剧集轨 / 侧栏就是最常见的一种），
///    裸空格就上浮到全局中和层被吞 =「按了没反应」。
///
/// 方案 D 之后键盘只剩**一个**挂载点：[_wrapVideoGamepadControls] 的
/// `Focus.onKeyEvent` → press-time 的 [resolveVideoKeyboardShortcut]。它是窗口
/// `build()` 与全屏路由 `pageBuilder` 的唯一共同外层，也是所有子焦点节点的共同祖先，声明的作用域
/// （[ShortcutScope.video]，整页）第一次与物理挂载点对齐。
///
/// [VideoFushiPage] 驱动 media_kit、无法离屏整页 widget 测试，故本测试用与真实拓扑同构
/// 的最小 widget 树 + **生产的判决函数与真注册表默认绑定**（不在测试里另写一份键位）。
void main() {
  // 全局导航层在生产里挂在 `MaterialApp.builder`（见 `main.dart`），也就是 Navigator 的
  // **祖先**——推到根 navigator 的全屏路由同样在它之下。测试里必须用同一个挂载位，否则
  // 「裸空格冒到 _neutralizeBareSpace 被吞」这个负向对照的机制根本不成立（用 `home:` 时
  // 全局层落在 Navigator 之内，全屏路由压根看不见它，空 log 是别的原因造成的）。
  Widget appWithGlobalNavigation({
    required GlobalKey<NavigatorState> navKey,
    required Widget home,
  }) {
    return MaterialApp(
      navigatorKey: navKey,
      builder: (BuildContext context, Widget? child) =>
          wrapWithGlobalNavigation(navigatorKey: navKey, child: child!),
      home: home,
    );
  }

  FushiShortcutRegistry defaults() =>
      FushiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

  /// 复刻生产 [_handleVideoKeyboardShortcut]：取页面态 → 问
  /// [resolveVideoKeyboardShortcut] → 按判决执行。测试只提供页面态，判据一律走
  /// 生产纯函数。
  KeyEventResult Function(FocusNode, KeyEvent) videoKeyboardChannel({
    required FushiShortcutRegistry registry,
    required List<ShortcutAction> log,
    bool videoNavigablePanelOpen = false,
    bool videoSurfaceHoldsFocus = false,
  }) {
    return (FocusNode node, KeyEvent event) {
      final VideoKeyboardResolution resolution = resolveVideoKeyboardShortcut(
        registry,
        event,
        modifiers: currentKeyboardModifiers(HardwareKeyboard.instance),
        hasEditableFocus: false,
        hasVisiblePopup: false,
        videoSurfaceHoldsFocus: videoSurfaceHoldsFocus,
        videoNavigablePanelOpen: videoNavigablePanelOpen,
      );
      switch (resolution.dispatch) {
        case VideoKeyboardDispatch.swallowRepeat:
          return KeyEventResult.handled;
        case VideoKeyboardDispatch.ignore:
          return KeyEventResult.ignored;
        case VideoKeyboardDispatch.dismissPopup:
          return KeyEventResult.handled;
        case VideoKeyboardDispatch.run:
          log.add(resolution.action!);
          return KeyEventResult.handled;
      }
    };
  }

  /// 复刻真实拓扑：全局导航层（裸空格 → DoNothingIntent）在外，页级键盘通道在内，
  /// 最里是一个普通可聚焦子节点（**不是**视频画面节点）。[pageLevelChannel] 为 false
  /// 时去掉页级通道，用作「未修复 = 被全局吞掉」的负向对照。
  Future<List<ShortcutAction>> pumpAndCollect(
    WidgetTester tester, {
    required bool pageLevelChannel,
  }) async {
    final List<ShortcutAction> log = <ShortcutAction>[];
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FocusNode genericNode = FocusNode(debugLabel: 'generic-not-video');
    addTearDown(genericNode.dispose);

    Widget child = Focus(
      focusNode: genericNode,
      child: const SizedBox(width: 100, height: 100),
    );
    if (pageLevelChannel) {
      child = Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: videoKeyboardChannel(registry: defaults(), log: log),
        child: child,
      );
    }

    await tester.pumpWidget(
      appWithGlobalNavigation(
        navKey: navKey,
        home: Scaffold(body: Center(child: child)),
      ),
    );

    // 关键：不调任何「视频节点」的 requestFocus；焦点只落在一个普通子节点上，
    // 模拟「焦点在视频页子树内但不精确在 _videoFocusNode」的真实使用路径。
    genericNode.requestFocus();
    await tester.pump();
    expect(genericNode.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    return log;
  }

  testWidgets(
    '页级键盘通道在焦点不精确落在视频节点时仍触发播放/暂停（修复）',
    (WidgetTester tester) async {
      expect(
        await pumpAndCollect(tester, pageLevelChannel: true),
        <ShortcutAction>[ShortcutAction.videoTogglePlayPause],
        reason: '焦点落在视频页子树任意节点上时，裸空格必须先被页级通道解析成 '
            'videoTogglePlayPause，永不下沉到全局 DoNothingIntent',
      );
    },
  );

  testWidgets(
    '负向对照：没有页级通道时裸空格被全局 DoNothingIntent 吞掉（复现回归）',
    (WidgetTester tester) async {
      expect(
        await pumpAndCollect(tester, pageLevelChannel: false),
        isEmpty,
        reason: '撤掉页级通道即回归 c152fcd91：裸空格被全局中和层吞掉，'
            '视频「按了没反应」',
      );
    },
  );

  /// BUG-1864 的真实拓扑复刻：**全屏是推到根 navigator 的独立路由**，页面 Scaffold
  /// 不在它的祖先链上。路由内容里挂真的 [PanelFocusScope]——它正是剧集轨 / 侧栏
  /// 打开时把焦点从视频画面抢走的那个组件（字幕列表自 BUG-2040 起不再领焦点）。
  ///
  /// [mount] 决定**那唯一一份键盘通道挂在哪**。两个取值下通道都真实存在、真实接线，
  /// 差别只有挂载位：
  /// · [_ChannelMount.route] = 修复后的形状（与生产 `_wrapVideoGamepadControls` 同位，
  ///   窗口 `build()` 与全屏路由 `pageBuilder` 共用）；
  /// · [_ChannelMount.scaffold] = 回归形状（挂在页面 Scaffold 上）。负向对照要证的是
  ///   **「Scaffold 不在全屏路由的祖先链上」这个拓扑事实**；若改成「路由里干脆不挂
  ///   handler」，证到的只是「没接线就没动作」——那条恒真，换成任何实现都还是绿的。
  ///
  /// [enterFullscreen] 为 false 时不推路由，面板直接留在 Scaffold 里，用作**装置活性
  /// 自证**：同一个 [_ChannelMount.scaffold] 挂载在不进全屏时必须产出**非空** log。
  /// 少了这一条，负向用例的「空 log」就不再是证据——键名写错、判决函数整个不工作、面板
  /// 没抢到焦点，都会给出同一个空。
  Future<List<ShortcutAction>> pumpFullscreenRouteAndCollect(
    WidgetTester tester, {
    required _ChannelMount mount,
    bool enterFullscreen = true,
  }) async {
    final List<ShortcutAction> log = <ShortcutAction>[];
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

    Widget withChannel(Widget child) => Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: videoKeyboardChannel(
            registry: defaults(),
            log: log,
            // 面板开着 —— 但空格不是焦点导航键，不该受让位影响。
            videoNavigablePanelOpen: true,
          ),
          child: child,
        );

    Widget panel() => PanelFocusScope(
          visible: true,
          child: Material(
            child: TextButton(
              onPressed: () {},
              child: const Text('面板里的按钮'),
            ),
          ),
        );

    // 面板住在哪：进全屏时住在路由里（Scaffold 只剩空壳），不进全屏时就住在 Scaffold。
    Widget scaffoldBody = enterFullscreen ? const SizedBox.expand() : panel();
    if (mount == _ChannelMount.scaffold) {
      scaffoldBody = withChannel(scaffoldBody);
    }
    await tester.pumpWidget(
      appWithGlobalNavigation(
        navKey: navKey,
        home: Scaffold(body: scaffoldBody),
      ),
    );

    if (enterFullscreen) {
      // 全屏：推到 root navigator 的独立路由（与 fullscreen.part.dart 同构）。
      unawaited(
        navKey.currentState!.push<void>(
          PageRouteBuilder<void>(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, __, ___) => mount == _ChannelMount.route
                ? withChannel(panel())
                : panel(),
          ),
        ),
      );
    }
    await tester.pumpAndSettle();

    // PanelFocusScope 自己把焦点移进面板（不在测试里手动 requestFocus 视频节点），
    // 这正是用户「打开右侧字幕列表后按空格」的真实焦点归属。
    expect(
      FocusManager.instance.primaryFocus?.context?.widget,
      isNotNull,
      reason: '面板打开后焦点必须落在面板内某个可聚焦节点上',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    return log;
  }

  testWidgets(
    'BUG-1864：全屏路由内面板持焦时裸空格仍触发播放/暂停（修复）',
    (WidgetTester tester) async {
      expect(
        await pumpFullscreenRouteAndCollect(tester, mount: _ChannelMount.route),
        <ShortcutAction>[ShortcutAction.videoTogglePlayPause],
        reason: '键盘通道挂到窗口/全屏共用的 wrapper 后，全屏下打开字幕列表'
            '（PanelFocusScope 抢焦）按空格必须照常播放/暂停',
      );
    },
  );

  testWidgets(
    'BUG-1864 负向对照：同一份通道挂在 Scaffold 上时全屏路由够不到它（真拓扑）',
    (WidgetTester tester) async {
      expect(
        await pumpFullscreenRouteAndCollect(
          tester,
          mount: _ChannelMount.scaffold,
        ),
        isEmpty,
        reason: '通道接线完全相同，只是挂在页面 Scaffold 上——而全屏是推到根 navigator '
            '的独立路由，Scaffold 不在它的祖先链上。裸空格因此一路冒到全局 '
            '_neutralizeBareSpace 被吞，「按了没反应」= BUG-1864 原样复现',
      );
    },
  );

  testWidgets(
    'BUG-1864 活性自证：同一个 Scaffold 挂载在不进全屏时必须产出非空',
    (WidgetTester tester) async {
      expect(
        await pumpFullscreenRouteAndCollect(
          tester,
          mount: _ChannelMount.scaffold,
          enterFullscreen: false,
        ),
        <ShortcutAction>[ShortcutAction.videoTogglePlayPause],
        reason: '这条一旦也变成空，上面那条负向用例的「空 log」就不再是「够不到通道」'
            '的证据，而只是「这套装置本来就产不出东西」——负向对照必须自带活性证明',
      );
    },
  );

  /// 方案 D 的另一半：整张表上提到页级之后，**方向键**在面板持焦时必须让位给通用焦点
  /// 遍历，否则用户一开字幕列表就再也用不了上下键选行（方向键在注册表里绑着 seek /
  /// 音量）。这是手柄侧 `isVideoPanelFocusNavButton` 的键盘对应物。
  Future<({List<ShortcutAction> log, bool focusMoved})>
      pumpPanelArrowAndCollect(
    WidgetTester tester, {
    required bool videoNavigablePanelOpen,
  }) async {
    final List<ShortcutAction> log = <ShortcutAction>[];
    final FocusNode first = FocusNode(debugLabel: 'panel-row-1');
    final FocusNode second = FocusNode(debugLabel: 'panel-row-2');
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: videoKeyboardChannel(
            registry: defaults(),
            log: log,
            videoNavigablePanelOpen: videoNavigablePanelOpen,
          ),
          child: Material(
            child: Column(
              children: <Widget>[
                TextButton(
                  focusNode: first,
                  onPressed: () {},
                  child: const Text('行 1'),
                ),
                TextButton(
                  focusNode: second,
                  onPressed: () {},
                  child: const Text('行 2'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    first.requestFocus();
    await tester.pump();
    expect(first.hasPrimaryFocus, isTrue, reason: '前置条件：焦点先落在面板第一行');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    return (log: log, focusMoved: second.hasPrimaryFocus);
  }

  testWidgets('面板持焦：裸方向键让位给焦点遍历，不解析成音量', (WidgetTester tester) async {
    final ({List<ShortcutAction> log, bool focusMoved}) r =
        await pumpPanelArrowAndCollect(tester, videoNavigablePanelOpen: true);
    expect(r.log, isEmpty, reason: '面板持焦时裸 ↓ 不得被解析成 videoVolumeDown');
    expect(r.focusMoved, isTrue,
        reason: '不消费 → 冒泡到 WidgetsApp 的 DirectionalFocusIntent，焦点应移到下一行');
  });

  testWidgets('负向对照：没有面板时裸方向键照常调音量、焦点不动', (WidgetTester tester) async {
    final ({List<ShortcutAction> log, bool focusMoved}) r =
        await pumpPanelArrowAndCollect(
            tester, videoNavigablePanelOpen: false);
    expect(r.log, <ShortcutAction>[ShortcutAction.videoVolumeDown],
        reason: '没有面板时方向键仍是视频动作——让位判据必须真的由面板态驱动，'
            '而不是无条件放行（那等于把方向键从视频快捷键里删掉）');
    expect(r.focusMoved, isFalse, reason: '被消费掉就不该再触发焦点遍历');
  });

  test('视频快捷键的唯一键盘挂载点是窗口/全屏共用的 wrapper（源码守卫）', () {
    final String src = readVideoFushiSource();

    // ① press-time 派发方法存在，且判据走生产纯函数（不在页面里另写一份解析）。
    // 方法体用 [methodBody] 括号配对取，不再手搓 `indexOf('\n  }')`：那个锚点被
    // 方法体里任意一个 2 空格缩进的闭合花括号（switch 的 case 体、闭包）截断在中途，
    // 后面的断言就在**残缺窗口**上跑，红绿都不代表实现。
    final String body = methodBody(src, 'bool _handleVideoKeyboardShortcut(');
    expect(containsIdentifierCall(body, 'resolveVideoKeyboardShortcut'), isTrue,
        reason: '判据必须走生产纯函数，页面不得另写一份键位解析');
    expect(containsIdentifierCall(body, 'videoActionCallbacks'), isTrue,
        reason: '执行体必须与手柄通道共用 videoActionCallbacks，两条通道行为才一致');
    expect(containsCodeLine(body, '_videoNavigablePanelOpen'), isTrue,
        reason: '面板态必须喂进判决，否则方向键在面板里不会让位给焦点遍历');
    expect(containsCodeLine(body, '_videoFocusNode.hasPrimaryFocus'), isTrue,
        reason: '画面持焦是 videoEnterCaret 放行判据 + 面板让位前提的共同输入，不能省');
    expect(
        containsCodeLine(
            body, 'hasEditableFocus: focusedEditableText() != null'),
        isTrue,
        reason: 'BUG-962：文本框持焦判据必须真的接进判决输入。纯函数那半是对的，'
            '页面不喂这个参数就等于没有——而现在**整张表**都过这条通道，'
            '它一坏就是在 mpv.conf / 弹幕规则框里打 f 直接切全屏，'
            '不再是旧实现那样「最多打不出空格」');

    // ①' 加载态可达性：controller 的必要性必须落在**执行点**，不得在入口把整条通道
    // 关掉。整条关掉时 `_controller == null`（转圈 / 资源缺失）下连 globalBack 都不再
    // 经本页解析，逐级退出阶梯不走、落到全局 universal 兜底，而 _buildLoadingBody 专门
    // 留了「转圈时随时可退出」的返回入口——那条可达性在键盘上就断了。
    final String masked = maskComments(body);
    final int resolveAt = masked.indexOf('resolveVideoKeyboardShortcut(');
    final int escapeAt = masked.indexOf('_handleVideoEscapeAction()');
    final int nullGate =
        masked.indexOf('if (controller == null) return false;');
    expect(nullGate, greaterThanOrEqualTo(0),
        reason: '需要 controller 的动作仍必须有一道门，不能解析出来就直接空指针');
    expect(resolveAt, lessThan(nullGate),
        reason: '解析必须无条件先做：controller 门提到 resolve 之前 = 加载态整条通道关闭');
    expect(escapeAt, greaterThanOrEqualTo(0),
        reason: 'globalBack 的执行体必须能在没有 controller 时单独调到'
            '（_handleVideoEscapeAction，整表里唯一不碰播放器的动作）');
    expect(escapeAt, lessThan(nullGate),
        reason: 'globalBack 分流必须排在 controller 门之前，否则加载态 Esc 仍走不到'
            '本页退出阶梯');

    // ② 挂载点必须是 [_wrapVideoGamepadControls]——窗口 build() 与全屏路由
    // pageBuilder 的**唯一共同外层**。挂在 _buildScaffold 上时全屏路由（推到根
    // navigator 的独立路由）根本没有这层（BUG-1864）。
    final String wrapper = methodBody(src, 'Widget _wrapVideoGamepadControls(');
    expect(containsCodeLine(wrapper, '_handleVideoKeyboardShortcut(event)'),
        isTrue,
        reason: '键盘通道必须挂在窗口/全屏共用的 _wrapVideoGamepadControls 内，'
            '否则全屏路径没有快捷键（BUG-1864 回归）');

    // ③ 全屏路由的 pageBuilder 必须真的走这个 wrapper（BUG-697 已确立的边界）。
    // 窗口由括号配对给出（[namedArgumentValues]），不再是 `substring(at, at + 200)`
    // 那种定长窗口——包装器名字一变长、实参多折一行，定长窗口就凭空变假。
    final List<String> pageBuilders = namedArgumentValues(src, 'pageBuilder');
    expect(pageBuilders, hasLength(1),
        reason: '合并语料里应当只有全屏路由这一个 pageBuilder；多出一个说明有第二条'
            '全屏路径，本守卫钉不住它');
    expect(containsIdentifierCall(pageBuilders.single,
            '_wrapVideoGamepadControls'),
        isTrue,
        reason: '全屏路由内容必须包进同一个 _wrapVideoGamepadControls，'
            '窗口与全屏的键盘/手柄语义才一致');

    // ④ 按住倍速的 keyup 边沿必须排在主通道之前——主通道只看按下 / 重复沿，松开沿
    // 只有 _handleHoldSpeedKey 认；顺序反了就永远卡在加速态。注释必须先剥掉：这段
    // wrapper 的注释里逐字提到了两个方法名。
    final String maskedWrapper = maskComments(wrapper);
    final int holdAt = maskedWrapper.indexOf('_handleHoldSpeedKey(event)');
    final int mainAt =
        maskedWrapper.indexOf('_handleVideoKeyboardShortcut(event)');
    expect(holdAt, greaterThanOrEqualTo(0), reason: 'wrapper 里缺按住倍速分支');
    expect(holdAt, lessThan(mainAt), reason: '按住倍速必须排在主通道之前');
  });
}
