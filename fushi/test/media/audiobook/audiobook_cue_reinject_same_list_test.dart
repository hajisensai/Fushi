import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// reader 每装一章文档都把同一份整书 cue 列表再灌进控制器一遍
/// （`_injectAudiobookBridge` → `setChapterCues` + `setAllBookCues`）。同一个列表
/// 对象原样重灌时只跳过「复制 + 排序 + 建 id 索引」，其余一步不省：
///  - 当前句身份保留 / 按位置重算 / 通知照跑（BUG-2781、BUG-3798 的用例在
///    `audiobook_paused_cue_reload_no_yank_test.dart`、
///    `chapter_transition_seek_guard_test.dart`，它们重灌的正是同一个列表对象）；
///  - 播放句身份映射照跑（BUG-4202，`lyrics_sliding_window_test.dart`）；
///  - 文件时长照常重算（TTS 朗读就地改 cue 的 endMs）。
/// 列表对象换了、或同一对象长度变了，必须完整重建。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.ryanheise.audio_session'),
          (_) async => null,
        );
  });

  int nextId = 1;
  AudioCue cue(int file, int startMs, int endMs) => AudioCue()
    ..id = nextId++
    ..bookKey = 'b'
    ..chapterHref = 'c'
    ..sentenceIndex = file * 1000 + startMs
    ..textFragmentId = 'cue-$file-$startMs'
    ..text = 'cue $file $startMs'
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = file;

  List<String> order(List<AudioCue> cues) => <String>[
    for (final AudioCue c in cues) '${c.audioFileIndex}:${c.startMs}',
  ];

  group('setChapterCues', () {
    test('同一个列表对象重灌：排好的副本原样复用，顺序仍是播放顺序', () {
      final AudiobookPlayerController c = AudiobookPlayerController();
      addTearDown(c.dispose);
      final List<AudioCue> cues = <AudioCue>[
        cue(1, 0, 500),
        cue(0, 9000, 9500),
        cue(0, 0, 500),
        cue(1, 4000, 4500),
      ];
      c.setChapterCues(cues);
      final List<AudioCue> first = c.chapterCuesSnapshot;
      expect(order(first), <String>['0:0', '0:9000', '1:0', '1:4000']);

      c.setChapterCues(cues);
      expect(
        identical(c.chapterCuesSnapshot, first),
        isTrue,
        reason: '同一个列表对象重灌不应再复制 + 排序',
      );
      expect(order(c.chapterCuesSnapshot), <String>[
        '0:0',
        '0:9000',
        '1:0',
        '1:4000',
      ]);
      expect(
        identical(c.chapterCuesSnapshot, cues),
        isFalse,
        reason: '控制器持有的是排好的副本，不是调用方的列表',
      );
    });

    test('同一个列表对象重灌仍然通知监听者', () {
      final AudiobookPlayerController c = AudiobookPlayerController();
      addTearDown(c.dispose);
      final List<AudioCue> cues = <AudioCue>[cue(0, 0, 500), cue(0, 500, 900)];
      c.setChapterCues(cues);
      int notified = 0;
      c.addListener(() => notified++);
      c.setChapterCues(cues);
      expect(notified, 1, reason: '重灌后的重算 + 通知不能随复制一起被跳过');
    });

    test('内容相同但换了列表对象：完整重建', () {
      final AudiobookPlayerController c = AudiobookPlayerController();
      addTearDown(c.dispose);
      final List<AudioCue> cues = <AudioCue>[cue(0, 500, 900), cue(0, 0, 500)];
      c.setChapterCues(cues);
      final List<AudioCue> first = c.chapterCuesSnapshot;
      c.setChapterCues(List<AudioCue>.of(cues));
      expect(identical(c.chapterCuesSnapshot, first), isFalse);
      expect(order(c.chapterCuesSnapshot), <String>['0:0', '0:500']);
    });

    test('同一个列表对象但长度变了：重新排序，新成员进表', () {
      final AudiobookPlayerController c = AudiobookPlayerController();
      addTearDown(c.dispose);
      final List<AudioCue> cues = <AudioCue>[cue(0, 500, 900), cue(1, 0, 500)];
      c.setChapterCues(cues);
      cues.add(cue(0, 0, 400));
      c.setChapterCues(cues);
      expect(order(c.chapterCuesSnapshot), <String>['0:0', '0:500', '1:0']);
    });

    test('换成别的列表再换回来：不拿上上次的副本顶替', () {
      final AudiobookPlayerController c = AudiobookPlayerController();
      addTearDown(c.dispose);
      final List<AudioCue> whole = <AudioCue>[cue(0, 0, 500), cue(0, 500, 900)];
      final List<AudioCue> chapter = <AudioCue>[cue(3, 0, 700)];
      c.setChapterCues(whole);
      c.setChapterCues(chapter);
      expect(order(c.chapterCuesSnapshot), <String>['3:0']);
      c.setChapterCues(whole);
      expect(order(c.chapterCuesSnapshot), <String>['0:0', '0:500']);
    });
  });

  group('setAllBookCues', () {
    test('同一个列表对象重灌：副本复用，id 索引仍可解析当前句', () {
      final AudiobookPlayerController c = AudiobookPlayerController();
      addTearDown(c.dispose);
      final List<AudioCue> cues = <AudioCue>[
        cue(0, 0, 1000),
        cue(0, 1000, 2000),
        cue(0, 2000, 3000),
      ];
      c.setChapterCues(cues);
      c.setAllBookCues(cues);
      final List<AudioCue> first = c.allBookCuesSnapshot;
      c.debugUpdateCueForPosition(1500);
      expect(c.currentCue?.startMs, 1000);
      expect(c.allBookCueIdx, 1);

      c.setAllBookCues(cues);
      expect(identical(c.allBookCuesSnapshot, first), isTrue);
      expect(c.allBookCueIdx, 1);
    });

    test('同一个列表对象重灌仍按 cue 当前的 endMs 重算全书时长', () {
      final AudiobookPlayerController c = AudiobookPlayerController();
      addTearDown(c.dispose);
      final List<AudioCue> cues = <AudioCue>[cue(0, 0, 1000), cue(1, 0, 2000)];
      c.setAllBookCues(cues);
      expect(c.totalDuration, const Duration(milliseconds: 3000));
      // TTS 朗读：一句合成完才知道真实时长，就地改 endMs。
      cues[1].endMs = 5000;
      c.setAllBookCues(cues);
      expect(
        c.totalDuration,
        const Duration(milliseconds: 6000),
        reason: '文件时长推算不在可跳过的范围里',
      );
    });

    test('同一个列表对象但长度变了：id 索引重建，新 cue 可解析', () {
      final AudiobookPlayerController c = AudiobookPlayerController();
      addTearDown(c.dispose);
      final List<AudioCue> cues = <AudioCue>[cue(0, 0, 1000)];
      c.setAllBookCues(cues);
      cues.add(cue(0, 1000, 2000));
      c.setAllBookCues(cues);
      c.setChapterCues(cues);
      c.debugUpdateCueForPosition(1500);
      expect(c.allBookCuesSnapshot.length, 2);
      expect(c.allBookCueIdx, 1);
    });

    test('换了列表对象：完整重建', () {
      final AudiobookPlayerController c = AudiobookPlayerController();
      addTearDown(c.dispose);
      final List<AudioCue> cues = <AudioCue>[cue(0, 0, 1000)];
      c.setAllBookCues(cues);
      final List<AudioCue> first = c.allBookCuesSnapshot;
      final List<AudioCue> replaced = <AudioCue>[
        cue(0, 0, 1000),
        cue(0, 1000, 4000),
      ];
      c.setAllBookCues(replaced);
      expect(identical(c.allBookCuesSnapshot, first), isFalse);
      expect(c.allBookCuesSnapshot.length, 2);
      expect(c.totalDuration, const Duration(milliseconds: 4000));
    });
  });
}
