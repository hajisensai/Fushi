import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_extension_api_core.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_bundle.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_host_feature.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_messages.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_settings_page.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_storage.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_subtitle_panel.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_video_activity.dart';
import 'package:fushi/src/web_browser/features/study/web_study_session.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

class _MemoryPrefs implements PrefStore {
  final Map<String, dynamic> values = <String, dynamic>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => values[key] = value;
}

class _FakeClock implements WebStudyClockPort {
  final List<String> log = <String>[];

  @override
  void start() => log.add('start');

  @override
  Future<void> stop() async => log.add('stop');

  @override
  void detach() => log.add('detach');

  @override
  void touch() {}

  @override
  void addChars(int c) {}
}

void main() {
  group('扩展存储', () {
    late _MemoryPrefs prefs;
    late bool appPause;
    late WebBrowserExtensionStorage storage;

    setUp(() {
      prefs = _MemoryPrefs();
      appPause = true;
      storage = WebBrowserExtensionStorage(
        prefs: prefs,
        bridged: <String, WebBrowserExtensionBridgedKey>{
          'subtitlePauseOnLookup': (
            read: () => appPause,
            write: (Object? v) async {
              if (v is bool) appPause = v;
            },
          ),
        },
        computed: <String, Object? Function()>{'appLocale': () => 'ja'},
      );
    });

    test('普通键落进设备本地偏好（JSON），只回存在的键', () async {
      final Map<String, WebBrowserExtensionStorageChange> changes =
          await storage.set(<String, Object?>{
            'subtitleOverlayEnabled': true,
            'subtitleStyle': <String, Object?>{'fontSize': 32},
          });
      expect(
        changes.keys,
        containsAll(<String>['subtitleOverlayEnabled', 'subtitleStyle']),
      );
      expect(changes['subtitleOverlayEnabled']!.hadOld, isFalse);
      final Object? raw = prefs.values[kWebBrowserExtensionStoragePref];
      expect(raw, isA<String>());
      expect(jsonDecode(raw! as String), <String, Object?>{
        'subtitleOverlayEnabled': true,
        'subtitleStyle': <String, Object?>{'fontSize': 32},
      });
      expect(
        storage.get(<String>['subtitleOverlayEnabled', 'missing']),
        <String, Object?>{'subtitleOverlayEnabled': true},
      );
      // 同值再写不报变更（chrome 同语义）。
      expect(
        await storage.set(<String, Object?>{'subtitleOverlayEnabled': true}),
        isEmpty,
      );
    });

    test('真源键：扩展读到的是 app 偏好；扩展写回落到 app 偏好、不另存', () async {
      expect(storage.get(<String>['subtitlePauseOnLookup']), <String, Object?>{
        'subtitlePauseOnLookup': true,
      });
      appPause = false; // app 设置页里关掉
      expect(
        storage.get(<String>['subtitlePauseOnLookup'])['subtitlePauseOnLookup'],
        isFalse,
      );
      final Map<String, WebBrowserExtensionStorageChange> changes =
          await storage.set(<String, Object?>{
            'subtitlePauseOnLookup': true,
          }); // 扩展里打开
      expect(appPause, isTrue);
      expect(changes['subtitlePauseOnLookup']!.oldValue, isFalse);
      expect(
        prefs.values.containsKey(kWebBrowserExtensionStoragePref),
        isFalse,
        reason: '真源键不得另存一份',
      );
      // 真源键删不掉（app 偏好总有值）。
      expect(await storage.remove(<String>['subtitlePauseOnLookup']), isEmpty);
    });

    test('现算键只读：扩展写它被忽略；get(null) 带上真源与现算键', () async {
      expect(await storage.set(<String, Object?>{'appLocale': 'en'}), isEmpty);
      expect(storage.get(<String>['appLocale']), <String, Object?>{
        'appLocale': 'ja',
      });
      await storage.set(<String, Object?>{'a': 1});
      expect(storage.get(null), <String, Object?>{
        'a': 1,
        'subtitlePauseOnLookup': true,
        'appLocale': 'ja',
      });
    });

    test('remove 报变更、变更集编码成 chrome.storage.onChanged 形状', () async {
      await storage.set(<String, Object?>{'a': 1});
      final Map<String, WebBrowserExtensionStorageChange> removed =
          await storage.remove(<String>['a', 'nope']);
      expect(webBrowserExtensionChangesJson(removed), <String, Object?>{
        'a': <String, Object?>{'oldValue': 1},
      });
      final Map<String, WebBrowserExtensionStorageChange> added = await storage
          .set(<String, Object?>{'b': 2});
      expect(webBrowserExtensionChangesJson(added), <String, Object?>{
        'b': <String, Object?>{'newValue': 2},
      });
    });

    test('appThemeMirror 只取镜像键，带当前明暗', () {
      final Map<String, Object?> m = webBrowserExtensionThemeMirror(
        colors: (String s) => <String, String>{
          '--md-primary': s == 'dark' ? '#fff' : '#000',
          '--fushi-popup-zoom': '1',
        },
        dark: true,
      );
      expect(m['current'], 'dark');
      expect(m['dark'], <String, String>{'--md-primary': '#fff'});
      expect(m['light'], <String, String>{'--md-primary': '#000'});
    });
  });

  group('消息路由', () {
    late List<(String, Map<String, dynamic>)> apiCalls;
    late List<String> events;
    late WebBrowserExtensionHostServices services;

    setUp(() {
      apiCalls = <(String, Map<String, dynamic>)>[];
      events = <String>[];
      services = WebBrowserExtensionHostServices(
        api: (String path, Map<String, dynamic> body) async {
          apiCalls.add((path, body));
          if (path == FushiExtensionApiCore.subtitleParsePath) {
            return const FushiExtensionApiResponse.error(
              400,
              'Missing filename/content',
            );
          }
          return FushiExtensionApiResponse.json(<String, dynamic>{
            'tracks': <Object?>[],
            'fonts': <Object?>[
              <String, Object?>{'id': 'f1'},
            ],
          });
        },
        openSidePanel: () => events.add('panel'),
        openOptions: () => events.add('options'),
        dismissLookup: () => events.add('dismiss'),
        onStudySample: (Map<String, dynamic> s) =>
            events.add('study:${s['playing']}'),
      );
    });

    test(
      'youtubeCaptions → 核心路由，回 {ok,status,data}（background.js 同形）',
      () async {
        final Map<String, Object?> r = await routeWebBrowserExtensionMessage(
          <String, dynamic>{'type': 'youtubeCaptions', 'videoId': 'abc'},
          services,
        );
        expect(apiCalls.single.$1, FushiExtensionApiCore.youtubeCaptionsPath);
        expect(apiCalls.single.$2, <String, dynamic>{
          'videoId': 'abc',
          'preferLang': 'ja',
        });
        expect(r['ok'], isTrue);
        expect(r['status'], 200);
        expect(r['data'], isA<Map<String, dynamic>>());
      },
    );

    test('失败回 ok:false + error，data 为 null', () async {
      final Map<String, Object?> r = await routeWebBrowserExtensionMessage(
        <String, dynamic>{'type': 'parseSubtitle', 'filename': 'a.srt'},
        services,
      );
      expect(r['ok'], isFalse);
      expect(r['status'], 400);
      expect(r['data'], isNull);
      expect(r['error'], 'Missing filename/content');
    });

    test('subtitleSearch 只透传扩展给的字段', () async {
      await routeWebBrowserExtensionMessage(<String, dynamic>{
        'type': 'subtitleSearch',
        'query': 'x',
        'episode': 3,
        'anime': 'no',
      }, services);
      expect(apiCalls.single.$2, <String, dynamic>{'query': 'x', 'episode': 3});
    });

    test('subtitleFonts 回 fonts / recommended', () async {
      final Map<String, Object?> r = await routeWebBrowserExtensionMessage(
        <String, dynamic>{'type': 'subtitleFonts'},
        services,
      );
      expect(r['ok'], isTrue);
      expect(r['fonts'], hasLength(1));
      expect(r['recommended'], isEmpty);
    });

    test('studySample：先通知（阅读计时避让）再落库', () async {
      final Map<String, Object?> r = await routeWebBrowserExtensionMessage(
        <String, dynamic>{
          'type': 'studySample',
          'sample': <String, dynamic>{'mediaKey': 'web:x', 'playing': true},
        },
        services,
      );
      expect(events, <String>['study:true']);
      expect(apiCalls.single.$1, FushiExtensionApiCore.studyPath);
      expect(r['ok'], isTrue);
    });

    test('侧栏 / 设置 / 关弹窗交给 app；不支持的消息回 ok:false', () async {
      for (final String type in <String>[
        'openSubtitleSidePanel',
        'openOptions',
        'fushiLookupDismiss',
      ]) {
        expect(
          (await routeWebBrowserExtensionMessage(<String, dynamic>{
            'type': type,
          }, services))['ok'],
          isTrue,
        );
      }
      expect(events, <String>['panel', 'options', 'dismiss']);
      for (final String type in <String>[
        'lookup',
        'mine',
        'beginClip',
        'nfFinish',
        'drawerSelfTab',
        'fushiInjectEmbeddedFrame',
      ]) {
        expect(
          await routeWebBrowserExtensionMessage(<String, dynamic>{
            'type': type,
          }, services),
          kWebBrowserExtensionUnsupported,
          reason: type,
        );
      }
    });
  });

  group('宿主功能：页内调用', () {
    late _MemoryPrefs prefs;
    late WebBrowserExtensionHostFeature feature;
    late WebBrowserTab tab;
    late WebBrowserVideoActivity activity;

    setUp(() {
      prefs = _MemoryPrefs();
      activity = WebBrowserVideoActivity();
      feature = WebBrowserExtensionHostFeature(
        storage: WebBrowserExtensionStorage(prefs: prefs),
        api: (String path, Map<String, dynamic> body) async =>
            FushiExtensionApiResponse.json(<String, dynamic>{'ok': true}),
        lookup: null,
        videoActivity: activity,
        loadParts: () async => const WebBrowserExtensionBundleParts(
          runtime: '',
          scripts: <({String path, String source})>[],
          bridges: <({List<String> matches, String source})>[],
          contentCss: '',
          iconDataUrl: '',
        ),
        loadAsset: (String asset) async => '{"k":"$asset"}',
        secret: 'sek',
      );
      tab = WebBrowserTab(id: 't1', url: Uri.parse('https://www.youtube.com/'));
    });

    tearDown(() {
      feature.dispose();
      activity.dispose();
    });

    test('整栈脚本带上本会话密钥，document-start 注入', () async {
      final String? bundle = await feature.bundleReady;
      expect(bundle, contains('var __fushiExtSecret = "sek";'));
      expect(feature.userScripts(), hasLength(1));
    });

    test('存储往返', () async {
      await feature.handleCall(tab, <String, dynamic>{
        'op': 'storageSet',
        'items': <String, Object?>{'subtitleHidden': true},
      });
      expect(
        await feature.handleCall(tab, <String, dynamic>{
          'op': 'storageGet',
          'keys': <Object?>['subtitleHidden'],
        }),
        <String, Object?>{'subtitleHidden': true},
      );
      await feature.handleCall(tab, <String, dynamic>{
        'op': 'storageRemove',
        'keys': <Object?>['subtitleHidden'],
      });
      expect(feature.readStorage(null), isEmpty);
    });

    test('扩展资源只开放界面字典', () async {
      expect(
        await feature.handleCall(tab, <String, dynamic>{
          'op': 'asset',
          'path': 'locales/zh-CN.json',
        }),
        '{"k":"${kWebBrowserExtensionRoot}locales/zh-CN.json"}',
      );
      for (final String bad in <String>[
        'background.js',
        '../secret',
        'locales/../x.json',
      ]) {
        expect(
          await feature.handleCall(tab, <String, dynamic>{
            'op': 'asset',
            'path': bad,
          }),
          isNull,
          reason: bad,
        );
      }
    });

    test('「打开字幕列表」消息开侧栏；关标签页收侧栏', () async {
      await feature.handleCall(tab, <String, dynamic>{
        'op': 'message',
        'message': <String, Object?>{'type': 'openSubtitleSidePanel'},
      });
      expect(feature.sidePanelOpenFor(tab), isTrue);
      feature.onTabClosed(tab);
      expect(feature.sidePanelOpenFor(tab), isFalse);
    });

    test('沉浸样本登记视频在播（无痕页不登记）', () async {
      await feature.handleCall(tab, <String, dynamic>{
        'op': 'message',
        'message': <String, Object?>{
          'type': 'studySample',
          'sample': <String, Object?>{'playing': true},
        },
      });
      expect(activity.isPlaying('t1'), isTrue);
      final WebBrowserTab incognito = WebBrowserTab(
        id: 't2',
        url: null,
        incognito: true,
      );
      await feature.handleCall(incognito, <String, dynamic>{
        'op': 'message',
        'message': <String, Object?>{
          'type': 'studySample',
          'sample': <String, Object?>{'playing': true},
        },
      });
      expect(activity.isPlaying('t2'), isFalse);
    });
  });

  group('阅读计时避让网页视频', () {
    test('webStudyClockMayRun：视频在播即不走表', () {
      expect(
        webStudyClockMayRun(
          tabActive: true,
          appForeground: true,
          pageVisible: true,
          japanesePage: true,
          interacted: true,
          videoPlaying: true,
        ),
        isFalse,
      );
    });

    test('会话：视频开播停表，停播（或样本过期）后续走', () async {
      final List<_FakeClock> clocks = <_FakeClock>[];
      final WebStudySession s = WebStudySession(
        incognito: false,
        clockFactory: ({required String mediaKey, required String title}) {
          final _FakeClock c = _FakeClock();
          clocks.add(c);
          return c;
        },
      )..setTabActive(true);
      await s.navigate(Uri.parse('https://a.jp/1'));
      s.report((
        visible: true,
        interacted: true,
        japanese: true,
        chars: 0,
      ), title: 'a');
      expect(s.running, isTrue);
      s.setVideoPlaying(true);
      expect(s.running, isFalse);
      s.setVideoPlaying(false);
      expect(s.running, isTrue);
    });

    test('在播登记：样本过期自动回落为停', () async {
      final WebBrowserVideoActivity a = WebBrowserVideoActivity(
        staleAfter: const Duration(milliseconds: 20),
      );
      a.report('t', playing: true);
      expect(a.isPlaying('t'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(a.isPlaying('t'), isFalse);
      a.dispose();
    });
  });

  group('字幕侧栏', () {
    test('解析侧栏状态、活动句二分查找', () {
      final WebBrowserSubtitlePanelState? s = parseWebBrowserSubtitlePanelState(
        <String, Object?>{
          'ok': true,
          'videoKey': 'yt:abc',
          'hasVideo': true,
          'activeLang': 'ja',
          'currentTimeMs': 2500,
          'offsetMs': -300,
          'tracks': <Object?>[
            <String, Object?>{'lang': 'ja', 'label': '日本語', 'signature': 's1'},
          ],
          'cues': <Object?>[
            <String, Object?>{'startMs': 0, 'endMs': 1000, 'text': 'a'},
            <String, Object?>{'startMs': 2000, 'endMs': 3000, 'text': 'b'},
          ],
        },
      );
      expect(s, isNotNull);
      expect(s!.tracks.single.label, '日本語');
      expect(s.cueIdentity, 'yt:abc|ja|-300|s1');
      expect(webBrowserSubtitleActiveIndex(s.cues!, s.currentTimeMs), 1);
      expect(webBrowserSubtitleActiveIndex(s.cues!, 1500), -1);
      expect(
        parseWebBrowserSubtitlePanelState(<String, Object?>{'ok': false}),
        isNull,
      );
    });
  });

  test('扩展设置页：英文源字典解析', () {
    expect(
      parseWebBrowserExtensionEnglishLocale(
        "x.FUSHI_I18N_EN = {\n  a_b: 'Don\\'t',\n  // c\n  c_d: 'Two words',\n};",
      ),
      <String, String>{'a_b': "Don't", 'c_d': 'Two words'},
    );
  });
}
