import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/mining_audio_clip.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// 制卡句子音频头/尾 padding 设置（对齐 asbplayer 的 audio padding）守卫。
///
/// 锁住四层契约（不依赖真机 / ffmpeg）：
/// 1. 偏好默认 = 原有声书硬编码常量（头 120 / 尾 200，Never break userspace）+ 写穿
///    Drift + 越界夹到 `0..kMiningPadMaxMs`；
/// 2. [miningSentenceAudioRange] 把偏好值透传给 [padSentenceRange]（默认参数 = 常量，
///    既有调用方签名零变化）；
/// 3. 视频字幕制卡路径用同一个 [padSentenceRange]、喂偏好值、夹锚定 cue 所属流、
///    **先 pad 再 shift**（与有声书链同序）；有声书路径喂偏好值；
/// 4. Anki 设置页有两个滑块行 + 搜索条目，wire 到 AppModel 的 getter/setter，滑块上限与
///    偏好 clamp 共用 [kMiningPadMaxMs]。

FushiDatabase _testDb() {
  return FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
}

AudioCue _cue({required int startMs, required int endMs, String text = 'x'}) {
  return AudioCue()
    ..bookKey = 'book'
    ..chapterHref = 'chapter.xhtml'
    ..sentenceIndex = 0
    ..textFragmentId = '#s0'
    ..text = text
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = 0;
}

void main() {
  group('偏好层', () {
    late FushiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = _testDb();
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });

    tearDown(() async {
      repo.dispose();
      await db.close();
    });

    test('默认 = 原有声书硬编码常量（头 120 / 尾 200）', () {
      expect(repo.miningAudioHeadPadMs, kMiningHeadPadMs);
      expect(repo.miningAudioTailPadMs, kMiningTailPadMs);
      expect(kMiningHeadPadMs, 120, reason: '默认值改了就是行为变更，必须有意');
      expect(kMiningTailPadMs, 200, reason: '默认值改了就是行为变更，必须有意');
    });

    test('setMiningAudioHeadPadMs 写穿 Drift（往返 + DB key + 越界夹取）', () async {
      repo.setMiningAudioHeadPadMs(300);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(repo.miningAudioHeadPadMs, 300);

      final PreferencesRepository restored = PreferencesRepository(db);
      await restored.loadFromDb();
      expect(restored.miningAudioHeadPadMs, 300, reason: '设过必须落盘且跨实例可见');
      final Map<String, String> prefs = await db.getAllPrefs();
      expect(
        prefs.containsKey('mining_audio_head_pad_ms'),
        isTrue,
        reason: 'DB key 必须是 mining_audio_head_pad_ms',
      );
      restored.dispose();

      repo.setMiningAudioHeadPadMs(99999);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(repo.miningAudioHeadPadMs, kMiningPadMaxMs, reason: '越界夹到上限');
      repo.setMiningAudioHeadPadMs(-5);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(repo.miningAudioHeadPadMs, 0, reason: '负值夹到 0');
    });

    test('setMiningAudioTailPadMs 写穿 Drift（往返 + DB key + 越界夹取）', () async {
      repo.setMiningAudioTailPadMs(450);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(repo.miningAudioTailPadMs, 450);

      final PreferencesRepository restored = PreferencesRepository(db);
      await restored.loadFromDb();
      expect(restored.miningAudioTailPadMs, 450, reason: '设过必须落盘且跨实例可见');
      final Map<String, String> prefs = await db.getAllPrefs();
      expect(
        prefs.containsKey('mining_audio_tail_pad_ms'),
        isTrue,
        reason: 'DB key 必须是 mining_audio_tail_pad_ms',
      );
      restored.dispose();

      repo.setMiningAudioTailPadMs(99999);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(repo.miningAudioTailPadMs, kMiningPadMaxMs, reason: '越界夹到上限');
    });
  });

  group('miningSentenceAudioRange 透传 padding', () {
    test('默认参数 = 常量（既有调用方零变化）', () {
      final AudioCue cue = _cue(startMs: 5000, endMs: 6200, text: 'は');
      final AudioPlaybackRange? clip = miningSentenceAudioRange(
        cues: <AudioCue>[cue],
        cue: cue,
        sentence: 'は',
      );
      expect(clip!.startMs, 5000 - kMiningHeadPadMs);
      expect(clip.endMs, 6200 + kMiningTailPadMs);
    });

    test('显式 head/tail 生效，且先 pad 再 shift', () {
      final AudioCue cue = _cue(startMs: 5000, endMs: 6200, text: 'は');
      final AudioPlaybackRange? clip = miningSentenceAudioRange(
        cues: <AudioCue>[cue],
        cue: cue,
        sentence: 'は',
        headPadMs: 0,
        tailPadMs: 700,
        delayMs: -250,
      );
      // pad: 5000/6900；shift -250: 4750/6650。
      expect(clip!.startMs, 4750);
      expect(clip.endMs, 6650);
    });

    test('用户把 tail 调大也不越过下一句（夹边界保留）', () {
      final AudioCue cue = _cue(startMs: 5000, endMs: 6200, text: 'は');
      final AudioCue next = _cue(startMs: 6500, endMs: 8000, text: '次');
      final AudioPlaybackRange? clip = miningSentenceAudioRange(
        cues: <AudioCue>[cue, next],
        cue: cue,
        sentence: 'は',
        tailPadMs: 1000,
      );
      expect(clip!.endMs, 6500, reason: 'tail 被下一句起点夹住');
    });
  });

  group('调用点源码守卫', () {
    test('视频字幕制卡：同一 padSentenceRange、喂偏好、夹锚定 cue 所属流、先 pad 再 shift', () {
      final String src = File(
        'lib/src/pages/implementations/video_fushi/lookup_mining.part.dart',
      ).readAsStringSync();
      expect(src, contains('padSentenceRange('));
      expect(src, contains('headPadMs: appModel.miningAudioHeadPadMs'));
      expect(src, contains('tailPadMs: appModel.miningAudioTailPadMs'));
      expect(
        src,
        contains('controller.cueStreamOwning(cue)'),
        reason: '夹边界必须用锚定 cue 所属流（主/副字幕独立），不能硬认主流',
      );
      // 先 pad（字幕时基）再 miningClipTimeMs 逆变换：pad 结果必须是 shift 的输入。
      expect(src, contains('miningClipTimeMs(paddedRange?.startMs ?? 0'));
      expect(src, contains('miningClipTimeMs(paddedRange?.endMs ?? 0'));
      expect(
        src,
        isNot(contains('mergedRange?.startMs ?? cue?.startMs')),
        reason: '旧的未 pad 区间不能再直接进 shift',
      );
    });

    test('有声书制卡：miningSentenceAudioRange 喂偏好值', () {
      final String src = File(
        'lib/src/pages/implementations/reader_fushi/audiobook.part.dart',
      ).readAsStringSync();
      expect(src, contains('headPadMs: appModel.miningAudioHeadPadMs'));
      expect(src, contains('tailPadMs: appModel.miningAudioTailPadMs'));
    });

    test('Anki 设置页：两个滑块行 + 搜索条目，上限与偏好 clamp 共用 kMiningPadMaxMs', () {
      final String page = File(
        'lib/src/pages/implementations/anki_settings_page.dart',
      ).readAsStringSync();
      expect(page, contains("id: 'card_creation.anki.mining_audio_head_pad'"));
      expect(page, contains("id: 'card_creation.anki.mining_audio_tail_pad'"));
      expect(page, contains('value: appModel.miningAudioHeadPadMs'));
      expect(page, contains('onChanged: appModel.setMiningAudioHeadPadMs'));
      expect(page, contains('value: appModel.miningAudioTailPadMs'));
      expect(page, contains('onChanged: appModel.setMiningAudioTailPadMs'));
      expect(page, contains('max: kMiningPadMaxMs.toDouble()'));

      final String schema = File(
        'lib/src/settings/settings_schema_card_creation.dart',
      ).readAsStringSync();
      expect(
        schema,
        contains("id: 'card_creation.anki.mining_audio_head_pad'"),
      );
      expect(
        schema,
        contains("id: 'card_creation.anki.mining_audio_tail_pad'"),
      );

      final String prefs = File(
        'lib/src/models/preferences_repository.dart',
      ).readAsStringSync();
      expect(
        prefs,
        contains('.clamp(0, kMiningPadMaxMs)'),
        reason: '偏好 clamp 与滑块上限必须是同一个常量',
      );
    });
  });
}
