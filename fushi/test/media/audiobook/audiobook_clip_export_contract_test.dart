import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_clip_export.dart';

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
        'lib/src/pages/implementations/reader_fushi/audiobook.part.dart',
      ).readAsStringSync();
      // BUG-1320：不可导出时不再裸 `return null`——tooLong 的窗口要透传出去
      // （否则超长选区回落单句锚，静默产出「全文卡片 + 一句声音」）。锚点只取判据本身，
      // 不再锚返回值形态。
      final int exportable = source.indexOf(
        'if (!result.isExportable) return',
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
      // BUG-2011：输出是 mp4，ffmpeg 默认等价 `-map_chapters 0`。只要有一路输入带
      // 章节，mp4 muxer 就会建一条与最后一个章节等长的 chapter text track，把
      // mvhd.duration 拉满（几秒的片段显示成整本的进度条）。今天两路输入都不带章节
      // （图片/帧序列 + 已裁好的裸 ADTS .aac），但那是靠调用方维持的隐式契约；
      // 就地钉死比指望远处的约定不被改动可靠，且没有章节可丢时它是空操作。
      expect(args, containsAllInOrder(<String>['-map_chapters', '-1']));
    }

    test('static card maps video input 0 and audio input 1', () {
      expectExplicitMaps(
        buildFfmpegImageAudioToVideoArgs(
          imagePath: '/card.jpg',
          audioPath: '/clip.aac',
          outputPath: '/clip.mp4',
        ),
      );
    });

    test('dynamic frame sequence maps video input 0 and audio input 1', () {
      expectExplicitMaps(
        buildFfmpegImageSeqAudioToVideoArgs(
          framesDir: '/frames',
          audioPath: '/clip.aac',
          outputPath: '/clip.mp4',
        ),
      );
    });

    test('BUG-1243 mobile share exposes one self-contained video only', () {
      // TODO-2357：两端产物统一 H.264/.mp4，mime 恒 video/mp4（不再按编码器分叉）。
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
