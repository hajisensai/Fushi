import 'dart:io';

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/webview_key_bridge.dart';
import 'package:fushi/src/media/manga/reader/manga_held_turn_gate.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_input_bridge.dart';
import 'package:fushi/src/reader/page_turn_animation.dart';
import 'package:fushi/src/shortcuts/directional_page_turn.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/manga_arrow_override.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

import '../helpers/source_guard.dart';
import '../pages/reader_fushi_page_source_corpus.dart';

/// 反馈 uz_2m0E_Eu（拍板台已拍「做」）：小说与漫画左右翻页剩下的四处差异统一。
///
/// ① 有声在场时裸 ← → = 上一句 / 下一句（小说跟漫画走），PageUp / PageDown 仍翻页；
/// ② 长按 ← → 漫画也连发翻页，但等上一页翻页动画落定才翻下一页；
/// ③ 查词弹窗开着时 ← →：小说也关弹窗并翻页；
/// ④ 「反转方向键翻页」两边各一个开关（漫画新增，小说原有的不动）。
void main() {
  const Set<ModifierKey> none = <ModifierKey>{};

  ShortcutAction? readerTakeover({
    required LogicalKeyboardKey key,
    Set<ModifierKey> modifiers = none,
    required ShortcutAction? page,
    bool audio = true,
    bool dictionary = false,
  }) => resolveAudioArrowTakeover(
    key: key,
    modifiers: modifiers,
    pageAction: page,
    pageForward: ShortcutAction.readerPageForward,
    pageBackward: ShortcutAction.readerPageBackward,
    nextLine: ShortcutAction.audiobookNextSentence,
    previousLine: ShortcutAction.audiobookPrevSentence,
    audioActive: audio,
    dictionaryShown: dictionary,
  );

  group('① 有声在场时裸 ← → = 切句（两个阅读器同一判据）', () {
    test('校正后的下一页 / 上一页 → 下一句 / 上一句', () {
      expect(
        readerTakeover(
          key: LogicalKeyboardKey.arrowLeft,
          page: ShortcutAction.readerPageForward,
        ),
        ShortcutAction.audiobookNextSentence,
        reason: '竖排书左键 = 下一页，有声在场时就是下一句',
      );
      expect(
        readerTakeover(
          key: LogicalKeyboardKey.arrowRight,
          page: ShortcutAction.readerPageBackward,
        ),
        ShortcutAction.audiobookPrevSentence,
      );
    });

    test('没有有声 / 弹窗可见 / 带修饰键 / 改绑过 → 不接管', () {
      expect(
        readerTakeover(
          key: LogicalKeyboardKey.arrowRight,
          page: ShortcutAction.readerPageForward,
          audio: false,
        ),
        isNull,
      );
      expect(
        readerTakeover(
          key: LogicalKeyboardKey.arrowRight,
          page: ShortcutAction.readerPageForward,
          dictionary: true,
        ),
        isNull,
        reason: '弹窗开着时 ← → 是「关弹窗并翻页」（③）',
      );
      expect(
        readerTakeover(
          key: LogicalKeyboardKey.arrowRight,
          modifiers: <ModifierKey>{ModifierKey.ctrl},
          page: ShortcutAction.readerPageForward,
        ),
        isNull,
      );
      expect(
        readerTakeover(key: LogicalKeyboardKey.arrowRight, page: null),
        isNull,
        reason: '用户改绑 / 解绑过左右键，方向校正返回 null，切句也让路',
      );
    });

    test('PageUp / PageDown / ↑ / ↓ 不受影响，照旧翻页', () {
      for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.pageUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowUp,
      ]) {
        expect(
          readerTakeover(key: key, page: ShortcutAction.readerPageForward),
          isNull,
          reason: '$key',
        );
      }
    });

    test('漫画的有声接管与小说同一判据（共用 resolveAudioArrowTakeover）', () {
      for (final bool rtl in <bool>[true, false]) {
        for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
        ]) {
          final ShortcutAction factory = key == LogicalKeyboardKey.arrowLeft
              ? ShortcutAction.mangaPageBackward
              : ShortcutAction.mangaPageForward;
          final ShortcutAction? page = resolveMangaArrowPageTurn(
            key: key,
            modifiers: none,
            rtl: rtl,
            boundAction: factory,
          );
          final ShortcutAction? manga = resolveMangaAudioKeyTakeover(
            key: key,
            modifiers: none,
            pageAction: page,
            audioActive: true,
            dictionaryShown: false,
          );
          expect(
            manga,
            page == ShortcutAction.mangaPageForward
                ? ShortcutAction.mangaAudioNextLine
                : ShortcutAction.mangaAudioPreviousLine,
            reason: 'rtl=$rtl key=$key',
          );
        }
      }
    });

    test('小说键盘解析接上有声切句（源码守卫）', () {
      final String src = maskComments(readReaderPageSource());
      final int start = src.indexOf('ShortcutAction? _resolveReaderArrowKey(');
      expect(start, greaterThanOrEqualTo(0));
      final String body = src.substring(start, src.indexOf('\n  }\n', start));
      expect(body, contains('resolveReaderArrowPageTurn('));
      expect(body, contains('resolveAudioArrowTakeover('));
      expect(body, contains('audioActive: _hasActiveAudiobook'));
      expect(body, contains('dictionaryShown: isDictionaryShown'));
      // KeyDown / KeyRepeat 共用的解析器、spread 键桥、弹窗回传都走它。
      expect(
        '_resolveReaderArrowKey('.allMatches(src).length,
        greaterThanOrEqualTo(4),
        reason: '定义 + 键盘解析器 + spread 键桥 + 弹窗回传',
      );
    });
  });

  group('② 漫画长按连发翻页，等上一页动画落定', () {
    final DateTime t0 = DateTime(2026, 11, 24, 12);

    test('没翻过页时长按直接放行', () {
      final MangaHeldTurnGate gate = MangaHeldTurnGate();
      expect(gate.acceptsHeldTurn(now: t0, turnInFlight: false), isTrue);
    });

    test('翻页在飞时一律丢掉这次重复', () {
      final MangaHeldTurnGate gate = MangaHeldTurnGate();
      expect(gate.acceptsHeldTurn(now: t0, turnInFlight: true), isFalse);
    });

    test('动画没走完丢掉，走完放行', () {
      final MangaHeldTurnGate gate = MangaHeldTurnGate()
        ..noteTurnStarted(
          now: t0,
          animation: const Duration(milliseconds: 235),
        );
      expect(
        gate.acceptsHeldTurn(
          now: t0.add(const Duration(milliseconds: 100)),
          turnInFlight: false,
        ),
        isFalse,
      );
      expect(
        gate.acceptsHeldTurn(
          now: t0.add(const Duration(milliseconds: 235)),
          turnInFlight: false,
        ),
        isTrue,
      );
    });

    test('多步重叠取最晚落定；换章 reset 后立即放行', () {
      final MangaHeldTurnGate gate = MangaHeldTurnGate()
        ..noteTurnStarted(now: t0, animation: const Duration(seconds: 1))
        ..noteTurnStarted(
          now: t0.add(const Duration(milliseconds: 10)),
          animation: Duration.zero,
        );
      expect(
        gate.acceptsHeldTurn(
          now: t0.add(const Duration(milliseconds: 500)),
          turnInFlight: false,
        ),
        isFalse,
      );
      gate.reset();
      expect(
        gate.acceptsHeldTurn(
          now: t0.add(const Duration(milliseconds: 500)),
          turnInFlight: false,
        ),
        isTrue,
      );
    });

    test('动画时长：无效果为零、卷页取 curlDuration、其余取速度档', () {
      expect(
        pageTurnAnimationDuration(
          PageTurnAnimation.none,
          PageTurnAnimationSpeed.slow,
        ),
        Duration.zero,
      );
      expect(
        pageTurnAnimationDuration(
          PageTurnAnimation.slide,
          PageTurnAnimationSpeed.normal,
        ),
        FushiMotion.longReverse,
      );
      expect(
        pageTurnAnimationDuration(
          PageTurnAnimation.curl,
          PageTurnAnimationSpeed.fast,
        ),
        PageTurnAnimationSpeed.fast.curlDuration,
      );
    });

    test('键桥 reportRepeats：转发长按并回传 e.repeat；默认逐字不变', () {
      final String reporting = webViewKeyBridgeScript(
        handlerName: 'h',
        keys: const <String>['ArrowLeft'],
        reportRepeats: true,
      );
      expect(reporting, isNot(contains('if (e.repeat) return;')));
      expect(reporting, contains("callHandler('h', _hit, !!e.repeat)"));
      final String plain = webViewKeyBridgeScript(
        handlerName: 'h',
        keys: const <String>['ArrowLeft'],
      );
      expect(plain, contains("callHandler('h', _hit);"));
    });

    test('漫画两条键盘路径共用同一个长按判据（源码守卫）', () {
      final String src = maskComments(
        File(
          'lib/src/media/manga/reader/manga_fushi_page.dart',
        ).readAsStringSync(),
      );
      expect(
        '_heldInputVerdict('.allMatches(src).length,
        greaterThanOrEqualTo(3),
        reason: '定义 + Flutter 持焦路径 + WebView 键桥回传路径',
      );
      expect(src, contains('repeat: args.length > 1 && args[1] == true'));
      expect(src, contains('_noteHeldTurnStarted();'));
    });
  });

  group('③ 查词弹窗开着时 ← →：小说也关弹窗并翻页', () {
    FushiShortcutRegistry registry() =>
        FushiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

    test('只追加裸 ← →，翻页的其它键位留给弹窗', () {
      final DictionaryPopupInputSpec spec = withPopupArrowPageTurnKeys(
        const DictionaryPopupInputSpec(keyTokens: <String>['Escape']),
        registry: registry(),
        scope: ShortcutScope.reader,
        pageTurnActions: const <ShortcutAction>{
          ShortcutAction.readerPageForward,
          ShortcutAction.readerPageBackward,
        },
      );
      expect(spec.keyTokens, <String>['Escape', 'ArrowLeft', 'ArrowRight']);
      expect(spec.keyTokens, isNot(contains('PageDown')));
      expect(spec.keyTokens, isNot(contains('ArrowDown')));
    });

    test('漫画：翻页只交回 ← →，PageDown / ↓ / 空格留给弹窗滚动，鼠标键照旧（BUG-5364）', () {
      final FushiShortcutRegistry r = registry();
      const Set<ShortcutAction> turn = <ShortcutAction>{
        ShortcutAction.mangaPageForward,
        ShortcutAction.mangaPageBackward,
      };
      const Set<ShortcutAction> forwarded = <ShortcutAction>{
        ...turn,
        ShortcutAction.mangaDismissDict,
        ShortcutAction.globalBack,
        ShortcutAction.globalToggleFullscreen,
      };
      final DictionaryPopupInputSpec full = dictionaryPopupInputSpecFor(
        registry: r,
        actions: forwarded,
      );
      // 前提：旧做法确实把翻页的非左右键位截走（否则本用例测不到回归）。
      final List<String> turnOnlyKeys = full.keyTokens
          .where(
            (String t) =>
                t != 'ArrowLeft' &&
                t != 'ArrowRight' &&
                dictionaryPopupInputSpecFor(
                  registry: r,
                  actions: turn,
                ).keyTokens.contains(t),
          )
          .toList();
      expect(turnOnlyKeys, isNotEmpty);

      final DictionaryPopupInputSpec spec =
          dictionaryPopupInputSpecArrowPageTurn(
            registry: r,
            scope: ShortcutScope.manga,
            forwardedActions: forwarded,
            pageTurnActions: turn,
          );
      expect(spec.keyTokens, containsAll(<String>['ArrowLeft', 'ArrowRight']));
      expect(spec.keyTokens, contains('Escape'));
      for (final String t in turnOnlyKeys) {
        expect(spec.keyTokens, isNot(contains(t)), reason: t);
      }
      expect(spec.mouseButtons, full.mouseButtons);
    });

    test('漫画页用 dictionaryPopupInputSpecArrowPageTurn 生成弹窗输入表（源码守卫）', () {
      final String src = maskComments(
        File(
          'lib/src/media/manga/reader/manga_fushi_page.dart',
        ).readAsStringSync(),
      );
      expect(src, contains('get dictionaryPopupInputSpec =>'));
      expect(src, contains('dictionaryPopupInputSpecArrowPageTurn('));
    });

    test('用户把左键改绑到别的动作后不再截走弹窗里的左键', () {
      final FushiShortcutRegistry r = registry();
      final ShortcutBindingSet backward = r.bindingsFor(
        ShortcutAction.readerPageBackward,
      );
      r.updateBinding(
        ShortcutAction.readerPageBackward,
        ShortcutBindingSet(
          keyboardBindings: backward.keyboardBindings
              .where((InputBinding b) => b.key != LogicalKeyboardKey.arrowLeft)
              .toList(),
          gamepadBindings: backward.gamepadBindings,
        ),
      );
      final DictionaryPopupInputSpec spec = withPopupArrowPageTurnKeys(
        const DictionaryPopupInputSpec(),
        registry: r,
        scope: ShortcutScope.reader,
        pageTurnActions: const <ShortcutAction>{
          ShortcutAction.readerPageForward,
          ShortcutAction.readerPageBackward,
        },
      );
      expect(spec.keyTokens, <String>['ArrowRight']);
    });

    test('注册表未装载时原样返回', () {
      const DictionaryPopupInputSpec base = DictionaryPopupInputSpec(
        keyTokens: <String>['Escape'],
      );
      expect(
        withPopupArrowPageTurnKeys(
          base,
          registry: FushiShortcutRegistry(),
          scope: ShortcutScope.reader,
          pageTurnActions: const <ShortcutAction>{
            ShortcutAction.readerPageForward,
          },
        ),
        base,
      );
    });

    test('小说执行体：← → 触发的翻页先关弹窗；弹窗回传接回翻页链（源码守卫）', () {
      final String src = maskComments(readReaderPageSource());
      final int exec = src.indexOf('KeyEventResult _executeShortcutAction(');
      final String forward = src.substring(
        src.indexOf('case ShortcutAction.readerPageForward:', exec),
        src.indexOf('case ShortcutAction.readerDismissDict:', exec),
      );
      expect(
        '_dismissDictionaryForArrowPageTurn(keyboardTriggerKey);'
            .allMatches(forward)
            .length,
        2,
      );
      expect(src, contains('get dictionaryPopupInputSpec =>'));
      expect(src, contains('withPopupArrowPageTurnKeys('));
      expect(src, contains('bool onDictionaryPopupInputToken(String token)'));
    });
  });

  group('④ 漫画自己的「反转方向键翻页」开关', () {
    test('reverse 在跨页方向校正结果上整体对调', () {
      for (final bool rtl in <bool>[true, false]) {
        final ShortcutAction? plain = resolveMangaArrowPageTurn(
          key: LogicalKeyboardKey.arrowLeft,
          modifiers: none,
          rtl: rtl,
          boundAction: ShortcutAction.mangaPageBackward,
        );
        final ShortcutAction? reversed = resolveMangaArrowPageTurn(
          key: LogicalKeyboardKey.arrowLeft,
          modifiers: none,
          rtl: rtl,
          boundAction: ShortcutAction.mangaPageBackward,
          reverse: true,
        );
        expect(reversed, isNotNull);
        expect(reversed, isNot(plain), reason: 'rtl=$rtl');
      }
    });

    test('漫画页按自己的偏好传 reverse，小说偏好键不动（源码守卫）', () {
      final String manga = File(
        'lib/src/media/manga/reader/manga_fushi_page.dart',
      ).readAsStringSync();
      expect(manga, contains('reverse: appModel.mangaReverseArrowPageTurn'));
      final String prefs = File(
        'lib/src/models/preferences_repository.dart',
      ).readAsStringSync();
      expect(prefs, contains("'manga_reverse_arrow_page_turn'"));
      final String readerSettings = File(
        'lib/src/reader/reader_settings.dart',
      ).readAsStringSync();
      expect(
        readerSettings,
        contains("'reverse_arrow_page_turn'"),
        reason: '小说的偏好键冻结，不改名、不合并',
      );
    });
  });
}
