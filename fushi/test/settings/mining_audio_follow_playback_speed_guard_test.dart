import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// 有声书倍速制卡：「句子音频跟随播放倍速」开关守卫。
///
/// 锁住四层契约（不依赖真机 / ffmpeg）：
/// 1. 偏好默认**开**（用户开着 1.5× 听书，卡片句子音频就是 1.5× 的）+ 写穿 Drift +
///    key 在白名单；
/// 2. 阅读器制卡调用点：开关开 → 把控制器**实时**倍速作 `tempo` 喂给
///    `TtsChannel.extractAudioSegment`；关 → null（与现状逐字节相同的参数表）；
/// 3. `TtsChannel.extractAudioSegment` 把 `tempo` 透传到 `extractAudioSegmentViaFfmpeg`；
/// 4. Anki 设置页有开关行 + 搜索条目，wire 到 AppModel 的 getter/toggle。
///
/// 桌面 ffmpeg-min 必须编入 `atempo`（`tool/ffmpeg-min/build-ffmpeg-min.sh` FILTERS），
/// 配方与入库二进制的一致性由 `ffmpeg_min_vendored_recipe_guard_test.dart` 钉住；这里
/// 只钉配方本身列了它。

FushiDatabase _testDb() {
  return FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
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
      // setter 是 `void ... async` 的 fire-and-forget；补一次可 await 的写把前面
      // 未决写冲干净，避免 db.close() 之后才落地。
      await repo.setPref('_drain_pending_writes', 1);
      repo.dispose();
      await db.close();
    });

    test('默认开', () {
      expect(repo.miningAudioFollowPlaybackSpeed, isTrue,
          reason: '默认值改了就是行为变更，必须有意');
    });

    test('toggle 写穿 Drift（往返 + DB key）', () async {
      repo.toggleMiningAudioFollowPlaybackSpeed();
      expect(repo.miningAudioFollowPlaybackSpeed, isFalse);

      await repo.setPref('mining_audio_follow_playback_speed', false);
      final PreferencesRepository restored = PreferencesRepository(db);
      await restored.loadFromDb();
      expect(restored.miningAudioFollowPlaybackSpeed, isFalse,
          reason: '设过必须落盘且跨实例可见');
      final Map<String, String> prefs = await db.getAllPrefs();
      expect(
        prefs.containsKey('mining_audio_follow_playback_speed'),
        isTrue,
        reason: 'DB key 必须是 mining_audio_follow_playback_speed',
      );
      restored.dispose();

      repo.toggleMiningAudioFollowPlaybackSpeed();
      expect(repo.miningAudioFollowPlaybackSpeed, isTrue);
    });

    test('key 在偏好白名单里', () {
      expect(
        kKnownPreferenceKeys,
        contains('mining_audio_follow_playback_speed'),
      );
    });
  });

  group('调用点源码守卫', () {
    test('有声书制卡：开关开 → 控制器实时倍速作 tempo；关 → null', () {
      final String src = File(
        'lib/src/pages/implementations/reader_fushi/mining.part.dart',
      ).readAsStringSync();
      expect(src, contains('appModel.miningAudioFollowPlaybackSpeed'));
      expect(
        src,
        contains('? _audiobookController?.speed'),
        reason: '读的必须是控制器当前实时倍速（用户刚拨的倍速就是这次制卡的倍速），'
            '不是落库偏好',
      );
      expect(src, contains('tempo: sentenceAudioTempo,'));
    });

    test('TtsChannel.extractAudioSegment 透传 tempo 到 ffmpeg 裁剪', () {
      final String src =
          File('lib/src/utils/misc/tts_channel.dart').readAsStringSync();
      expect(src, contains('double? tempo,'));
      expect(src, contains('tempo: tempo,'));
    });

    test('视频制卡链不读这个开关（仅有声书语境）', () {
      final String src = File(
        'lib/src/pages/implementations/video_fushi/lookup_mining.part.dart',
      ).readAsStringSync();
      expect(src, isNot(contains('miningAudioFollowPlaybackSpeed')));
    });

    test('Anki 设置页：开关行 + 搜索条目，wire 到 AppModel', () {
      final String page = File(
        'lib/src/pages/implementations/anki_settings_page.dart',
      ).readAsStringSync();
      expect(
        page,
        contains("id: 'card_creation.anki.mining_audio_follow_playback_speed'"),
      );
      expect(page, contains('value: appModel.miningAudioFollowPlaybackSpeed'));
      expect(page, contains('appModel.toggleMiningAudioFollowPlaybackSpeed()'));

      final String schema = File(
        'lib/src/settings/settings_schema_card_creation.dart',
      ).readAsStringSync();
      expect(
        schema,
        contains("id: 'card_creation.anki.mining_audio_follow_playback_speed'"),
      );
    });

    test('桌面 ffmpeg-min 配方编入 atempo', () {
      final String recipe = File(
        '../tool/ffmpeg-min/build-ffmpeg-min.sh',
      ).readAsStringSync();
      final RegExpMatch? filters =
          RegExp(r'^FILTERS="([^"]*)"', multiLine: true).firstMatch(recipe);
      expect(filters, isNotNull);
      expect(
        filters!.group(1)!.split(','),
        contains('atempo'),
        reason: '倍速制卡的 -af atempo 在精简构建里缺滤镜就整条 ffmpeg 失败',
      );
    });
  });
}
