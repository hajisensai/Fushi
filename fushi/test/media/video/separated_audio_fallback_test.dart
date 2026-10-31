import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

import '../../pages/video_fushi_page_source_corpus.dart';

/// 反馈 s3sOy3sD1J：YouTube 分离流的 audio-only 外挂音轨被 googlevideo 403（YouTube
/// 侧限窗，不可控）→ libmpv `Can not open external file` → 音轨被丢、画面照放、完全无声，
/// 页面只把这条错误写进日志。修法是失败后的处理：判出「本次 load 的外挂音轨打不开」→
/// 有自带音轨的 muxed 流就原位换过去，没有就明确提示无声。
void main() {
  const String relayAudio =
      'http://127.0.0.1:45495/yt/Vsjudh_igyFxyhCx3YNXsr-E';

  group('isExternalAudioOpenFailure（外挂音轨打开失败判据）', () {
    test('mpv 的 external file 打开失败且 URI 是本次外挂音轨 → 命中', () {
      expect(
        VideoPlayerController.isExternalAudioOpenFailure(
          'Can not open external file $relayAudio.',
          relayAudio,
        ),
        isTrue,
      );
    });

    test('同一 URI 的主流级 Failed to open 不算（只认外挂文件那条）', () {
      expect(
        VideoPlayerController.isExternalAudioOpenFailure(
          'Failed to open $relayAudio.',
          relayAudio,
        ),
        isFalse,
      );
    });

    test('别的外挂文件（字幕 / 上一片的旧音轨）打不开不算', () {
      expect(
        VideoPlayerController.isExternalAudioOpenFailure(
          'Can not open external file http://127.0.0.1:45495/yt/OLDTOKEN.',
          relayAudio,
        ),
        isFalse,
      );
      expect(
        VideoPlayerController.isExternalAudioOpenFailure(
          'Can not open external file C:/subs/ep1.ass.',
          relayAudio,
        ),
        isFalse,
      );
    });

    test('本次 load 没挂外挂音轨 → 永不命中', () {
      expect(
        VideoPlayerController.isExternalAudioOpenFailure(
          'Can not open external file $relayAudio.',
          null,
        ),
        isFalse,
      );
      expect(
        VideoPlayerController.isExternalAudioOpenFailure(
          'Can not open external file $relayAudio.',
          '',
        ),
        isFalse,
      );
    });
  });

  group('separatedAudioFallbackStreamUrl（回退流选择）', () {
    test('分离流 + muxed 制卡流 → 回退到 muxed（复用解析器现成的流）', () {
      expect(
        separatedAudioFallbackStreamUrl(
          const RemoteVideoStreamUrls(
            streamUrl: 'http://127.0.0.1:1/yt/video',
            audioStreamUrl: 'http://127.0.0.1:1/yt/audio',
            miningVideoUrl: 'http://127.0.0.1:1/yt/muxed18',
            miningVideoHasAudio: true,
          ),
        ),
        'http://127.0.0.1:1/yt/muxed18',
      );
    });

    test('制卡流是 video-only（无 muxed）→ 无可回退，交给提示', () {
      expect(
        separatedAudioFallbackStreamUrl(
          const RemoteVideoStreamUrls(
            streamUrl: 'http://127.0.0.1:1/yt/video',
            audioStreamUrl: 'http://127.0.0.1:1/yt/audio',
            miningVideoUrl: 'http://127.0.0.1:1/yt/video144',
          ),
        ),
        isNull,
      );
    });

    test('本集没挂分离音轨（已是 muxed / 普通直链）→ null', () {
      expect(
        separatedAudioFallbackStreamUrl(
          const RemoteVideoStreamUrls(
            streamUrl: 'http://127.0.0.1:1/yt/muxed18',
            miningVideoUrl: 'http://127.0.0.1:1/yt/muxed18',
            miningVideoHasAudio: true,
          ),
        ),
        isNull,
      );
    });

    test('muxed 流就是当前主流 → null（换过去等于原地重放）', () {
      expect(
        separatedAudioFallbackStreamUrl(
          const RemoteVideoStreamUrls(
            streamUrl: 'http://127.0.0.1:1/yt/same',
            audioStreamUrl: 'http://127.0.0.1:1/yt/audio',
            miningVideoUrl: 'http://127.0.0.1:1/yt/same',
            miningVideoHasAudio: true,
          ),
        ),
        isNull,
      );
    });
  });

  // 页面接线需要真 libmpv（宿主没有），在源码层钉住：控制器的失败回调接到页面，
  // 起播收尾 / 切档收尾都会处理在途期间记下的失败，处理走「回退 muxed 或提示」。
  group('页面接线（源码守卫）', () {
    final String src = readVideoFushiSource();

    test('_applyLoad 把音轨失败回调接到页面', () {
      expect(
        src,
        contains(
          'controller.onExternalAudioTrackFailed = '
          '_handleExternalAudioTrackFailed;',
        ),
      );
    });

    test('远端起播按本集流算回退目标，并在收尾处理在途失败', () {
      expect(
        src,
        contains(
          '_separatedAudioFallbackUrl = separatedAudioFallbackStreamUrl(urls);',
        ),
      );
      expect(
        RegExp(r'_recoverFromExternalAudioFailure\(\)').allMatches(src).length,
        greaterThanOrEqualTo(3),
        reason: '回调本身 + 远端起播收尾 + YouTube 切档收尾',
      );
    });

    test('回退分支：有 muxed 换流重载（不再挂外挂音轨），没有则提示无声', () {
      final int start = src.indexOf(
        'Future<void> _recoverFromExternalAudioFailure() async {',
      );
      expect(start, greaterThanOrEqualTo(0));
      final String body = _methodBody(src, start);
      expect(body, contains('controller.externalAudioTrackFailed'));
      expect(body, contains('t.video_audio_track_load_failed'));
      expect(body, contains('mediaUri: fallback,'));
      expect(body, isNot(contains('externalAudioTrackUrl:')));
      expect(body, contains('t.video_audio_track_fallback_muxed'));
    });

    // PR #2688 review：共享 bool 在重叠载入下失效、回退不看集序号。在途 / 作废 / 被拒
    // 的判据全在 SeparatedAudioLoadGuard（纯逻辑单测见 separated_audio_load_guard_test），
    // 这里钉住页面确实把三条载入路径与回退都交给它。
    test('不再用共享 bool 记在途', () {
      expect(src, isNot(contains('_separatedAudioLoadInFlight')));
    });

    test('三条挂分离音轨的载入都经令牌在途记账，回退经 guard 按集序号作废', () {
      expect(
        RegExp(r'_separatedAudio\.runLoad<void>\(').allMatches(src).length,
        2,
        reason: '远端起播 + YouTube 切档（回退那程在 guard.recover 内部 runLoad）',
      );
      final int start = src.indexOf(
        'Future<void> _recoverFromExternalAudioFailure() async {',
      );
      expect(_methodBody(src, start), contains('_separatedAudio.recover('));
      expect(
        src,
        contains('if (_separatedAudio.loadInFlight) return;'),
        reason: '控制器失败回调在有载入在途时只记账',
      );
    });

    test('YouTube 切档：被拒后不再挂同一条音频流，await 前后校验集序号', () {
      final int start = src.indexOf(
        'Future<void> _switchYoutubeVariant(int index) async {',
      );
      expect(start, greaterThanOrEqualTo(0));
      final String body = _methodBody(src, start);
      final int refusedAt = body.indexOf(
        'if (_separatedAudio.separatedAudioRefused) {',
      );
      final int relayAt = body.indexOf('await relayYoutubeStreamUrl(');
      final int loadAt = body.indexOf('_separatedAudio.runLoad<void>(');
      final int osdAt = body.indexOf('t.video_quality_switched(');
      expect(refusedAt, greaterThanOrEqualTo(0), reason: '被拒后必须早退');
      expect(refusedAt, lessThan(relayAt));
      expect(body, contains('t.video_quality_separated_audio_refused'));
      final int seqCheckAfterRelay = body.indexOf(
        '_separatedAudio.isCurrent(seq)',
        relayAt,
      );
      expect(seqCheckAfterRelay, greaterThan(relayAt));
      expect(seqCheckAfterRelay, lessThan(loadAt), reason: '中继 await 后、重载前校验');
      final int seqCheckAfterLoad = body.indexOf(
        '_separatedAudio.isCurrent(seq)',
        loadAt,
      );
      expect(seqCheckAfterLoad, greaterThan(loadAt));
      expect(
        seqCheckAfterLoad,
        lessThan(osdAt),
        reason: '重载 await 后、弹 OSD 前校验',
      );
    });

    test('画质菜单在被拒后禁用分离档并说明原因', () {
      expect(
        src,
        contains(
          'final bool separatedRefused = _separatedAudio.separatedAudioRefused;',
        ),
      );
      expect(
        RegExp(r'enabled: !separatedRefused,').allMatches(src).length,
        2,
        reason: '「自动」档与各具体档都禁用',
      );
      expect(src, contains("'video-quality-youtube-separated-audio-refused'"));
    });
  });
}

/// 从 [start]（方法签名处）切到该方法的结束花括号（part 成员 2 空格缩进）。
String _methodBody(String src, int start) {
  final int end = src.indexOf('\n  }\n', start);
  return src.substring(start, end < 0 ? src.length : end);
}
