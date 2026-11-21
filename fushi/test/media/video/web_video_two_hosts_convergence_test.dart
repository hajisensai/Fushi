// gap-webvideo-11（拍板台 design-nmv-webvideo-two-hosts，选 a）：网页视频两个宿主页
// （原生播放器页的网页档、内置网页播放器）共用一份选轨状态与一个宿主会话，不再各写一套。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi/src/media/video/web_video_bridge.dart';
import 'package:fushi/src/media/video/web_video_track_selection.dart';

import '../../helpers/source_guard.dart';

const String _builtinPage =
    'lib/src/pages/implementations/web_video_fushi_page.dart';
const String _nativePart =
    'lib/src/pages/implementations/video_fushi/web_source.part.dart';

WebVideoTrack _track(String videoKey, String lang, {int cues = 1}) =>
    WebVideoTrack(
      key: '$videoKey|$lang',
      videoKey: videoKey,
      lang: lang,
      cues: <AudioCue>[
        for (int i = 0; i < cues; i++)
          AudioCue()
            ..bookKey = 'b'
            ..chapterHref = videoKey
            ..sentenceIndex = i
            ..textFragmentId = ''
            ..text = 'c$i'
            ..startMs = i * 1000
            ..endMs = i * 1000 + 900
            ..audioFileIndex = 0,
      ],
    );

void main() {
  group('WebVideoTrackSelection', () {
    test('语言偏好的整轨优先于先到的 live 轨与别的语言', () {
      final WebVideoTrackSelection sel = WebVideoTrackSelection()
        ..beginVideo('v1');
      sel.tracks['v1|$kWebVideoLiveTrackLang'] = _track(
        'v1',
        kWebVideoLiveTrackLang,
      );
      WebVideoTrackReselect r = sel.reselect(preferredLanguage: 'ja');
      expect(sel.activeKey, 'v1|$kWebVideoLiveTrackLang');
      expect(r.reload, isTrue);
      expect(r.changed, isTrue);

      sel.tracks['v1|en'] = _track('v1', 'en');
      sel.tracks['v1|ja'] = _track('v1', 'ja', cues: 3);
      r = sel.reselect(updatedKey: 'v1|ja', preferredLanguage: 'ja');
      expect(sel.activeKey, 'v1|ja');
      expect(r.reload, isTrue);
      expect(r.cues, hasLength(3));
    });

    test('没选中的 live 轨长了一句：不重灌', () {
      final WebVideoTrackSelection sel = WebVideoTrackSelection()
        ..beginVideo('v1');
      sel.tracks['v1|ja'] = _track('v1', 'ja');
      sel.reselect(preferredLanguage: 'ja');
      sel.tracks['v1|$kWebVideoLiveTrackLang'] = _track(
        'v1',
        kWebVideoLiveTrackLang,
        cues: 2,
      );
      final WebVideoTrackReselect r = sel.reselect(
        updatedKey: 'v1|$kWebVideoLiveTrackLang',
        preferredLanguage: 'ja',
      );
      expect(r.reload, isFalse);
      expect(sel.activeKey, 'v1|ja');
    });

    test('显式请求的轨采到即钉住，压过语言偏好', () {
      final WebVideoTrackSelection sel = WebVideoTrackSelection()
        ..beginVideo('v1');
      sel.tracks['v1|ja'] = _track('v1', 'ja');
      sel.reselect(preferredLanguage: 'ja');
      sel.pendingKey = 'v1|en';
      sel.tracks['v1|en'] = _track('v1', 'en');
      sel.reselect(updatedKey: 'v1|en', preferredLanguage: 'ja');
      expect(sel.pendingKey, isNull);
      expect(sel.pinnedKey, 'v1|en');
      expect(sel.activeKey, 'v1|en');
    });

    test('关字幕后不再自动挑轨；换视频清掉选择、只列新视频的轨', () {
      final WebVideoTrackSelection sel = WebVideoTrackSelection()
        ..beginVideo('v1');
      sel.tracks['v1|ja'] = _track('v1', 'ja');
      sel.choose(null);
      final WebVideoTrackReselect off = sel.reselect(preferredLanguage: 'ja');
      expect(sel.activeKey, isNull);
      expect(off.cues, isEmpty);

      sel.choose('v1|ja');
      sel.beginVideo('v2');
      expect(sel.pinnedKey, isNull);
      expect(sel.currentTracks, isEmpty);
      sel.tracks['v2|ja'] = _track('v2', 'ja');
      expect(sel.currentTracks.map((WebVideoTrack t) => t.key), <String>[
        'v2|ja',
      ]);
    });

    test('默认字幕语言：书没有语言时走字幕工作台 / 内容语言偏好链，不落到随机首轨', () {
      expect(
        webVideoPreferredSubtitleLanguage(
          subtitleWorkbenchLanguage: null,
          bookLanguage: null,
          defaultContentLanguage: 'ja',
        ),
        'ja',
      );
    });
  });

  group('两个宿主页共用一份实现', () {
    final String builtin = File(_builtinPage).readAsStringSync();
    final String native = File(_nativePart).readAsStringSync();

    test('选轨：两处都只经 WebVideoTrackSelection.reselect 判灌不灌，语言偏好同一条链', () {
      for (final (String path, String src, String reselect)
          in <(String, String, String)>[
            (_builtinPage, builtin, 'void _reselectTrack('),
            (_nativePart, native, 'void _reselectWebTrack('),
          ]) {
        final String body = compactCode(methodBody(src, reselect));
        expect(body, contains('.reselect('), reason: path);
        expect(body, isNot(contains('chooseWebVideoTrackKey(')), reason: path);
        final int gate = body.indexOf('if(!r.reload)return;');
        expect(gate, greaterThanOrEqualTo(0), reason: path);
        expect(body.indexOf('.setCues(r.cues)'), greaterThan(gate));
        expect(
          src,
          contains('webVideoPreferredSubtitleLanguage('),
          reason: path,
        );
      }
    });

    test('内置网页播放器的 WebView 由共享会话建：不再自己 new InAppWebView / 包 JS', () {
      expect(builtin, contains('WebVideoSurface(session: session)'));
      expect(builtin, isNot(contains('InAppWebView(')));
      expect(builtin, isNot(contains('evaluateJavascript(')));
      expect(builtin, isNot(contains('addJavaScriptHandler(')));
      expect(builtin, isNot(contains('WebViewDeathGuard(')));
      // 浏览器广告拦截暖机与原生页同一段。
      expect(builtin, contains('warmWebVideoAdblock('));
      expect(native, contains('warmWebVideoAdblock('));
      // 页面命令仍只有一个出口，走会话的包装（在途调用随表面死亡作废）。
      expect(
        compactCode(methodBody(builtin, 'Future<Object?> _js(')),
        contains('_session?.evaluate(expression)'),
      );
    });
  });
}
