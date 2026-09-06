import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/pages/implementations/manga_fushi_page.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';

import '../helpers/source_guard.dart';

/// BUG-1888 回归：漫画阅读器必须有隐藏界面的方式。
///
/// 修前状态：顶栏（页码 + 框选/整卷 OCR/单双页/阅读模式）与左上返回键的**唯一**
/// 显示条件是 `_bookRow != null && !_loadFailed`——没有任何可见性状态字段、没有
/// auto-hide、没有点击唤出、也没有对应的 ShortcutAction，用户无从把它们收掉。
///
/// 三层断言：
///  1. 动作层：`mangaToggleChrome` 存在于 manga scope，且默认绑定 M / 手柄 Y
///     （与 [ShortcutAction.readerToggleChrome] 同键，跨阅读器复用肌肉记忆）。
///  2. 解析层：[MangaFushiPage.inputActionForShortcut] 把它映射成
///     [MangaReaderInputAction.toggleChrome]，且**不吃两道翻页门控**——webtoon
///     模式和词典弹窗可见时都必须照常解析出来。
///  3. 结构层：源码守卫钉住「顶栏受内容门控，返回键与唤回键**只**受
///     `_chromeVisible` 门控」+「隐藏态留有唤回按钮」。后者是硬要求：漫画正文是
///     原生 WebView，空白点击手势全在注入的 JS 里且已被翻页占用，没有这个按钮
///     触屏设备就再也唤不回界面。前者同样是硬要求：返回键是本页唯一出口，
///     一旦挂上内容门控，加载失败态就没有任何退出通道——iOS 没有系统返回键，
///     `PopScope(canPop: false)` 还关掉了侧滑返回，结果是只能杀进程。
void main() {
  group('动作层：mangaToggleChrome 注册与默认绑定', () {
    test('枚举存在，scope=manga，key 稳定', () {
      expect(
        ShortcutAction.values.map((ShortcutAction a) => a.name),
        contains('mangaToggleChrome'),
      );
      expect(ShortcutAction.mangaToggleChrome.scope, ShortcutScope.manga);
      expect(ShortcutAction.mangaToggleChrome.key, 'manga_toggle_chrome');
      expect(
        ShortcutAction.actionsForScope(ShortcutScope.manga),
        contains(ShortcutAction.mangaToggleChrome),
      );
    });

    test('默认键盘 M / 手柄 Y，与 readerToggleChrome 同键', () {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.android,
      ]) {
        final Map<ShortcutAction, ShortcutBindingSet> table =
            ShortcutDefaults.forPlatform(platform);
        final ShortcutBindingSet manga =
            table[ShortcutAction.mangaToggleChrome]!;
        expect(
          manga.keyboardBindings.map((InputBinding b) => b.key),
          contains(LogicalKeyboardKey.keyM),
          reason: '$platform 的漫画切换界面必须默认绑 M',
        );
        final ShortcutBindingSet reader =
            table[ShortcutAction.readerToggleChrome]!;
        expect(
          manga.keyboardBindings.map((InputBinding b) => b.key).toSet(),
          reader.keyboardBindings.map((InputBinding b) => b.key).toSet(),
          reason: '漫画与小说的「切换界面」应当同键，两者分属不同 scope 绝不同时激活',
        );
        expect(
          manga.gamepadBindings.map((GamepadBinding b) => b.button).toSet(),
          reader.gamepadBindings.map((GamepadBinding b) => b.button).toSet(),
          reason: '手柄侧同理',
        );
      }
    });
  });

  group('解析层：不吃两道翻页门控', () {
    MangaReaderInputAction? resolve({
      required bool dictionaryShown,
      required MangaReadingMode mode,
      bool crossPageStep = false,
    }) =>
        MangaFushiPage.inputActionForShortcut(
          action: ShortcutAction.mangaToggleChrome,
          crossPageStep: crossPageStep,
          dictionaryShown: dictionaryShown,
          mode: mode,
        );

    test('spread 模式、无弹窗：解析成 toggleChrome', () {
      expect(
        resolve(dictionaryShown: false, mode: MangaReadingMode.spread),
        MangaReaderInputAction.toggleChrome,
      );
    });

    test('webtoon 模式仍解析（那道门控只针对翻页）', () {
      expect(
        resolve(dictionaryShown: false, mode: MangaReadingMode.webtoon),
        MangaReaderInputAction.toggleChrome,
        reason: 'webtoon 让位原生滚动的门控是给翻页的，切换界面不翻页',
      );
    });

    test('词典弹窗可见时仍解析（查词途中也该能收顶栏看页图）', () {
      expect(
        resolve(dictionaryShown: true, mode: MangaReadingMode.spread),
        MangaReaderInputAction.toggleChrome,
      );
      expect(
        resolve(dictionaryShown: true, mode: MangaReadingMode.webtoon),
        MangaReaderInputAction.toggleChrome,
      );
    });

    test('不影响既有动作：翻页 / 关词典 / 退出的解析结果不变', () {
      expect(
        MangaFushiPage.inputActionForShortcut(
          action: ShortcutAction.mangaPageForward,
          crossPageStep: false,
          dictionaryShown: false,
          mode: MangaReadingMode.webtoon,
        ),
        isNull,
        reason: 'webtoon 让位原生滚动这道门控必须原样保留',
      );
      expect(
        MangaFushiPage.inputActionForShortcut(
          action: ShortcutAction.globalBack,
          crossPageStep: false,
          dictionaryShown: false,
          mode: MangaReadingMode.spread,
        ),
        MangaReaderInputAction.backOrExit,
      );
      expect(
        MangaFushiPage.inputActionForShortcut(
          action: ShortcutAction.mangaDismissDict,
          crossPageStep: false,
          dictionaryShown: true,
          mode: MangaReadingMode.spread,
        ),
        MangaReaderInputAction.dismissDictionary,
      );
    });
  });

  group('结构层：源码守卫', () {
    // 必须剥注释再判：本次修复在源码注释里**逐字引用了旧条件**用于解释为什么它
    // 是错的，不剥的话守卫会把那段说明数成一处真实门控，断言恒红。
    final String pageSrc = maskComments(
      File(
        'lib/src/media/manga/reader/manga_fushi_page.dart',
      ).readAsStringSync(),
    );

    test('顶栏受内容门控，返回键与唤回键只受 _chromeVisible 门控', () {
      expect(
        pageSrc.contains('bool _chromeVisible = true;'),
        isTrue,
        reason: '可见性必须是页面自己的状态字段',
      );
      // 顶栏画的是页码 / 框选 OCR / 单双页，没有内容时它们无意义——继续挂内容门控。
      expect(
        pageSrc.contains('_bookRow != null && !_loadFailed && _chromeVisible'),
        isTrue,
        reason: '顶栏（页码/OCR/单双页）在没有内容时不该画',
      );
      // 出口不是内容的一部分。返回键与唤回键**不得**再出现内容门控：
      // 加载失败或迟迟未就绪时它们一起消失，iOS 上就是「只能杀进程」
      // （没有系统返回键 + PopScope(canPop:false) 关掉了侧滑返回 +
      //  正文原生 WebView 的空白点击已被翻页占用）。
      expect(
        pageSrc.contains('_bookRow != null && !_loadFailed && !_chromeVisible'),
        isFalse,
        reason: '唤回按钮不得挂内容门控——隐藏界面后内容加载失败会连返回键一起叫不回来',
      );
      expect(
        RegExp(r'_bookRow != null && !_loadFailed && _chromeVisible')
            .allMatches(pageSrc)
            .length,
        1,
        reason: '内容门控只该剩顶栏那一处；返回键若还挂着它，失败态就没有出口了',
      );
    });

    test('隐藏态留有可点的唤回按钮', () {
      expect(
        pageSrc.contains("'manga_chrome_show_button'"),
        isTrue,
        reason: '漫画正文是原生 WebView、空白点击已被翻页占用，'
            '没有这个按钮触屏设备再无第二条通道唤回界面',
      );
      expect(pageSrc.contains("'manga_chrome_hide_button'"), isTrue);
      expect(pageSrc.contains('t.manga_interface_show'), isTrue);
      expect(pageSrc.contains('t.manga_interface_hide'), isTrue);
    });

    test('切换界面时移动端联动系统栏沉浸', () {
      expect(pageSrc.contains('_applyMangaImmersiveMode'), isTrue);
      expect(pageSrc.contains('SystemUiMode.immersiveSticky'), isTrue);
      expect(
        pageSrc.contains('SystemUiMode.edgeToEdge'),
        isTrue,
        reason: '显示界面时要还原，不能把系统栏永久吞掉',
      );
    });

    test('快捷键执行体走同一个 _toggleMangaChrome', () {
      expect(
        pageSrc.contains('MangaReaderInputAction.toggleChrome'),
        isTrue,
      );
      expect(pageSrc.contains('_toggleMangaChrome();'), isTrue);
      expect(
        pageSrc.contains('onPressed: _toggleMangaChrome,'),
        isTrue,
        reason: '按钮与快捷键必须共用一个执行体，避免两条路行为漂移',
      );
    });
  });
}
