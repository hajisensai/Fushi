import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/hibiki_library_host_service.dart';

/// 守卫：断点 prefs 键「三件套」抽成 [PositionPrefKeys] 生成器后，**键字符串必须
/// 逐字节不变**——这些键落在用户 Drift `preferences` 表里，是持久化契约；任何
/// 前缀/拼接变化都会让既有进度静默丢失。若本测试失败，说明有人动了键公式：
/// 恢复公式，而不是改断言。
void main() {
  group('视频远端断点键（video_remote_position_*）逐字节冻结', () {
    test('位置键 / 时间戳键 / 集数变体', () {
      expect(videoRemotePositionPrefKey('video/my_film'),
          'video_remote_position_video/my_film');
      expect(videoRemotePositionAtPrefKey('video/my_film'),
          'video_remote_position_at_video/my_film');
      // 集数变体（TODO-885）：index<=0 回退整书键；index>0 带 #ep 后缀。
      expect(
          videoRemotePositionEpisodePrefKey('u', 0), 'video_remote_position_u');
      expect(videoRemotePositionEpisodePrefKey('u', 2),
          'video_remote_position_u#ep2');
      expect(videoRemotePositionEpisodeAtPrefKey('u', 0),
          'video_remote_position_at_u');
      expect(videoRemotePositionEpisodeAtPrefKey('u', 2),
          'video_remote_position_at_u#ep2');
    });

    test('位置键逆解析：排除更长前缀的 at_ 时间戳键', () {
      expect(
          videoUidFromRemotePositionPrefKey('video_remote_position_u1'), 'u1');
      // 时间戳键绝不能被误解析成「以 at_ 开头的 uid」。
      expect(videoUidFromRemotePositionPrefKey('video_remote_position_at_u1'),
          isNull);
      expect(
          videoUidFromRemotePositionPrefKey('video_remote_position_'), isNull);
      expect(videoUidFromRemotePositionPrefKey('unrelated_key'), isNull);
    });
  });

  group('有声书断点键（audiobook_pos_*）逐字节冻结', () {
    test('位置键 / 时间戳键', () {
      expect(audiobookPositionPrefKey('bookA'), 'audiobook_pos_bookA');
      expect(audiobookPositionAtPrefKey('bookA'), 'audiobook_pos_at_bookA');
    });

    test('位置键逆解析：排除更长前缀的 at_ 时间戳键', () {
      expect(audiobookKeyFromPositionPrefKey('audiobook_pos_bookA'), 'bookA');
      expect(audiobookKeyFromPositionPrefKey('audiobook_pos_at_bookA'), isNull);
      expect(audiobookKeyFromPositionPrefKey('audiobook_pos_'), isNull);
      expect(audiobookKeyFromPositionPrefKey('unrelated_key'), isNull);
    });
  });

  group('PositionPrefKeys 生成器本体', () {
    test('两个冻结实例的前缀逐字节正确', () {
      expect(
          videoRemotePositionPrefKeys.positionPrefix, 'video_remote_position_');
      expect(videoRemotePositionPrefKeys.atPrefix, 'video_remote_position_at_');
      expect(audiobookPositionPrefKeys.positionPrefix, 'audiobook_pos_');
      expect(audiobookPositionPrefKeys.atPrefix, 'audiobook_pos_at_');
    });

    test('roundtrip：positionKey → idFromPositionKey 恒等；atKey 恒 null', () {
      for (final PositionPrefKeys keys in <PositionPrefKeys>[
        videoRemotePositionPrefKeys,
        audiobookPositionPrefKeys,
      ]) {
        for (final String id in <String>['a', 'video/嵌套/名', 'u#ep3']) {
          expect(keys.idFromPositionKey(keys.positionKey(id)), id);
          expect(keys.idFromPositionKey(keys.atKey(id)), isNull);
        }
        // 已知歧义（旧实现同款语义，冻结）：字面以 `at_` 开头的 id 与时间戳键
        // 无法区分，逆解析保守返回 null（宁可漏枚举也不误把时间戳当 id）。
        expect(keys.idFromPositionKey(keys.positionKey('at_x')), isNull);
      }
    });
  });
}
