import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/page_focus_ownership.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show
        kLyricsBridgedActions,
        kLyricsKeyBridgeSpaceToken,
        lyricsKeyBridgeTokens,
        parseLyricsKeyBridgeToken,
        readerCanOwnFocus,
        resolveSpreadKeyBridgeAction;
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi_audio/fushi_audio.dart';

import 'reader_fushi_page_source_corpus.dart';

/// 反馈 NmpRV-amTY / PHs18V7U3K：歌词模式里点了「↺ 跟随音频」后 Space / Esc 失灵；
/// 点词出查词弹窗后 Esc 关不掉弹窗。
///
/// 根因：歌词独立文档是「二等输入公民」——① 没有键桥，WebView 抢走 OS 焦点后按键只到
/// DOM；② 胶囊 / 中键点句不回 Dart、从不收回焦点；③ 焦点判据以「歌词自有焦点路径」为由
/// 在 popupRendered / appResumed / overlayClosed 上一律对歌词让位，而这条路径并不存在。
/// 修：歌词模式下 `_focusNode` 仍是唯一键盘入口——判据抽成纯函数按矩阵钉死；歌词文档
/// 注入共享 webViewKeyBridgeScript（onLyricsKey），解析走与正文 / spread 同一套；所有指针
/// 手势回 Dart 收回焦点。WebView 内真实按键需 Windows itest，这里是可落地的最强层：纯函数
/// 矩阵 + 键表 / 反解析单测 + 生成 HTML 契约 + 源码接线守卫。
void main() {
  AudioCue cue(int i) => AudioCue()
    ..id = i + 1
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = i
    ..textFragmentId = ''
    ..text = 'cue $i'
    ..startMs = i * 1000
    ..endMs = i * 1000 + 900
    ..audioFileIndex = 0;

  group('readerCanOwnFocus 矩阵', () {
    bool can(
      FocusReclaimCause cause, {
      bool lyricsMode = false,
      bool dictionaryShown = false,
      bool chromeHasFocus = false,
      bool contentReady = true,
      bool caretBusy = false,
      bool routeIsCurrent = true,
    }) => readerCanOwnFocus(
      cause,
      lyricsMode: lyricsMode,
      dictionaryShown: dictionaryShown,
      chromeHasFocus: chromeHasFocus,
      contentReady: contentReady,
      caretBusy: caretBusy,
      routeIsCurrent: routeIsCurrent,
    );

    test('popupRendered：弹窗可见就收回，歌词模式也一样（PHs18V7U3K）', () {
      expect(
        can(
          FocusReclaimCause.popupRendered,
          lyricsMode: true,
          dictionaryShown: true,
        ),
        isTrue,
      );
      expect(
        can(FocusReclaimCause.popupRendered, dictionaryShown: true),
        isTrue,
      );
      expect(can(FocusReclaimCause.popupRendered, lyricsMode: true), isFalse);
      expect(can(FocusReclaimCause.popupRendered), isFalse);
    });

    test('overlayClosed / appResumed：歌词模式下同样归位（不再一律让位）', () {
      for (final FocusReclaimCause c in <FocusReclaimCause>[
        FocusReclaimCause.overlayClosed,
        FocusReclaimCause.appResumed,
      ]) {
        expect(can(c, lyricsMode: true), isTrue, reason: '$c');
        // 歌词态不看正文是否就绪（歌词是独立文档）。
        expect(can(c, lyricsMode: true, contentReady: false), isTrue);
        // 弹窗 / 别的路由压着 / 光标态时仍不抢。
        expect(can(c, lyricsMode: true, dictionaryShown: true), isFalse);
        expect(can(c, lyricsMode: true, routeIsCurrent: false), isFalse);
        expect(can(c, lyricsMode: true, caretBusy: true), isFalse);
        // 正文态行为不变。
        expect(can(c), isTrue);
        expect(can(c, contentReady: false), isFalse);
      }
    });

    test('contentReady / surfaceRemounted：歌词态仍不抢（BUG-767 加载后夺焦闪烁）', () {
      for (final FocusReclaimCause c in <FocusReclaimCause>[
        FocusReclaimCause.contentReady,
        FocusReclaimCause.surfaceRemounted,
      ]) {
        expect(can(c, lyricsMode: true), isFalse, reason: '$c');
        expect(can(c), isTrue);
        expect(can(c, contentReady: false), isFalse);
        expect(can(c, dictionaryShown: true), isFalse);
        expect(can(c, routeIsCurrent: false), isFalse);
        expect(can(c, caretBusy: true), isFalse);
      }
    });

    test('gesture / chromeToggled / popupDismissed 语义不变', () {
      expect(can(FocusReclaimCause.gesture, lyricsMode: true), isTrue);
      expect(can(FocusReclaimCause.gesture, dictionaryShown: true), isFalse);
      expect(can(FocusReclaimCause.gesture, chromeHasFocus: true), isFalse);
      expect(can(FocusReclaimCause.chromeToggled, lyricsMode: true), isTrue);
      expect(
        can(FocusReclaimCause.popupDismissed, contentReady: false),
        isTrue,
      );
    });
  });

  group('歌词文档键桥：键表与反解析', () {
    FushiShortcutRegistry registry() =>
        FushiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

    test('裸 Space 恒在；Esc（返回上一级）按注册表绑定导出；Space 只出一次', () {
      final List<String> tokens = lyricsKeyBridgeTokens(registry());
      expect(tokens.first, kLyricsKeyBridgeSpaceToken);
      expect(tokens, contains('Escape'));
      expect(tokens.where((String t) => t == 'Space'), isEmpty);
      expect(tokens.toSet(), hasLength(tokens.length), reason: '无重复 token');
    });

    test('注册表未装载：只剩 Space（下一次装载文档拿到真表）', () {
      expect(lyricsKeyBridgeTokens(FushiShortcutRegistry()), <String>[
        kLyricsKeyBridgeSpaceToken,
      ]);
    });

    test('token 反解析：Space 走 Space 解析，Esc 解析成返回上一级', () {
      expect(parseLyricsKeyBridgeToken(' ')?.space, isTrue);
      expect(parseLyricsKeyBridgeToken('Space')?.space, isTrue);
      expect(parseLyricsKeyBridgeToken('not a key !!'), isNull);
      final ({bool space, InputBinding? binding})? esc =
          parseLyricsKeyBridgeToken('Escape');
      expect(esc?.space, isFalse);
      expect(esc?.binding?.key, LogicalKeyboardKey.escape);
      expect(
        resolveSpreadKeyBridgeAction(
          registry(),
          esc!.binding!,
          actions: kLyricsBridgedActions,
        ),
        ShortcutAction.globalBack,
      );
    });

    test('改键跟随：返回上一级改绑后键表随之变化', () {
      final FushiShortcutRegistry r = registry();
      const InputBinding custom = InputBinding(key: LogicalKeyboardKey.keyQ);
      r.updateBinding(
        ShortcutAction.globalBack,
        r
            .bindingsFor(ShortcutAction.globalBack)
            .copyWith(keyboardBindings: <InputBinding>[custom]),
      );
      final List<String> tokens = lyricsKeyBridgeTokens(r);
      expect(tokens, contains(custom.serialize()));
      expect(tokens, isNot(contains('Escape')));
    });
  });

  group('歌词文档 HTML 契约', () {
    String html({String keyBridgeScript = ''}) => LyricsModeHtml.generate(
      cues: <AudioCue>[cue(0), cue(1)],
      currentIndex: 0,
      backgroundColor: 'transparent',
      textColor: 'rgba(0,0,0,1.00)',
      accentColor: 'rgba(255,220,0,1.00)',
      fontSize: 20,
      followLabel: 'Follow audio',
      keyBridgeScript: keyBridgeScript,
    );

    test('宿主给的键桥脚本原样进文档', () {
      const String marker = '/*__lyrics_key_bridge_marker__*/';
      expect(html(keyBridgeScript: marker), contains(marker));
    });

    test('「跟随音频」胶囊回 Dart（收回焦点），不只做纯 JS 恢复', () {
      final String doc = html();
      final int pill = doc.indexOf("document.getElementById('ly-follow')");
      expect(pill, greaterThanOrEqualTo(0));
      final String block = doc.substring(pill, doc.indexOf('})();', pill));
      expect(block, contains("callHandler('onLyricsFollowResume')"));
      expect(block, contains('_lyResume()'));
    });
  });

  group('阅读器接线守卫', () {
    final String src = readReaderPageSource();

    String handler(String name) {
      // 只认注册处（后面紧跟 callback），不认生成键桥脚本时的同名 handlerName 实参。
      final RegExpMatch? m = RegExp(
        "handlerName: '${RegExp.escape(name)}',\\s*callback:",
      ).firstMatch(src);
      expect(m, isNotNull, reason: name);
      final int at = m!.start;
      final int end = src.indexOf('addJavaScriptHandler(', at);
      return src.substring(at, end < 0 ? src.length : end);
    }

    test('歌词文档装载时注入 onLyricsKey 键桥（按注册表当前绑定）', () {
      expect(
        src,
        contains(
          'keyBridgeScript: webViewKeyBridgeScript(\n'
          "        handlerName: 'onLyricsKey',\n"
          '        keys: lyricsKeyBridgeTokens(appModel.shortcutRegistry),',
        ),
      );
    });

    test('onLyricsKey：Space 走正文同款解析，其余走动作集反解析，执行后收回焦点', () {
      final String body = handler('onLyricsKey');
      expect(body, contains('_resolveWebViewSpaceAction()'));
      expect(body, contains('actions: kLyricsBridgedActions'));
      expect(body, contains('_executeShortcutAction(action)'));
      expect(
        body,
        contains('_focusOwnership.reclaim(FocusReclaimCause.gesture)'),
      );
    });

    test('胶囊与中键点句都收回焦点', () {
      for (final String name in <String>[
        'onLyricsFollowResume',
        'onLyricsPointerSeek',
      ]) {
        expect(
          handler(name),
          contains('_focusOwnership.reclaim(FocusReclaimCause.gesture)'),
          reason: name,
        );
      }
    });

    test('整页焦点判据委托给纯函数（不再在页面里另写一份歌词让位）', () {
      final int start = src.indexOf(
        'bool _canOwnReaderFocus(FocusReclaimCause cause) {',
      );
      expect(start, greaterThanOrEqualTo(0));
      final String body = src.substring(start, src.indexOf('\n  }', start));
      expect(body, contains('readerCanOwnFocus('));
      expect(body, contains('lyricsMode: _lyricsMode'));
      expect(src, isNot(contains('_lyricsMode ? false : isDictionaryShown')));
    });
  });
}
