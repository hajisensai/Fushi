import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_clip_export.dart';

void main() {
  group('exported card text follows the actual reader selection', () {
    test('accepts cue text only when it exactly represents the selection', () {
      const List<AudiobookClipCueSpan> cues = <AudiobookClipCueSpan>[
        AudiobookClipCueSpan(text: 'first', startMs: 0, endMs: 1000),
        AudiobookClipCueSpan(text: 'second', startMs: 1000, endMs: 2000),
      ];
      expect(
        audiobookClipCueTextMatchesSelection(
          selectedText: 'first\nsecond',
          cueSpans: cues,
        ),
        isTrue,
      );
    });

    test('rejects subtitle wording or a wider cue than the selected text', () {
      const List<AudiobookClipCueSpan> cues = <AudiobookClipCueSpan>[
        AudiobookClipCueSpan(text: 'subtitle wording', startMs: 0, endMs: 1000),
      ];
      expect(
        audiobookClipCueTextMatchesSelection(
          selectedText: 'epub wording',
          cueSpans: cues,
        ),
        isFalse,
      );
      expect(
        audiobookClipCueTextMatchesSelection(
          selectedText: 'sub',
          cueSpans: cues,
        ),
        isFalse,
      );
    });

    test('reader plan falls back before rendering differing cue text', () {
      final String source = File(
        'lib/src/pages/implementations/reader_hibiki/audiobook.part.dart',
      ).readAsStringSync();
      final int exportable = source.indexOf(
        'if (!result.isExportable) return null;',
      );
      final int equalityGate = source.indexOf(
        'audiobookClipCueTextMatchesSelection(',
        exportable,
      );
      final int renderCueText = source.indexOf(
        'text: plan.cueSpans[i].text',
        equalityGate,
      );
      expect(exportable, greaterThanOrEqualTo(0));
      expect(equalityGate, greaterThan(exportable));
      expect(renderCueText, greaterThan(equalityGate));
    });
  });

  group('every synthesized clip explicitly carries the audio input', () {
    void expectExplicitMaps(List<String> args) {
      expect(
        args,
        containsAllInOrder(<String>['-map', '0:v:0', '-map', '1:a:0']),
      );
      expect(args, containsAllInOrder(<String>['-c:a', 'aac']));
    }

    test('static card maps video input 0 and audio input 1', () {
      expectExplicitMaps(
        buildFfmpegImageAudioToVideoArgs(
          imagePath: '/card.jpg',
          audioPath: '/clip.aac',
          outputPath: '/clip.mp4',
          h264: true,
        ),
      );
    });

    test('dynamic frame sequence maps video input 0 and audio input 1', () {
      expectExplicitMaps(
        buildFfmpegImageSeqAudioToVideoArgs(
          framesDir: '/frames',
          audioPath: '/clip.aac',
          outputPath: '/clip.mp4',
          h264: true,
        ),
      );
    });

    test('BUG-1243 mobile share exposes one self-contained video only', () {
      // BUG-1264：移动产物统一 MPEG-4/.mp4，mime 恒 video/mp4（不再按编码器分叉）。
      final List<AudiobookClipShareAttachment> attachments =
          audiobookClipMobileShareAttachments(
        videoPath: '/tmp/clip.mp4',
      );
      expect(attachments, hasLength(1));
      expect(attachments.single.path, '/tmp/clip.mp4');
      expect(attachments.single.mimeType, 'video/mp4');
      expect(
        attachments.where(
          (AudiobookClipShareAttachment attachment) =>
              attachment.mimeType.startsWith('audio/'),
        ),
        isEmpty,
        reason: 'AAC is an intermediate file, never a second share attachment',
      );
    });
  });
}
