/// 窗口全屏**收窄到内容模块**这条规则的守卫（用户裁定）。
///
/// 规则有三条，缺一条就会退化成一个可以把人锁死在全屏里的功能：
///   ① 只有内容模块（小说 / 漫画 / 视频）能**进入**窗口全屏；
///   ② 退出永远放行——门若对称，用户在内容页进全屏、退回首页后就再没有出口，
///      桌面全屏是 runner 自绘的保边框巨窗，系统不提供第二个退出方式；
///   ③ 最后一个宿主离场时把全屏还回去，且判定必须推到帧末（`pushReplacement`
///      换集时旧页 dispose 与新页挂载同帧，当场判会把全屏闪掉）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/window_fullscreen_hosts.dart';

import '../helpers/source_guard.dart';

void main() {
  setUp(WindowFullscreenHosts.debugReset);
  tearDown(WindowFullscreenHosts.debugReset);

  group('宿主注册表', () {
    test('没有宿主时不可见', () {
      expect(WindowFullscreenHosts.hasVisibleHost, isFalse);
    });

    test('route 为 null 的宿主视为可见', () {
      // 页面没被 push 成路由（widget 测试直接 pumpWidget 的宿主）时，它就是当前
      // UI，没有「被别的整页盖住」这回事。
      final Object token = Object();
      WindowFullscreenHosts.register(token, null);
      expect(WindowFullscreenHosts.hasVisibleHost, isTrue);
      WindowFullscreenHosts.unregister(token);
      expect(WindowFullscreenHosts.hasVisibleHost, isFalse);
    });

    test('同一 token 重复登记是更新而不是堆积', () {
      // 路由会随 didChangeDependencies 重算，同一个宿主必须覆盖自己那条登记；
      // 堆积的话第一次 unregister 清不干净，宿主离场后全屏永远还不回去。
      final Object token = Object();
      WindowFullscreenHosts.register(token, null);
      WindowFullscreenHosts.register(token, null);
      expect(WindowFullscreenHosts.debugHostCount, 1);
      WindowFullscreenHosts.unregister(token);
      expect(WindowFullscreenHosts.debugHostCount, 0);
    });
  });

  group('WindowFullscreenHost widget', () {
    testWidgets('挂载即登记、卸载即注销', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: WindowFullscreenHost(child: SizedBox.shrink()),
        ),
      );
      expect(WindowFullscreenHosts.hasVisibleHost, isTrue);

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      expect(WindowFullscreenHosts.hasVisibleHost, isFalse);
    });

    testWidgets('宿主被另一个整页路由盖住时不再可见', (WidgetTester tester) async {
      // 这条是「收窄」的核心判据：宿主还在栈里 ≠ 宿主在最上面。从阅读器 push 一个
      // 设置页之后，用户看到的是设置页，此时按全屏键不该把窗口变成全屏。
      final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          home: const WindowFullscreenHost(child: SizedBox.shrink()),
        ),
      );
      expect(WindowFullscreenHosts.hasVisibleHost, isTrue);

      unawaitedPush(navKey);
      await tester.pumpAndSettle();
      expect(
        WindowFullscreenHosts.hasVisibleHost,
        isFalse,
        reason: '宿主被整页路由盖住后，全屏键不该还能进入全屏',
      );

      navKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(
        WindowFullscreenHosts.hasVisibleHost,
        isTrue,
        reason: '盖在上面的页面退掉后，宿主重新成为栈顶，全屏键该恢复',
      );
    });
  });

  group('源码守卫', () {
    final String navSrc = File(
      'lib/src/shortcuts/global_navigation.dart',
    ).readAsStringSync();

    test('全屏快捷键的执行体读宿主声明，且只门住「进入」', () {
      final String toggle = methodBody(
        navSrc,
        'Future<void> _toggleWindowFullscreen() async {',
      );
      expect(
        toggle,
        contains('WindowFullscreenHosts.hasVisibleHost'),
        reason: '进入全屏必须由内容页的宿主声明门控，而不是页面清单 if 阶梯',
      );
      expect(
        toggle,
        contains('readDesktopWindowFullscreen()'),
        reason: '非宿主页面按全屏键时要读一次真值，才能判断这是不是一次「退出」',
      );
      expect(
        toggle,
        contains('toggleDesktopWindowFullscreen()'),
        reason: '真正的切换仍须委托给单一 native 窗口所有者',
      );
    });

    test('退出全屏的原语不看宿主，只看真值', () {
      // 对称的门 = 把用户锁死在全屏里。这条断言钉的就是「退出路径上没有宿主判据」。
      final String exit = methodBody(
        navSrc,
        'Future<bool> exitWindowFullscreenIfActive() async {',
      );
      expect(
        exit,
        isNot(contains('hasVisibleHost')),
        reason: '退出全屏必须无条件放行，一旦加上宿主门用户就再也退不出来',
      );
      expect(exit, contains('setDesktopWindowFullscreen(false)'));
    });

    test('四个内容页都声明了自己是宿主', () {
      const Map<String, String> hosts = <String, String>{
        '小说': 'lib/src/pages/implementations/reader_fushi_page.dart',
        '漫画': 'lib/src/media/manga/reader/manga_fushi_page.dart',
        '视频': 'lib/src/pages/implementations/video_fushi_page.dart',
        '网页流媒体': 'lib/src/pages/implementations/web_video_fushi_page.dart',
      };
      for (final MapEntry<String, String> entry in hosts.entries) {
        final String src = maskComments(File(entry.value).readAsStringSync());
        expect(
          src,
          contains('WindowFullscreenHost('),
          reason: '${entry.key}页没有声明全屏宿主，它的全屏键会被门掉',
        );
      }
    });

    test('宿主离场时的归还判定推到帧末', () {
      // 当场判 = 每次 pushReplacement 换集都把全屏闪掉一次（BUG-839 场景）。
      final String hostSrc = maskComments(
        File('lib/src/shortcuts/window_fullscreen_hosts.dart')
            .readAsStringSync(),
      );
      final String release = methodBody(
        hostSrc,
        'void _releaseWindowFullscreenIfNoHostLeft() {',
      );
      expect(
        release,
        contains('addPostFrameCallback'),
        reason: '同帧内 dispose→挂载 的换集场景要求判定发生在帧末',
      );
      expect(release, contains('exitWindowFullscreenIfActive()'));
    });

    test('小说页底栏有全屏按钮，Esc 先退全屏再退书', () {
      final String chrome = maskComments(
        File('lib/src/pages/implementations/reader_fushi/chrome.part.dart')
            .readAsStringSync(),
      );
      expect(
        chrome,
        contains("ValueKey<String>('fushi_reader_fullscreen_button')"),
        reason: '小说页此前没有任何全屏入口，收窄后必须补一个看得见的',
      );

      final String caret = maskComments(
        File('lib/src/pages/implementations/reader_fushi/caret.part.dart')
            .readAsStringSync(),
      );
      expect(
        caret,
        contains('_exitWindowFullscreenOrPopReader()'),
        reason: '用户裁定 Esc 也要能退全屏：退书之前必须先过全屏这一级',
      );
    });

    test('小说页底栏全屏图标的镜像三条路径都同步', () {
      // 镜像型 bool 的经典塌法：只有「自己那条成功路径」会复位，其余入口改了状态它
      // 一无所知，于是图标停在一个稳定的错值上、而且不会自愈。这里把三条会改变窗口
      // 全屏状态的路径各钉一条：
      //   ① 进页 —— 在别处进的全屏里打开本书，镜像默认 false 就是错的；
      //   ② 底栏按钮 —— 自己那条路；
      //   ③ Esc 阶梯 —— 退的是同一个全屏，不复位图标就撒谎。
      final String chrome = maskComments(
        File('lib/src/pages/implementations/reader_fushi/chrome.part.dart')
            .readAsStringSync(),
      );

      final String initial = methodBody(
        chrome,
        'Future<void> _readInitialWindowFullscreenState() async {',
      );
      expect(
        initial,
        contains('readDesktopWindowFullscreen()'),
        reason: '① 进页必须问一次 native 真值，而不是相信镜像的初值',
      );
      expect(initial, contains('_isWindowFullscreen = fullscreen'));

      final String change = methodBody(
        chrome,
        'Future<void> _changeReaderWindowFullscreen() async {',
      );
      expect(
        change,
        contains('_isWindowFullscreen = applied'),
        reason: '② 按钮那条路必须按 native 回读的实际结果更新镜像',
      );

      final String esc = methodBody(
        chrome,
        'Future<void> _exitWindowFullscreenOrPopReader() async {',
      );
      expect(
        esc,
        contains('_isWindowFullscreen = false'),
        reason: '③ Esc 退掉全屏后图标必须跟着回到「进入全屏」，否则它稳定撒谎',
      );
    });

    test('小说页进页时真的会去读一次全屏真值', () {
      // 上一条只证明 helper 写对了；这条证明它**被调用**——helper 存在但没人调，
      // 是同一个 bug 的另一种活法。
      final String page = maskComments(
        File('lib/src/pages/implementations/reader_fushi_page.dart')
            .readAsStringSync(),
      );
      final int idxInit = page.indexOf('void initState() {');
      expect(idxInit, isNonNegative, reason: 'initState 锚点没了，守卫失去判据');
      final int idxDispose = page.indexOf('void dispose() {', idxInit);
      expect(idxDispose, greaterThan(idxInit));
      final int idxCall =
          page.indexOf('_readInitialWindowFullscreenState()', idxInit);
      expect(
        idxCall,
        inInclusiveRange(idxInit, idxDispose),
        reason: '初次读取必须发生在 initState 里，否则第一帧的图标就是错的',
      );
      expect(
        page.indexOf('desktopWindowFullscreenSupported', idxInit),
        lessThan(idxCall),
        reason: '移动端没有可全屏的窗口，这次读取必须被桌面门控挡住',
      );
    });

    test('漫画页的返回阶梯不再只认「自己进的」全屏', () {
      // 用户用 F11 进的全屏不会置所有权标志，但在他眼里那和按钮进的是同一个全屏，
      // Esc 都该先退它，而不是连人带全屏一起退出漫画。
      final String manga = maskComments(
        File('lib/src/media/manga/reader/manga_fushi_page.dart')
            .readAsStringSync(),
      );
      final String exitBeforePop = methodBody(
        manga,
        'Future<bool> _exitOwnedFullscreenBeforePop() async {',
      );
      expect(exitBeforePop, contains('readDesktopWindowFullscreen()'));
    });
  });
}

/// 往栈上推一个**整页**路由（不是弹层）：模拟「从内容页进设置页」。
void unawaitedPush(GlobalKey<NavigatorState> navKey) {
  navKey.currentState!.push(
    MaterialPageRoute<void>(builder: (BuildContext _) => const SizedBox()),
  );
}
