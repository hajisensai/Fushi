import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/web_video_bridge.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/features/youtube_subtitles/youtube_subtitles_feature.dart';
import 'package:fushi/src/web_browser/features/youtube_subtitles/youtube_subtitles_scripts.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:material_ui/material_ui.dart';

class _MemoryPrefs implements PrefStore {
  final Map<String, dynamic> values = <String, dynamic>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => values[key] = value;
}

/// flutter test 的 cwd 是 fushi 包根：直接读磁盘上的资产（与 rootBundle 同一份文件）。
Future<String> _readAsset(String asset) => File(asset).readAsString();

String? _resolveNode() {
  final String exe = Platform.isWindows ? 'node.exe' : 'node';
  final String separator = Platform.isWindows ? ';' : ':';
  for (final String dir in (Platform.environment['PATH'] ?? '').split(
    separator,
  )) {
    if (dir.isEmpty) continue;
    final File candidate = File('$dir${Platform.pathSeparator}$exe');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}

void main() {
  group('脚本拼装', () {
    test('资产顺序：bridge → adapters → providers → 字幕层，前三样是扩展镜像', () {
      expect(kWebBrowserYoutubeSubtitlesAssets, <String>[
        kWebVideoYoutubeBridgeAsset,
        kWebVideoAdaptersAsset,
        kWebVideoProvidersAsset,
        kWebBrowserYoutubeSubtitlesAsset,
      ]);
      for (final String asset in kWebBrowserYoutubeSubtitlesAssets.take(3)) {
        expect(asset, startsWith('assets/browser_extension/'));
      }
      for (final String asset in kWebBrowserYoutubeSubtitlesAssets) {
        expect(File(asset).existsSync(), isTrue, reason: asset);
      }
    });

    test('块按 YouTube 主机与「已装」标记守卫，源码按顺序原样拼进去', () {
      final String bundle = webBrowserYoutubeSubtitlesBundle(<String>[
        '/*A*/',
        '/*B*/',
      ]);
      expect(bundle, startsWith('if ('));
      expect(bundle, contains(webVideoHostMatchJs(kWebVideoYoutubeHosts)));
      expect(bundle, contains('!window.__fushiYtSubsBundle'));
      expect(bundle, contains('window.__fushiYtSubsBundle = true;'));
      expect(bundle.indexOf('/*A*/'), lessThan(bundle.indexOf('/*B*/')));
      expect(bundle.trimRight(), endsWith('}'));
    });

    test('开关脚本', () {
      expect(
        webBrowserYoutubeSubtitlesToggleScript(enabled: true),
        'if (window.__fushiYtSubs) window.__fushiYtSubs.setEnabled(true, "");',
      );
      expect(
        webBrowserYoutubeSubtitlesToggleScript(enabled: true, language: 'ja'),
        'if (window.__fushiYtSubs) window.__fushiYtSubs.setEnabled(true, "ja");',
      );
      expect(
        webBrowserYoutubeSubtitlesToggleScript(
          enabled: true,
          language: '"); alert(1); ("',
        ),
        contains(r'"\"); alert(1); (\""'),
        reason: '语言按 JSON 字符串转义，不能拼出脚本',
      );
      expect(
        webBrowserYoutubeSubtitlesToggleScript(enabled: false),
        contains('setEnabled(false, "")'),
      );
    });

    test('node 真执行：字幕层纯逻辑 + 完整脚本块在 YouTube 装起来、别的站不装', () async {
      final String? node = _resolveNode();
      if (node == null) {
        markTestSkipped('node not found on PATH');
        return;
      }
      final String bundle = await loadWebBrowserYoutubeSubtitlesBundle(
        loadAsset: _readAsset,
      );
      final Directory tmp = await Directory.systemTemp.createTemp('fushi-yts');
      try {
        final File bundleFile = File('${tmp.path}/bundle.js');
        await bundleFile.writeAsString(bundle);
        final ProcessResult result = await Process.run(node, <String>[
          'test/web_browser/features/youtube_subtitles/'
              'youtube_subtitles_overlay_test.js',
          bundleFile.path,
        ]);
        expect(
          result.exitCode,
          0,
          reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
        );
        expect(result.stdout.toString(), contains('all assertions passed'));
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });

  group('YoutubeSubtitlesFeature', () {
    test('YouTube 页判定', () {
      expect(
        isWebBrowserYoutubePage(Uri.parse('https://m.youtube.com/')),
        isTrue,
      );
      expect(
        isWebBrowserYoutubePage(Uri.parse('https://www.youtube.com/watch?v=x')),
        isTrue,
      );
      expect(
        isWebBrowserYoutubePage(Uri.parse('https://music.youtube.com/')),
        isTrue,
      );
      expect(
        isWebBrowserYoutubePage(Uri.parse('https://example.com/')),
        isFalse,
      );
      expect(
        isWebBrowserYoutubePage(Uri.parse('https://youtube.com.evil.example/')),
        isFalse,
      );
      expect(isWebBrowserYoutubePage(null), isFalse);
    });

    test('开着时 document-start 注入整块 + 打开字幕层；关着不注入', () async {
      final _MemoryPrefs prefs = _MemoryPrefs();
      final YoutubeSubtitlesFeature feature = YoutubeSubtitlesFeature(
        prefs: prefs,
        loadAsset: _readAsset,
      );
      expect(await feature.bundleReady, isNotNull);
      expect(feature.enabled, isTrue, reason: '默认开');
      final List<UserScript> scripts = feature.userScripts();
      expect(scripts, hasLength(1));
      expect(
        scripts.single.injectionTime,
        UserScriptInjectionTime.AT_DOCUMENT_START,
      );
      expect(scripts.single.source, contains('__fushiYtSubsBundle'));
      expect(scripts.single.source, contains('setEnabled(true, "")'));

      await feature.setEnabled(false);
      expect(prefs.values[kWebBrowserYoutubeSubtitlesPref], isFalse);
      expect(feature.userScripts(), isEmpty);
    });

    test('学习语言随脚本下发（每次现读）', () async {
      String language = 'ja';
      final YoutubeSubtitlesFeature feature = YoutubeSubtitlesFeature(
        prefs: _MemoryPrefs(),
        learningLanguage: () => language,
        loadAsset: _readAsset,
      );
      await feature.bundleReady;
      expect(
        feature.userScripts().single.source,
        contains('setEnabled(true, "ja")'),
      );
      language = 'zh-Hant';
      expect(
        feature.userScripts().single.source,
        contains('setEnabled(true, "zh-Hant")'),
      );
    });

    test('学习语言：默认内容语言优先，未设置时是日语', () {
      expect(
        webBrowserYoutubeSubtitleLanguage(defaultContentLanguage: ''),
        'ja',
      );
      expect(
        webBrowserYoutubeSubtitleLanguage(defaultContentLanguage: ' ko '),
        'ko',
      );
    });

    test('资产读失败：不注入、不抛', () async {
      final YoutubeSubtitlesFeature feature = YoutubeSubtitlesFeature(
        prefs: _MemoryPrefs(),
        loadAsset: (String asset) async => throw StateError('missing'),
      );
      expect(await feature.bundleReady, isNull);
      expect(feature.userScripts(), isEmpty);
    });

    testWidgets('菜单开关只在 YouTube 页出现，selected 跟偏好走', (
      WidgetTester tester,
    ) async {
      final _MemoryPrefs prefs = _MemoryPrefs();
      final YoutubeSubtitlesFeature feature = YoutubeSubtitlesFeature(
        prefs: prefs,
        loadAsset: (String asset) async => '',
      );
      late List<WebBrowserAction> yt;
      late List<WebBrowserAction> other;
      Future<void> build() => tester.pumpWidget(
        Builder(
          builder: (BuildContext context) {
            yt = feature.actions(
              context,
              WebBrowserTab(
                id: 'a',
                url: Uri.parse('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
              ),
            );
            other = feature.actions(
              context,
              WebBrowserTab(id: 'b', url: Uri.parse('https://example.com/')),
            );
            return const SizedBox.shrink();
          },
        ),
      );
      await build();
      expect(other, isEmpty);
      expect(yt, hasLength(1));
      expect(yt.single.placement, WebBrowserActionPlacement.menu);
      expect(yt.single.selected, isTrue);

      prefs.values[kWebBrowserYoutubeSubtitlesPref] = false;
      await build();
      expect(yt.single.selected, isFalse);
    });
  });
}
