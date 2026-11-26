// BUG-5543（反馈 WNUWVgsr6Q）：网页档的副字幕选轨状态。副字幕只由用户显式选，选了 / 关了 /
// 采到了 / 换视频才要求宿主页重灌副层；主轨自动挑选避开选作副字幕的那条。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/web_video_bridge.dart';
import 'package:fushi/src/media/video/web_video_track_selection.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;

WebVideoTrack _track(String videoKey, String lang, {int cues = 1}) =>
    WebVideoTrack(
      key: '$videoKey|$lang',
      videoKey: videoKey,
      lang: lang,
      languageCode: lang,
      cues: <AudioCue>[
        for (int i = 0; i < cues; i++)
          AudioCue()
            ..bookKey = 'b'
            ..chapterHref = videoKey
            ..sentenceIndex = i
            ..textFragmentId = ''
            ..text = '$lang $i'
            ..startMs = i * 1000
            ..endMs = i * 1000 + 900
            ..audioFileIndex = 0,
      ],
    );

void main() {
  group('WebVideoTrackSelection 副字幕', () {
    test('选副字幕即要求重灌副层；没变化的重选不重灌', () {
      final WebVideoTrackSelection sel = WebVideoTrackSelection()
        ..beginVideo('v1');
      sel.tracks['v1|ja'] = _track('v1', 'ja');
      sel.tracks['v1|en'] = _track('v1', 'en', cues: 2);
      WebVideoTrackReselect r = sel.reselect(preferredLanguage: 'ja');
      expect(r.secondaryReload, isFalse, reason: '副字幕关着，空层不必重灌');
      expect(r.secondaryCues, isEmpty);

      sel.chooseSecondary('v1|en');
      r = sel.reselect(preferredLanguage: 'ja');
      expect(r.secondaryReload, isTrue);
      expect(r.secondaryCues, hasLength(2));
      expect(sel.activeKey, 'v1|ja', reason: '主字幕不受副字幕选择影响');

      r = sel.reselect(updatedKey: 'v1|ja', preferredLanguage: 'ja');
      expect(r.secondaryReload, isFalse);

      sel.chooseSecondary(null);
      r = sel.reselect(preferredLanguage: 'ja');
      expect(r.secondaryReload, isTrue);
      expect(r.secondaryCues, isEmpty);
    });

    test('先选后到的按需加载轨：采到 / 长了才灌进副层', () {
      final WebVideoTrackSelection sel = WebVideoTrackSelection()
        ..beginVideo('v1');
      sel.tracks['v1|ja'] = _track('v1', 'ja');
      sel.reselect(preferredLanguage: 'ja');
      sel.chooseSecondary('v1|en');
      WebVideoTrackReselect r = sel.reselect(preferredLanguage: 'ja');
      expect(r.secondaryReload, isFalse, reason: '还没采到，副层仍是空');

      sel.tracks['v1|en'] = _track('v1', 'en', cues: 3);
      r = sel.reselect(updatedKey: 'v1|en', preferredLanguage: 'ja');
      expect(r.secondaryReload, isTrue);
      expect(r.secondaryCues, hasLength(3));
      expect(r.reload, isFalse, reason: '主轨没换，不重灌主层');
      expect(sel.activeKey, 'v1|ja');
    });

    test('主轨自动挑选避开副字幕那条；用户钉住的照旧', () {
      final WebVideoTrackSelection sel = WebVideoTrackSelection()
        ..beginVideo('v1');
      sel.tracks['v1|live'] = _track('v1', kWebVideoLiveTrackLang);
      sel.chooseSecondary('v1|en');
      // 为副字幕取来的英文整轨到了：没有日语整轨时也不能把主字幕抢成英文。
      sel.tracks['v1|en'] = _track('v1', 'en');
      sel.reselect(updatedKey: 'v1|en', preferredLanguage: 'ja');
      expect(sel.activeKey, 'v1|live');

      sel.choose('v1|en');
      sel.reselect(preferredLanguage: 'ja');
      expect(sel.activeKey, 'v1|en');
    });

    test('换视频：副字幕不跟到新视频', () {
      final WebVideoTrackSelection sel = WebVideoTrackSelection()
        ..beginVideo('v1');
      sel.tracks['v1|en'] = _track('v1', 'en');
      sel.chooseSecondary('v1|en');
      sel.reselect(preferredLanguage: 'ja');
      sel.beginVideo('v2');
      expect(sel.secondaryKey, isNull);
      final WebVideoTrackReselect r = sel.reselect(preferredLanguage: 'ja');
      expect(r.secondaryReload, isTrue);
      expect(r.secondaryCues, isEmpty);
    });
  });

  test('chooseWebVideoTrackKey 的 exclude 只作用于自动结果', () {
    final List<WebVideoTrack> tracks = <WebVideoTrack>[
      _track('v1', 'en'),
      _track('v1', 'ja'),
    ];
    expect(
      chooseWebVideoTrackKey(tracks: tracks, videoKey: 'v1', exclude: 'v1|en'),
      'v1|ja',
    );
    expect(
      chooseWebVideoTrackKey(
        tracks: <WebVideoTrack>[_track('v1', 'en')],
        videoKey: 'v1',
        exclude: 'v1|en',
      ),
      isNull,
    );
    expect(
      chooseWebVideoTrackKey(
        tracks: tracks,
        videoKey: 'v1',
        pinned: 'v1|en',
        exclude: 'v1|en',
      ),
      'v1|en',
    );
  });
}
