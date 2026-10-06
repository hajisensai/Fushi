import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_overlay.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_theme_host.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show showFushiMenu;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart'
    show FushiAppleDarkTier;

/// 歌词模式配色注入（2026-10-05 用户：「m3e 歌词模式下拉框颜色不对劲」「侧边栏
/// 打开各种颜色都不对劲在歌词模式下」）：
///  * 歌词覆盖层挂载即向页面外的 [LyricsThemeHost] 登记，卸载即撤回；
///  * 宿主激活后，从**页面 context** 弹出的菜单 / 阅读器侧栏（导航目录、阅读
///    设置、有声书面板、阅读统计都走 [showReaderSideSheet]）拿到的是歌词模式
///    的主题：MD3 = 按封面 scheme 重走工厂（菜单表面色等组件主题一起换），
///    Apple = 深色档；
///  * 宿主未激活时原样透传根主题。
class _Clock implements LyricsPlayerClock {
  @override
  Duration get position => Duration.zero;
  @override
  Duration get duration => const Duration(minutes: 1);
  @override
  LyricsPlayerStats get stats => LyricsPlayerStats.empty;
}

ThemeData _rootTheme({required bool apple}) => buildFushiThemeData(
  scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1E3A8A)),
  textTheme: Typography.material2021().black,
  glass: apple ? FushiGlassMaterial.frosted : FushiGlassMaterial.off,
  glassDesign: apple,
).copyWith(platform: TargetPlatform.windows);

/// 封面取色替身：暖橙色调（与用户截图里的封面同向）。
final ColorScheme _coverScheme = ColorScheme.fromSeed(
  seedColor: const Color(0xFFD9822B),
);

Widget _overlay() => ReaderLyricsPlayerOverlay(
  lyricsView: const SizedBox.expand(),
  data: LyricsPlayerData(
    title: 'T',
    cover: null,
    isPlaying: false,
    speed: 1,
    lyricsMasked: false,
    clock: _Clock(),
  ),
  callbacks: LyricsPlayerCallbacks(
    onClose: () {},
    onPlayPause: () {},
    onPreviousCue: () {},
    onNextCue: () {},
    onSeek: (_) {},
    onToggleMask: () {},
    onOpenStatistics: () {},
    onSpeedChanged: (_) {},
    onMore: (_) {},
    onTapBackground: () {},
  ),
  onHtmlThemeChanged: (_) {},
);

/// 阅读器页面替身：页面 State 的 context 在宿主之下（与真页面同构）。
class _Page extends StatefulWidget {
  const _Page({required this.lyrics, super.key});

  final bool lyrics;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(body: widget.lyrics ? _overlay() : const SizedBox.expand());
  }
}

void main() {
  testWidgets('歌词覆盖层挂载即登记宿主、卸载即撤回', (WidgetTester tester) async {
    final GlobalKey<LyricsThemeHostState> host =
        GlobalKey<LyricsThemeHostState>();
    Widget app({required bool lyrics}) => MaterialApp(
      theme: _rootTheme(apple: false),
      home: LyricsThemeHost(
        key: host,
        child: _Page(lyrics: lyrics),
      ),
    );
    await tester.pumpWidget(app(lyrics: false));
    expect(host.currentState!.active, isFalse);
    await tester.pumpWidget(app(lyrics: true));
    await tester.pump();
    expect(host.currentState!.active, isTrue);
    await tester.pumpWidget(app(lyrics: false));
    await tester.pump();
    expect(host.currentState!.active, isFalse);
  });

  for (final bool apple in <bool>[false, true]) {
    final String design = apple ? 'Apple' : 'MD3';

    testWidgets('$design：从页面 context 弹出的菜单与侧栏继承歌词模式主题', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.reset);

      final ThemeData root = _rootTheme(apple: apple);
      final ThemeData expected = apple
          ? FushiAppleDarkTier.darkTierOf(root)
          : rethemeFushiWithScheme(root, _coverScheme);
      final GlobalKey<LyricsThemeHostState> host =
          GlobalKey<LyricsThemeHostState>();
      final GlobalKey<_PageState> page = GlobalKey<_PageState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: root,
          themeAnimationDuration: Duration.zero,
          home: LyricsThemeHost(
            key: host,
            child: _Page(key: page, lyrics: false),
          ),
        ),
      );

      // 未激活：页面就是根主题。
      expect(
        Theme.of(page.currentContext!).colorScheme.primary,
        root.colorScheme.primary,
      );

      // 歌词覆盖层上报封面 scheme（真实路径里由 ColorScheme.fromImageProvider
      // 异步给出；这里直接登记，测的是注入与传递）。
      final Object owner = Object();
      host.currentState!.attach(owner, _coverScheme);
      await tester.pump();
      final BuildContext pageContext = page.currentContext!;
      final ThemeData pageTheme = Theme.of(pageContext);
      expect(pageTheme.colorScheme.primary, expected.colorScheme.primary);
      expect(pageTheme.colorScheme.surface, expected.colorScheme.surface);
      expect(
        pageTheme.colorScheme.surface,
        isNot(root.colorScheme.surface),
        reason: '$design 歌词模式下页面主题必须换掉根主题的表面色',
      );

      // ⋯ 菜单 / 下拉：菜单内容拿到的主题（含组件主题烤进去的菜单底色）。
      ThemeData? menuTheme;
      unawaited(
        showFushiMenu<int>(
          context: pageContext,
          position: const RelativeRect.fromLTRB(100, 100, 100, 100),
          items: <PopupMenuEntry<int>>[
            PopupMenuItem<int>(
              value: 1,
              child: Builder(
                builder: (BuildContext context) {
                  menuTheme = Theme.of(context);
                  return const Text('item');
                },
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(menuTheme, isNotNull);
      expect(menuTheme!.colorScheme.primary, expected.colorScheme.primary);
      expect(menuTheme!.popupMenuTheme.color, expected.popupMenuTheme.color);
      if (!apple) {
        expect(
          menuTheme!.popupMenuTheme.color,
          isNot(root.popupMenuTheme.color),
          reason: '菜单表面色烤在组件主题里，必须跟着封面 scheme 重算',
        );
      }
      Navigator.of(pageContext).pop();
      await tester.pumpAndSettle();

      // 阅读器侧栏（导航目录 / 阅读设置 / 有声书面板 / 阅读统计共用的抽屉）。
      ThemeData? sheetTheme;
      unawaited(
        showReaderSideSheet<void>(
          context: pageContext,
          builder: (BuildContext context) {
            sheetTheme = Theme.of(context);
            return const SizedBox.expand();
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(sheetTheme, isNotNull);
      expect(sheetTheme!.colorScheme.primary, expected.colorScheme.primary);
      final Material sheet = tester.widget<Material>(
        find.byKey(const ValueKey<String>('fushi_reader_side_sheet')),
      );
      if (apple) {
        expect(sheetTheme!.brightness, Brightness.dark);
      } else {
        expect(sheet.color, expected.colorScheme.surfaceContainerLow);
      }
      Navigator.of(pageContext).pop();
      await tester.pumpAndSettle();

      // 撤回：页面回到根主题。
      host.currentState!.detach(owner);
      await tester.pump();
      expect(
        Theme.of(page.currentContext!).colorScheme.primary,
        root.colorScheme.primary,
      );
    });
  }
}
