import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_storage.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_strings.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_subtitle_panel.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:material_ui/material_ui.dart';

/// app 原生字幕侧栏与扩展 Side Panel 功能对齐：工具排（本地文件 / 在线搜索 / 字号 / 跟随 /
/// 设置）、选轨、偏移（±0.1 / ±0.5 / 手填 / 重置）、行内空白跳转。数据与执行一律经扩展同一份
/// `fushiSubtitleSidePanel*`（页面）与 `parseSubtitle` / `subtitleSearch` / `subtitleFetch`
/// （后台）消息，这里用假页面 / 假后台核对发出去的消息与界面反馈。
void main() {
  late Map<String, String> en;

  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.en);
    en = parseWebBrowserExtensionEnglishLocale(
      File('assets/browser_extension/locales/en.js').readAsStringSync(),
    );
  });

  setUp(() => WebBrowserExtensionStrings.instance.debugSet(en));
  tearDown(WebBrowserExtensionStrings.instance.debugReset);

  group('纯函数（与扩展 side-panel.js 同律）', () {
    test('偏移读数 / 手填解析', () {
      expect(formatWebBrowserSubtitleOffset(0), '0');
      expect(formatWebBrowserSubtitleOffset(4), '0');
      expect(formatWebBrowserSubtitleOffset(-4), '0');
      expect(formatWebBrowserSubtitleOffset(500), '+0.5');
      expect(formatWebBrowserSubtitleOffset(-1250), '-1.25');
      expect(formatWebBrowserSubtitleOffset(42000), '+42');
      expect(parseWebBrowserSubtitleOffset('1.5'), 1500);
      expect(parseWebBrowserSubtitleOffset('－0，5秒'), -500);
      expect(parseWebBrowserSubtitleOffset('+2s'), 2000);
      expect(parseWebBrowserSubtitleOffset('.25'), 250);
      expect(parseWebBrowserSubtitleOffset('abc'), isNull);
      expect(parseWebBrowserSubtitleOffset('3601'), isNull);
    });

    test('跟随定位：间隙取最近一句，片头 / 片尾夹到两端', () {
      const List<WebBrowserSubtitleCue> cues = <WebBrowserSubtitleCue>[
        WebBrowserSubtitleCue(startMs: 1000, endMs: 2000, text: 'a'),
        WebBrowserSubtitleCue(startMs: 5000, endMs: 6000, text: 'b'),
      ];
      expect(webBrowserSubtitleNearestIndex(cues, 0), 0);
      expect(webBrowserSubtitleNearestIndex(cues, 1500), 0);
      expect(webBrowserSubtitleNearestIndex(cues, 2500), 0);
      expect(webBrowserSubtitleNearestIndex(cues, 4800), 1);
      expect(webBrowserSubtitleNearestIndex(cues, 9000), 1);
      expect(
        webBrowserSubtitleNearestIndex(const <WebBrowserSubtitleCue>[], 0),
        -1,
      );
    });

    test('轨状态带句数', () {
      final WebBrowserSubtitlePanelState? s = parseWebBrowserSubtitlePanelState(
        <String, Object?>{
          'ok': true,
          'tracks': <Object?>[
            <String, Object?>{'lang': 'ja', 'length': 12, 'signature': 'x'},
          ],
        },
      );
      expect(s!.tracks.single.length, 12);
    });
  });

  group('侧栏', () {
    late _FakePage page;
    late List<Map<String, Object?>> runtime;
    late Object? Function(Map<String, Object?> m) runtimeReply;
    late WebBrowserExtensionStorage storage;
    late int settingsOpened;
    late List<WebBrowserSubtitleFile> pickResult;

    setUp(() {
      page = _FakePage();
      runtime = <Map<String, Object?>>[];
      runtimeReply = (_) => null;
      storage = WebBrowserExtensionStorage(prefs: _MemoryPrefs());
      settingsOpened = 0;
      pickResult = <WebBrowserSubtitleFile>[];
    });

    Future<void> pump(WidgetTester tester, {double width = 280}) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: Scaffold(
              body: WebBrowserSubtitlePanel(
                request: page.handle,
                runtime: (Map<String, Object?> m) async {
                  runtime.add(m);
                  return runtimeReply(m);
                },
                storage: storage,
                onOpenSettings: () => settingsOpened++,
                tabTitle: () => 'Frieren',
                pickFiles: () async => pickResult,
                onClose: () {},
                pollInterval: const Duration(hours: 1),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    WebBrowserSubtitlePanelState$ stateOf(WidgetTester tester) =>
        tester.state<WebBrowserSubtitlePanelState$>(
          find.byType(WebBrowserSubtitlePanel),
        );

    Finder key(String k) => find.byKey(ValueKey<String>(k));

    testWidgets('空状态与状态行用扩展文案；280dp 宽不溢出', (WidgetTester tester) async {
      page.cues.clear();
      page.tracks.clear();
      await pump(tester);
      expect(find.text(en['sp_empty_no_subtitles']!), findsOneWidget);
      expect(find.text(en['sp_status_waiting_subtitles']!), findsOneWidget);
      for (final String k in <String>[
        'load',
        'search',
        'smaller',
        'larger',
        'follow',
        'settings',
      ]) {
        expect(key('web-browser-subtitle-panel-$k'), findsOneWidget, reason: k);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('有轨：轨按钮带句数，偏移行 ±0.5 / ±0.1 / 手填 / 重置都走扩展消息', (
      WidgetTester tester,
    ) async {
      await pump(tester);
      expect(find.textContaining('Japanese（2）'), findsOneWidget);
      expect(find.text(en['sp_status_connected']!), findsOneWidget);

      await tester.tap(find.text('+0.5'));
      await tester.pump();
      expect(page.offsetMs, 500);
      await tester.tap(find.text('−0.1'));
      await tester.pump();
      expect(page.offsetMs, 400);
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: key('web-browser-subtitle-panel-offset'),
                matching: find.byType(EditableText),
              ),
            )
            .controller
            .text,
        '+0.4',
      );

      await tester.tap(key('web-browser-subtitle-panel-offset'));
      await tester.pump();
      await tester.enterText(key('web-browser-subtitle-panel-offset'), '-42');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump();
      expect(page.offsetMs, -42000);
      expect(
        page.received.where(
          (Map<String, Object?> m) => m['absoluteMs'] == -42000,
        ),
        hasLength(1),
      );

      await tester.tap(key('web-browser-subtitle-panel-offset-reset'));
      await tester.pump();
      expect(page.offsetMs, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('字号 A- / A+ 与跟随开关写进扩展存储；设置钮打开设置', (WidgetTester tester) async {
      await pump(tester);
      expect(stateOf(tester).fontScale, 1);
      await tester.tap(key('web-browser-subtitle-panel-larger'));
      await tester.pump();
      expect(stateOf(tester).fontScale, 1.15);
      expect(
        storage.get(<String>[kWebBrowserSubtitleFontStepKey]),
        <String, Object?>{kWebBrowserSubtitleFontStepKey: 2},
      );
      await tester.tap(key('web-browser-subtitle-panel-smaller'));
      await tester.tap(key('web-browser-subtitle-panel-smaller'));
      await tester.pump();
      expect(stateOf(tester).fontScale, 0.85);

      expect(stateOf(tester).following, isTrue);
      await tester.tap(key('web-browser-subtitle-panel-follow'));
      await tester.pump();
      expect(stateOf(tester).following, isFalse);
      expect(
        storage.get(<String>[kWebBrowserSubtitleAutoScrollKey]),
        <String, Object?>{kWebBrowserSubtitleAutoScrollKey: false},
      );
      // 设置页 / 页内面板改了同一个键：侧栏就地跟上。
      await storage.set(<String, Object?>{
        kWebBrowserSubtitleAutoScrollKey: true,
      });
      await tester.pump();
      expect(stateOf(tester).following, isTrue);

      await tester.tap(key('web-browser-subtitle-panel-settings'));
      expect(settingsOpened, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('手动拖动列表暂停跟随（不改偏好）', (WidgetTester tester) async {
      page.cues
        ..clear()
        ..addAll(<Map<String, Object?>>[
          for (int i = 0; i < 80; i++)
            <String, Object?>{
              'startMs': i * 1000,
              'endMs': i * 1000 + 900,
              'text': '台詞$i',
            },
        ]);
      await pump(tester);
      await tester.drag(find.text('台詞3'), const Offset(0, -300));
      await tester.pump();
      expect(stateOf(tester).following, isFalse);
      expect(storage.get(<String>[kWebBrowserSubtitleAutoScrollKey]), isEmpty);
    });

    testWidgets('点行内空白 = 跳到这句', (WidgetTester tester) async {
      await pump(tester);
      final Rect row = tester.getRect(find.text('こんにちは'));
      await tester.tapAt(Offset(row.right + 40, row.center.dy));
      await tester.pump();
      expect(
        page.received.where(
          (Map<String, Object?> m) =>
              m['type'] == 'fushiSubtitleSidePanelSeek' && m['ms'] == 1000,
        ),
        hasLength(1),
      );
    });

    testWidgets('加载本地字幕：parseSubtitle → InstallTrack；超 8 MB 拒收', (
      WidgetTester tester,
    ) async {
      runtimeReply = (Map<String, Object?> m) => <String, Object?>{
        'ok': true,
        'data': <String, Object?>{
          'cues': <Object?>[
            <String, Object?>{'startMs': 0, 'endMs': 1000, 'text': '外挂'},
          ],
        },
      };
      pickResult = <WebBrowserSubtitleFile>[
        (name: 'ep1.srt', bytes: Uint8List.fromList(utf8.encode('1\n...'))),
        (
          name: 'huge.srt',
          bytes: Uint8List(kWebBrowserSubtitleFileMaxBytes + 1),
        ),
      ];
      await pump(tester);
      await tester.tap(key('web-browser-subtitle-panel-load'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(runtime.single['type'], 'parseSubtitle');
      expect(runtime.single['filename'], 'ep1.srt');
      expect(runtime.single['content'], '1\n...');
      final Map<String, Object?> install = page.received.lastWhere(
        (Map<String, Object?> m) =>
            m['type'] == 'fushiSubtitleSidePanelInstallTrack',
      );
      expect(install['filename'], 'ep1.srt');
      expect((install['cues']! as List<Object?>).length, 1);
      expect(find.text('外挂'), findsOneWidget);
      expect(find.text(en['subtitle_file_too_large']!), findsOneWidget);
    });

    testWidgets('在线搜索：预填标签页标题，带集数搜，点候选 fetch 后装轨', (WidgetTester tester) async {
      runtimeReply = (Map<String, Object?> m) => switch (m['type']) {
        'subtitleSearch' => <String, Object?>{
          'ok': true,
          'data': <String, Object?>{
            'ok': true,
            'candidates': <Object?>[
              <String, Object?>{
                'handle': 'h1',
                'fileName': 'Frieren - 03.srt',
                'provider': 'jimaku',
                'episode': 3,
              },
            ],
            'failures': <Object?>[
              <String, Object?>{'provider': 'opensubtitles'},
            ],
          },
        },
        'subtitleFetch' => <String, Object?>{
          'ok': true,
          'data': <String, Object?>{
            'ok': true,
            'filename': 'Frieren - 03.srt',
            'provider': 'jimaku',
            'cues': <Object?>[
              <String, Object?>{'startMs': 0, 'endMs': 1000, 'text': '在线'},
            ],
          },
        },
        _ => null,
      };
      await pump(tester);
      await tester.tap(key('web-browser-subtitle-panel-search'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Frieren'), findsOneWidget);
      await tester.enterText(key('web-browser-subtitle-panel-episode'), '3');
      await tester.tap(key('web-browser-subtitle-panel-go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(runtime.last, <String, Object?>{
        'type': 'subtitleSearch',
        'query': 'Frieren',
        'episode': 3,
      });
      expect(find.text('Frieren - 03.srt'), findsOneWidget);
      expect(find.textContaining('Jimaku'), findsOneWidget);
      expect(find.textContaining('OpenSubtitles'), findsOneWidget);

      await tester.tap(find.text('Frieren - 03.srt'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(runtime.last, <String, Object?>{
        'type': 'subtitleFetch',
        'handle': 'h1',
      });
      expect(page.received.last['type'], 'fushiSubtitleSidePanelInstallTrack');
      expect(find.text('在线'), findsOneWidget);
      expect(find.text('Frieren - 03.srt'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

/// 假页面：subtitle-panel.js 那一侧的状态与执行端。
class _FakePage {
  final List<Map<String, Object?>> received = <Map<String, Object?>>[];
  final List<Map<String, Object?>> tracks = <Map<String, Object?>>[
    <String, Object?>{
      'lang': 'ja',
      'label': 'Japanese',
      'length': 2,
      'signature': 's1',
    },
  ];
  final List<Map<String, Object?>> cues = <Map<String, Object?>>[
    <String, Object?>{'startMs': 1000, 'endMs': 2000, 'text': 'こんにちは'},
    <String, Object?>{'startMs': 3000, 'endMs': 4000, 'text': 'さようなら'},
  ];
  int offsetMs = 0;
  int sig = 1;

  Map<String, Object?> _state(bool includeCues) => <String, Object?>{
    'ok': true,
    'videoKey': 'v',
    'hasVideo': true,
    'activeLang': tracks.isEmpty ? null : tracks.last['lang'],
    'currentTimeMs': 1500,
    'offsetMs': offsetMs,
    'tracks': tracks,
    'cues': includeCues ? cues : null,
  };

  Future<Object?> handle(Map<String, Object?> m) async {
    received.add(m);
    switch (m['type']) {
      case 'fushiSubtitleSidePanelState':
        return _state(m['includeCues'] == true);
      case 'fushiSubtitleSidePanelOffset':
        if (m['reset'] == true) {
          offsetMs = 0;
        } else if (m['absoluteMs'] is int) {
          offsetMs = m['absoluteMs']! as int;
        } else {
          offsetMs += (m['deltaMs'] as int?) ?? 0;
        }
        return _state(true);
      case 'fushiSubtitleSidePanelInstallTrack':
        final List<Object?> next = m['cues']! as List<Object?>;
        cues
          ..clear()
          ..addAll(<Map<String, Object?>>[
            for (final Object? c in next) Map<String, Object?>.from(c! as Map),
          ]);
        tracks.add(<String, Object?>{
          'lang': 'ext${++sig}',
          'label': '${m['filename']}',
          'length': cues.length,
          'signature': 's$sig',
        });
        return _state(true);
      case 'fushiSubtitleSidePanelSeek':
        return <String, Object?>{'ok': true};
    }
    return null;
  }
}

class _MemoryPrefs implements PrefStore {
  final Map<String, dynamic> values = <String, dynamic>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => values[key] = value;
}
