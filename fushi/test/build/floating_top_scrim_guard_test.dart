import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';

/// 浮动顶栏页面的顶部可读性只允许无硬边的柔和渐变（2026-10-06 用户：视频
/// 详情页滚动后集卡在顶栏下沿被一条水平硬边切开，之前按页面修过多次仍复发）。
///
/// 根因有两层，本守卫各咬一层：
/// 1. 共享遮罩 [FushiTopFadeScrim] 的不透明度曲线必须单调、连续、末端为 0，
///    相邻采样之间没有跳变（曾经是「实色段 + 20 px 线性降到 0」，顶栏还从栏
///    下沿起画，不透明度在下沿处 0 → 0.92 一步跳上去）。
/// 2. 页面不得自己再画顶部底带 / 渐变：详情布局曾叠一层 `_MediaDetailTopScrim`，
///    与顶栏那层叠加出浅色带；铺到顶栏底下的页面（extendBodyBehindAppBar）
///    的 [FushiAppBar] 不得设非透明底色或 flexibleSpace。
void main() {
  group('FushiTopFadeScrim curve', () {
    Future<List<Color>> pumpScrim(
      WidgetTester tester, {
      required double solidHeight,
      double topOpacity = 0.92,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topCenter,
            child: FushiTopFadeScrim(
              solidHeight: solidHeight,
              topOpacity: topOpacity,
              color: const Color(0xFFFFFFFF),
            ),
          ),
        ),
      );
      final DecoratedBox box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(FushiTopFadeScrim),
          matching: find.byType(DecoratedBox),
        ),
      );
      final LinearGradient gradient =
          (box.decoration as BoxDecoration).gradient! as LinearGradient;
      return gradient.colors;
    }

    for (final double solid in <double>[0, 56, 120]) {
      testWidgets('solidHeight $solid: monotone, continuous, ends at 0', (
        WidgetTester tester,
      ) async {
        final List<Color> colors = await pumpScrim(tester, solidHeight: solid);
        expect(colors.first.a, closeTo(0.92, 0.001));
        expect(colors.last.a, closeTo(0, 0.001));
        for (int i = 1; i < colors.length; i++) {
          expect(
            colors[i].a,
            lessThanOrEqualTo(colors[i - 1].a + 1e-6),
            reason: 'alpha must not rise at sample $i',
          );
          expect(
            colors[i - 1].a - colors[i].a,
            lessThan(0.2),
            reason: 'no visible step between adjacent samples ($i)',
          );
        }
      });
    }

    testWidgets('topOpacity 1 starts fully opaque (seam continuation)', (
      WidgetTester tester,
    ) async {
      final List<Color> colors = await pumpScrim(
        tester,
        solidHeight: 0,
        topOpacity: 1,
      );
      expect(colors.first.a, closeTo(1, 0.001));
    });
  });

  group('no page-local top bands', () {
    test('MediaDetailLayout draws no own top scrim', () {
      final String kit = File(
        'lib/src/media/detail/media_detail_kit.dart',
      ).readAsStringSync();
      expect(kit.contains('_MediaDetailTopScrim'), isFalse);
      expect(kit.contains('topScrim'), isFalse);
    });

    test('FushiAppBar on extendBodyBehindAppBar pages paints no band', () {
      final List<String> offenders = <String>[];
      for (final FileSystemEntity entity in Directory(
        'lib',
      ).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final String source = entity.readAsStringSync();
        if (!source.contains('extendBodyBehindAppBar: true')) continue;
        int from = 0;
        while (true) {
          final int start = source.indexOf('FushiAppBar(', from);
          if (start < 0) break;
          final String args = _balancedArgs(
            source,
            start + 'FushiAppBar'.length,
          );
          from = start + 1;
          final RegExpMatch? bg = RegExp(
            r'(?<![A-Za-z])backgroundColor:\s*([^,)\n]+)',
          ).firstMatch(args);
          if (bg != null && bg.group(1)!.trim() != 'Colors.transparent') {
            offenders.add('${entity.path}: backgroundColor ${bg.group(1)}');
          }
          if (args.contains('flexibleSpace:')) {
            offenders.add('${entity.path}: flexibleSpace');
          }
        }
      }
      expect(offenders, isEmpty);
    });

    test('top fades go through the shared FushiTopFadeScrim', () {
      // 曾经各页各写一份「底色 → 透明」两色线性渐变（线性渐变末端斜率突变，
      // 在模糊背景上是一道看得见的 Mach 带）。
      final String discovery = File(
        'lib/src/pages/implementations/discovery/discovery_hero_carousel.dart',
      ).readAsStringSync();
      expect(discovery.contains('FushiTopFadeScrim('), isTrue);
    });

    test('library toolbar scrim is a short fade, not a solid block', () {
      // 曾经整个工具区高度都是 0.92 的实色段：库页一滚顶部两三百 px 全白。
      final String chrome = File(
        'lib/src/utils/components/fushi_floating_chrome.dart',
      ).readAsStringSync();
      expect(
        chrome.contains('solidHeight: outer + shown * _chromeHeight'),
        isFalse,
      );
      expect(chrome.contains('kFushiTopScrimChromeReach'), isTrue);
    });

    test('discovery pages float their search rows in the toolbar', () {
      // 发现页的搜索 / 筛选行曾是 Column 里的一整块不透明控件区。
      for (final String path in <String>[
        'lib/src/pages/implementations/video_discovery_page.dart',
        'lib/src/media/manga/discovery/manga_discovery_page.dart',
        'lib/src/pages/implementations/media_discovery_page.dart',
      ]) {
        final String source = File(path).readAsStringSync();
        expect(
          source.contains('FushiFloatingChromeOverlay('),
          isTrue,
          reason: path,
        );
        expect(
          source.contains('FushiFloatingChromeInsetSpacer()'),
          isTrue,
          reason: path,
        );
      }
    });

    test('FushiFloatingChromeInsetPadding is a ratchet, not a page root', () {
      // 整体 Padding 下移让出的那段永远是空白页面底色：工具区一收起顶部就是
      // 一整块白（游戏 / 设置 2026-10-06 截图）。滚动页面一律走
      // FushiFloatingChromeScrollInset / InsetSpacer；InsetPadding 只留给不滚动
      // 的占位 / 加载 / 错误态，以及下面这些已审过的点。只许减，不许加。
      const Map<String, int> allowed = <String, int>{
        'lib/src/pages/implementations/browse_page.dart': 1,
        'lib/src/pages/implementations/home_game_page.dart': 1,
        'lib/src/pages/implementations/home_reader_page.dart': 1,
        'lib/src/pages/implementations/media_discovery_page.dart': 7,
        'lib/src/pages/implementations/media_library_shell.dart': 1,
        'lib/src/pages/implementations/media_server/media_server_widgets.dart':
            1,
        'lib/src/pages/implementations/reader_fushi_history_page.dart': 4,
        'lib/src/pages/implementations/video_discovery_page.dart': 2,
        'lib/src/pages/implementations/video_library_shell.dart': 1,
      };
      final Map<String, int> found = <String, int>{};
      for (final FileSystemEntity entity in Directory(
        'lib',
      ).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final String path = entity.path.replaceAll(r'\', '/');
        if (path.endsWith('fushi_floating_chrome.dart')) continue;
        final int count = 'FushiFloatingChromeInsetPadding('
            .allMatches(entity.readAsStringSync())
            .length;
        if (count > 0) found[path] = count;
      }
      for (final MapEntry<String, int> entry in found.entries) {
        expect(
          entry.value,
          lessThanOrEqualTo(allowed[entry.key] ?? 0),
          reason:
              '${entry.key}: 新增的整体下移；滚动页面改用 '
              'FushiFloatingChromeScrollInset',
        );
      }
    });

    test('top fade scrims live only in shared components', () {
      const Set<String> allowed = <String>{
        'lib/src/utils/components/fushi_floating_chrome.dart',
        'lib/src/utils/components/fushi_material_components.dart',
        'lib/src/utils/components/glass/fushi_glass_bars.dart',
        'lib/src/pages/implementations/discovery/discovery_hero_carousel.dart',
      };
      final List<String> offenders = <String>[];
      for (final FileSystemEntity entity in Directory(
        'lib',
      ).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final String path = entity.path.replaceAll(r'\', '/');
        if (allowed.contains(path)) continue;
        final String source = entity.readAsStringSync();
        if (source.contains('FushiTopFadeScrim(')) offenders.add(path);
      }
      expect(offenders, isEmpty);
    });

    test('hero backdrops on app-bar pages extend behind the bar', () {
      // 游戏详情页：正文从顶栏下沿开始，hero 背景（左上角散开的色晕）在栏下沿
      // 被切出一块发白的矩形色区（2026-10-06 用户截图）。带 hero 渐变背景的
      // FushiAppBar 页必须 extendBodyBehindAppBar，背景从窗口顶端画起。
      // 白名单里的渐变是卡片 / 发现卡的局部遮罩，不是页面顶部。
      const Set<String> allowed = <String>{
        'lib/src/pages/implementations/discovery/discovery_layout.dart',
        'lib/src/pages/implementations/games_library_page.dart',
      };
      final List<String> offenders = <String>[];
      for (final FileSystemEntity entity in Directory(
        'lib',
      ).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final String path = entity.path.replaceAll(r'\', '/');
        if (path.contains('/utils/components/') || allowed.contains(path)) {
          continue;
        }
        final String source = entity.readAsStringSync();
        if (!source.contains('FushiAppBar(')) continue;
        final bool heroGradient =
            source.contains('RadialGradient(') ||
            source.contains('begin: Alignment.topCenter') ||
            source.contains('begin: Alignment.topLeft');
        if (heroGradient && !source.contains('extendBodyBehindAppBar: true')) {
          offenders.add(path);
        }
      }
      expect(offenders, isEmpty);
    });

    test(
      'FushiPageScaffold opt-outs from the floating header are reviewed',
      () {
        // FushiPageScaffold 默认把页头叠在正文上（bc65b9dc94c），正文滚到页头
        // 底下、无实色带。只有确实无法让内容滚到页头底下的页面才能退回竖排，
        // 且必须在调用处写明理由；新增退回要先加进这里（只许减不许加）。
        const Map<String, int> allowed = <String, int>{
          // Mokuro 目录（固定搜索行 + 网格 + 底部动作行的竖排）与 OPDS 目录
          // （正文 MediaDiscoveryPage 自带浮动工具区，脚手架不下发作用域）。
          'lib/src/media/manga/discovery/manga_discovery_page.dart': 2,
          // Mokuro 目录（同上）。
          'lib/src/media/manga/manga_online_sources_view.dart': 1,
          // Mihon 登录：整页 WebView。
          'lib/src/media/manga/mihon/mihon_web_login_page.dart': 1,
          // 字幕工作台：定高面板，顶部控件行固定、列表区各自滚动。
          'lib/src/pages/implementations/subtitle_workbench_page.dart': 1,
          // 标签选择：与弹层共用的面板，固定标题行 + 底部动作行。
          'lib/src/pages/implementations/tag_picker_page.dart': 1,
          // 配对扫码：相机取景定高画布。
          'lib/src/sync/sync_settings_schema/interconnect_link.part.dart': 1,
        };
        final Map<String, int> found = <String, int>{};
        for (final FileSystemEntity entity in Directory(
          'lib',
        ).listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          final String path = entity.path.replaceAll(r'\', '/');
          final int count = 'extendBodyBehindHeader: false'
              .allMatches(entity.readAsStringSync())
              .length;
          if (count > 0) found[path] = count;
        }
        for (final MapEntry<String, int> entry in found.entries) {
          expect(
            entry.value,
            lessThanOrEqualTo(allowed[entry.key] ?? 0),
            reason:
                '${entry.key}: 新的竖排退回；让正文消费 '
                'MediaQuery.paddingOf(context).top，或在此登记理由',
          );
        }
      },
    );

    test('SettingsKitScaffold pages scroll under the floating header', () {
      // 设置子页独立脚手架默认竖排（bodyConsumesTopPadding: false），页头收起
      // 后顶部留一段实色空白。每个调用点都必须显式 true；只有正文是定高卡片
      // + 自带滚动（FushiLogPanel）的日志页例外。
      const Set<String> allowedFalse = <String>{
        'lib/src/pages/implementations/debug_log_page.dart',
        'lib/src/pages/implementations/error_log_page.dart',
      };
      final List<String> offenders = <String>[];
      for (final FileSystemEntity entity in Directory(
        'lib',
      ).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final String path = entity.path.replaceAll(r'\', '/');
        if (path.endsWith('/settings/settings_kit.dart')) continue;
        final String source = entity.readAsStringSync();
        final int calls = 'SettingsKitScaffold('.allMatches(source).length;
        if (calls == 0) continue;
        final int consuming = 'bodyConsumesTopPadding: true'
            .allMatches(source)
            .length;
        if (consuming < calls && !allowedFalse.contains(path)) {
          offenders.add(path);
        }
      }
      expect(offenders, isEmpty);
    });

    test('desktop title bar floats over the page', () {
      // 曾经是 Column[标题行, Expanded(页面)]：标题行是一条独立带子，页面背景
      // 在 y = 32 被切开。
      final String bar = File(
        'lib/src/utils/components/fushi_desktop_title_bar.dart',
      ).readAsStringSync();
      expect(bar.contains('? Colors.transparent\n'), isTrue);
      expect(bar.contains('top: mediaQuery.padding.top + inset'), isTrue);
    });
  });
}

/// 从 [open]（指向 `(`）开始取配平的参数文本。
String _balancedArgs(String source, int open) {
  int depth = 0;
  for (int i = open; i < source.length; i++) {
    final String c = source[i];
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  return source.substring(open);
}
