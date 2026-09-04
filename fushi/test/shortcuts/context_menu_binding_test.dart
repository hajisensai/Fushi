import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/shortcuts/global_navigation.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/mouse_binding_dispatch.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// 「右键菜单」纳入绑定表（[ShortcutAction.globalContextMenu]）之后的三条不变式：
///
///   ① 谁都没改键 → 右键仍然弹菜单（Never break userspace）；
///   ② 用户把右键绑给页面动作 → 菜单在**那个页面**自动让位，其余表面照常（共用，
///      不需要先解绑菜单）；
///   ③ 菜单改绑中键 / 侧键 → 跟着走，右键不再弹。
///
/// 本次报修的原始症状是「把快捷键绑到右键上，按一下既跑那个动作、又弹右键菜单」——
/// 根因是右键这个物理按钮同时被硬编码的 `onSecondaryTap*` 与鼠标绑定通道消费，两者
/// 互不知情。②就是那条症状的回归门。
void main() {
  late FushiShortcutRegistry registry;

  setUp(() {
    registry = FushiShortcutRegistry();
    registry.loadDefaults(TargetPlatform.windows);
    MouseBindingDispatch.resetForTest();
  });

  const List<ShortcutScope> videoLadder = <ShortcutScope>[
    ShortcutScope.video,
    ShortcutScope.universal,
    ShortcutScope.global,
  ];

  group('默认绑定', () {
    test('三平台默认表都把右键给了 globalContextMenu（含移动端：安卓可接鼠标）', () {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.android,
      ]) {
        expect(
          ShortcutDefaults.forPlatform(
                  platform)[ShortcutAction.globalContextMenu]!
              .mouseBindings,
          contains(const MouseBinding(2)),
          reason: '$platform 默认表丢了右键 → 该平台右键菜单会整个消失',
        );
      }
    });

    test('默认表里右键没有被任何页面 scope 的动作占用（否则默认就遮蔽菜单）', () {
      final Map<ShortcutAction, ShortcutBindingSet> defaults =
          ShortcutDefaults.forPlatform(TargetPlatform.windows);
      for (final MapEntry<ShortcutAction, ShortcutBindingSet> e
          in defaults.entries) {
        if (e.key == ShortcutAction.globalContextMenu) continue;
        expect(
          e.value.mouseBindings,
          isNot(contains(const MouseBinding(2))),
          reason: '${e.key.key} 默认占了右键，会把上下文菜单默认遮蔽掉',
        );
      }
    });
  });

  group('判据 contextMenuButtonMatches', () {
    test('① 没改过键：右键 = 菜单，中键 / 左键都不是', () {
      expect(
        contextMenuButtonMatches(
          registry: registry,
          buttons: kSecondaryMouseButton,
          ladder: kDefaultContextMenuLadder,
        ),
        isTrue,
      );
      expect(
        contextMenuButtonMatches(
          registry: registry,
          buttons: kMiddleMouseButton,
          ladder: kDefaultContextMenuLadder,
        ),
        isFalse,
      );
      // 左键恒折不出按钮号 → 永远不可能被解析成菜单（正常点击 / 划词零影响）。
      expect(
        contextMenuButtonMatches(
          registry: registry,
          buttons: kPrimaryMouseButton,
          ladder: kDefaultContextMenuLadder,
        ),
        isFalse,
      );
    });

    test('拿不到绑定表时回退成硬绑右键（widget 测试宿主不必搭注册表）', () {
      expect(
        contextMenuButtonMatches(
          registry: null,
          buttons: kSecondaryMouseButton,
          ladder: kDefaultContextMenuLadder,
        ),
        isTrue,
      );
      expect(
        contextMenuButtonMatches(
          registry: null,
          buttons: kMiddleMouseButton,
          ladder: kDefaultContextMenuLadder,
        ),
        isFalse,
      );
    });

    test('② 右键绑给视频页动作：视频页让位，书架 / 首页照常弹（快捷键可共用）', () {
      registry.updateBinding(
        ShortcutAction.videoScreenshot,
        const ShortcutBindingSet(
            mouseBindings: <MouseBinding>[MouseBinding(2)]),
      );

      // 视频页阶梯：video scope 先命中 videoScreenshot → 菜单让位，一次按下只做一件事。
      expect(
        contextMenuButtonMatches(
          registry: registry,
          buttons: kSecondaryMouseButton,
          ladder: videoLadder,
        ),
        isFalse,
        reason: '这正是报修症状：右键既截图又弹菜单',
      );

      // 关键：菜单**没有被解绑**，别的表面照常。用户不必二选一。
      expect(
        contextMenuButtonMatches(
          registry: registry,
          buttons: kSecondaryMouseButton,
          ladder: kDefaultContextMenuLadder,
        ),
        isTrue,
      );
      expect(
        registry.bindingsFor(ShortcutAction.globalContextMenu).mouseBindings,
        contains(const MouseBinding(2)),
      );
    });

    test('③ 菜单改绑中键：中键弹菜单，右键不再弹', () {
      registry.updateBinding(
        ShortcutAction.globalContextMenu,
        const ShortcutBindingSet(
            mouseBindings: <MouseBinding>[MouseBinding(1)]),
      );
      expect(
        contextMenuButtonMatches(
          registry: registry,
          buttons: kMiddleMouseButton,
          ladder: kDefaultContextMenuLadder,
        ),
        isTrue,
      );
      expect(
        contextMenuButtonMatches(
          registry: registry,
          buttons: kSecondaryMouseButton,
          ladder: kDefaultContextMenuLadder,
        ),
        isFalse,
      );
    });

    test('按钮号版本（WebView 那一路）与位掩码版本判据一致', () {
      const List<ShortcutScope> mangaLadder = <ShortcutScope>[
        ShortcutScope.manga,
        ShortcutScope.universal,
        ShortcutScope.global,
      ];
      expect(
        contextMenuButtonNumberMatches(
          registry: registry,
          button: 2,
          ladder: mangaLadder,
        ),
        isTrue,
      );
      // 漫画页把右键绑给翻页 → 菜单让位（否则一次右键既翻页又弹菜单）。
      registry.updateBinding(
        ShortcutAction.mangaPageForward,
        const ShortcutBindingSet(
            mouseBindings: <MouseBinding>[MouseBinding(2)]),
      );
      expect(
        contextMenuButtonNumberMatches(
          registry: registry,
          button: 2,
          ladder: mangaLadder,
        ),
        isFalse,
      );
      // button 0（左键）在 DOM 口径里恒不可绑。
      expect(
        contextMenuButtonNumberMatches(
          registry: registry,
          button: 0,
          ladder: mangaLadder,
        ),
        isFalse,
      );
    });

    test('菜单绑定被清空 = 彻底关掉右键菜单', () {
      registry.updateBinding(
        ShortcutAction.globalContextMenu,
        const ShortcutBindingSet(),
      );
      expect(
        contextMenuButtonMatches(
          registry: registry,
          buttons: kSecondaryMouseButton,
          ladder: kDefaultContextMenuLadder,
        ),
        isFalse,
      );
    });
  });

  group('ContextMenuTrigger', () {
    Future<void> pressButton(WidgetTester tester, int buttons) async {
      final TestGesture gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: buttons,
      );
      await gesture.down(tester.getCenter(find.byKey(const Key('target'))));
      await tester.pump();
      await gesture.up();
      await tester.pump();
    }

    Future<void> pumpTrigger(
      WidgetTester tester, {
      required List<Offset> hits,
      FushiShortcutRegistry? scopeRegistry,
      bool nullInvoke = false,
    }) async {
      final Widget trigger = ContextMenuTrigger(
        onInvoke: nullInvoke ? null : hits.add,
        child: const SizedBox(
          key: Key('target'),
          width: 200,
          height: 100,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: scopeRegistry == null
                  ? trigger
                  : ShortcutBindingScope(
                      registry: scopeRegistry,
                      child: trigger,
                    ),
            ),
          ),
        ),
      );
    }

    testWidgets('默认绑定下右键按下即弹菜单，并带上按下处坐标', (WidgetTester tester) async {
      final List<Offset> hits = <Offset>[];
      await pumpTrigger(tester, hits: hits, scopeRegistry: registry);
      await pressButton(tester, kSecondaryMouseButton);
      expect(hits, hasLength(1));
      expect(hits.single, tester.getCenter(find.byKey(const Key('target'))));
    });

    testWidgets('左键点击不弹菜单（正常点击零影响）', (WidgetTester tester) async {
      final List<Offset> hits = <Offset>[];
      await pumpTrigger(tester, hits: hits, scopeRegistry: registry);
      await pressButton(tester, kPrimaryMouseButton);
      expect(hits, isEmpty);
    });

    testWidgets('右键被页面动作占用后不再弹（同一份注册表，判据走阶梯）', (WidgetTester tester) async {
      registry.updateBinding(
        ShortcutAction.homeFocusSearch,
        const ShortcutBindingSet(
            mouseBindings: <MouseBinding>[MouseBinding(2)]),
      );
      final List<Offset> hits = <Offset>[];
      await pumpTrigger(tester, hits: hits, scopeRegistry: registry);
      await pressButton(tester, kSecondaryMouseButton);
      expect(hits, isEmpty);
    });

    testWidgets('onInvoke 为 null 时整层让路，不挂 Listener',
        (WidgetTester tester) async {
      await pumpTrigger(
        tester,
        hits: <Offset>[],
        scopeRegistry: registry,
        nullInvoke: true,
      );
      final ContextMenuTrigger widget = tester.widget<ContextMenuTrigger>(
        find.byType(ContextMenuTrigger),
      );
      expect(widget.onInvoke, isNull);
      expect(
        find.descendant(
          of: find.byType(ContextMenuTrigger),
          matching: find.byType(Listener),
        ),
        findsNothing,
      );
    });

    testWidgets('没有 ShortcutBindingScope 时回退硬绑右键（旧行为免费）',
        (WidgetTester tester) async {
      final List<Offset> hits = <Offset>[];
      await pumpTrigger(tester, hits: hits);
      await pressButton(tester, kSecondaryMouseButton);
      expect(hits, hasLength(1));
    });

    testWidgets('同一次按下只被认领一次：菜单弹了，外层鼠标绑定就不再派发', (WidgetTester tester) async {
      final List<Offset> hits = <Offset>[];
      int outerRuns = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ShortcutBindingScope(
            registry: registry,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (PointerDownEvent event) =>
                  dispatchClaimedMouseAction(event, () {
                outerRuns += 1;
                return true;
              }),
              child: Scaffold(
                body: Center(
                  child: ContextMenuTrigger(
                    onInvoke: hits.add,
                    child: const SizedBox(
                      key: Key('target'),
                      width: 200,
                      height: 100,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await pressButton(tester, kSecondaryMouseButton);
      expect(hits, hasLength(1));
      expect(outerRuns, 0, reason: '外层若也派发，就是「一次右键做两件事」的老症状');
    });
  });

  group('注册表真的送到了子树', () {
    // 全 app 唯一安装点是 `wrapWithGlobalNavigation`（global_navigation.dart）。
    // 把那一层删掉 / 挪到 Navigator 之外，16 处 ContextMenuTrigger 会全部落进
    // `registry == null` 回退分支 = 逐字退回硬绑右键 = BUG-2111 原样复发，而此前
    // **没有任何测试会红**：新测试全都是自己 pumpWidget 手搭一棵带 scope 的树。
    testWidgets('wrapWithGlobalNavigation 把 registry 装进 ShortcutBindingScope',
        (WidgetTester tester) async {
      FushiShortcutRegistry? seen;
      bool built = false;
      await tester.pumpWidget(MaterialApp(
        home: wrapWithGlobalNavigation(
          navigatorKey: GlobalKey<NavigatorState>(),
          registry: registry,
          child: Builder(builder: (BuildContext ctx) {
            built = true;
            seen = ShortcutBindingScope.maybeOf(ctx);
            return const SizedBox.shrink();
          }),
        ),
      ));
      expect(built, isTrue, reason: '子树没建起来，下面的断言会空过');
      expect(
        identical(seen, registry),
        isTrue,
        reason: 'wrapWithGlobalNavigation 没把注册表装进 ShortcutBindingScope：'
            '全部 ContextMenuTrigger 会退回硬绑右键（BUG-2111 复发）',
      );
    });
  });

  group('源码守卫：右键菜单不得再硬绑次按钮', () {
    /// 剥掉注释再扫——本仓库注释里满是 `onSecondaryTapDown` 的历史说明，不剥必假红。
    String stripComments(String source) {
      final StringBuffer out = StringBuffer();
      for (final String line in source.split('\n')) {
        final String trimmed = line.trimLeft();
        if (trimmed.startsWith('//')) continue;
        final int idx = line.indexOf('//');
        out.writeln(idx >= 0 ? line.substring(0, idx) : line);
      }
      return out.toString();
    }

    test('lib/ 里不再有 onSecondaryTapDown / onSecondaryTapUp 的手势入口', () {
      final List<String> offenders = <String>[];
      for (final FileSystemEntity entity
          in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final String source = stripComments(entity.readAsStringSync());
        if (source.contains('onSecondaryTapDown') ||
            source.contains('onSecondaryTapUp')) {
          offenders.add(entity.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: '这两个回调写死鼠标次按钮，绕过绑定表 → 右键被别的动作占用时会双触发。'
            '请改用 ContextMenuTrigger：${offenders.join(', ')}',
      );
    });

    test('漫画页 WebView 那一路也过归属判据（JS 侧仍硬判 e.button === 2）', () {
      final File file =
          File('lib/src/media/manga/reader/manga_fushi_page.dart');
      expect(file.existsSync(), isTrue, reason: '路径过期请更新守卫');
      final String source = stripComments(file.readAsStringSync());
      final int handler = source.indexOf("handlerName: 'onMangaContextMenu'");
      expect(handler, isNonNegative, reason: '漫画右键菜单 handler 不见了');
      final String body = source.substring(handler, handler + 600);
      expect(
        body.contains('contextMenuButtonNumberMatches('),
        isTrue,
        reason: '漫画页右键被别的动作占用时菜单必须让位，否则一次右键做两件事',
      );
      expect(body.contains('_kMangaMouseLadder'), isTrue,
          reason: '必须用漫画页那条阶梯，页面动作才排在菜单之前');
    });

    /// 取 `构造名(` 之后**深度 1** 的具名实参名字集合。
    ///
    /// 只看深度 1 是关键：`InkWell(child: FushiCard(onSecondaryTap: …))` 里那个
    /// `onSecondaryTap` 属于内层的 Fushi 组件（它自己走 ContextMenuTrigger），不是
    /// InkWell 的裸手势入口，不能算 InkWell 头上。
    Set<String> topLevelArgNames(String source, int openParen) {
      final Set<String> names = <String>{};
      int depth = 0;
      final StringBuffer ident = StringBuffer();
      for (int i = openParen; i < source.length; i++) {
        final String c = source[i];
        if (c == '(' || c == '[' || c == '{') {
          depth++;
          ident.clear();
          continue;
        }
        if (c == ')' || c == ']' || c == '}') {
          depth--;
          ident.clear();
          if (depth == 0) break;
          continue;
        }
        if (depth == 1) {
          if (RegExp(r'[A-Za-z0-9_]').hasMatch(c)) {
            ident.write(c);
            continue;
          }
          if (c == ':' && ident.isNotEmpty) names.add(ident.toString());
          ident.clear();
        }
      }
      return names;
    }

    // Flutter 自带的这三个 widget 是仅有的「裸手势消费次按钮」入口。它们头上一旦出现
    // onSecondaryTap*，那个物理按钮就被硬绑死、绕过绑定表——正是 BUG-2111 的形态。
    //
    // **按目录枚举，不是硬编码路径清单**：原来那条只盯死三个共享卡片文件，于是
    // `stat_period_detail_sheet.dart` 里新写的 `InkWell(onSecondaryTap: …)` 一个字都
    // 碰不到（那条同批 PR 引入的裸硬绑就是这么溜进来的）。新文件自动落进扫描面。
    test('lib/ 里没有任何裸手势 widget 直接消费次按钮', () {
      const List<String> rawGestureWidgets = <String>[
        'InkWell(',
        'InkResponse(',
        'GestureDetector(',
      ];
      final List<String> offenders = <String>[];
      for (final FileSystemEntity entity
          in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final String source = stripComments(entity.readAsStringSync());
        for (final String widget in rawGestureWidgets) {
          int at = source.indexOf(widget);
          while (at >= 0) {
            final Set<String> args =
                topLevelArgNames(source, at + widget.length - 1);
            if (args.any((String a) => a.startsWith('onSecondaryTap'))) {
              offenders.add('${entity.path} -> $widget');
            }
            at = source.indexOf(widget, at + widget.length);
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: '这些地方把鼠标次按钮硬绑死、绕过绑定表 → 右键被别的动作占用时会双触发。'
            '请改用 ContextMenuTrigger + contextMenuInvoker：${offenders.join(', ')}',
      );
    });

    test('三个共享卡片组件的 onSecondaryTap 参数只经 ContextMenuTrigger 落地', () {
      const List<String> shells = <String>[
        'lib/src/utils/components/fushi_material_components.dart',
        'lib/src/utils/components/galgame_poster_card.dart',
        'lib/src/pages/implementations/series_shelf_card.dart',
      ];
      for (final String path in shells) {
        final File file = File(path);
        expect(file.existsSync(), isTrue, reason: '路径过期请更新守卫：$path');
        final String source = stripComments(file.readAsStringSync());
        expect(
          source.contains('ContextMenuTrigger('),
          isTrue,
          reason: '$path 的右键菜单没走绑定表',
        );
        // InkWell / GestureDetector 上不得再直接接次按钮回调。
        expect(
          RegExp(r'onSecondaryTap:\s*(widget\.)?onSecondaryTap')
              .hasMatch(source),
          isFalse,
          reason: '$path 仍把 onSecondaryTap 直接转给手势识别器（硬绑右键）',
        );
      }
    });
  });
}
