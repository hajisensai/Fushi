import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_remote_control_layout.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// 手机字幕遥控器控制卡按钮布局（`video_remote_control_layout`）：出厂布局、
/// 必需项、编解码与偏好持久化。
void main() {
  group('模型', () {
    test('出厂：主组 上一句 / 播放 / 下一句，次组 重播 / 收藏 / 回到当前句 / 选集 / 字幕轨 / 在线字幕 / 音量', () {
      final VideoRemoteControlLayout layout = VideoRemoteControlLayout.defaults;
      expect(layout.primaryItems, <VideoRemoteControlItem>[
        VideoRemoteControlItem.previousCue,
        VideoRemoteControlItem.playPause,
        VideoRemoteControlItem.nextCue,
      ]);
      expect(layout.secondaryItems, <VideoRemoteControlItem>[
        VideoRemoteControlItem.replayCue,
        VideoRemoteControlItem.favorite,
        VideoRemoteControlItem.followCurrent,
        VideoRemoteControlItem.episodes,
        VideoRemoteControlItem.subtitleTrack,
        VideoRemoteControlItem.subtitleSearch,
        VideoRemoteControlItem.volume,
      ]);
      expect(
        layout.removedItems,
        containsAll(<VideoRemoteControlItem>[
          VideoRemoteControlItem.speed,
          VideoRemoteControlItem.subtitleVisibility,
          VideoRemoteControlItem.seekBack,
          VideoRemoteControlItem.seekForward,
        ]),
      );
    });

    test('播放暂停是必需项：移出被拒，布局不变', () {
      final VideoRemoteControlLayout layout = VideoRemoteControlLayout.defaults;
      final VideoRemoteControlLayout next = layout.moveItem(
        VideoRemoteControlItem.playPause,
        VideoRemoteControlSlot.hidden,
      );
      expect(next, layout);
      expect(next.primaryItems, contains(VideoRemoteControlItem.playPause));
    });

    test('移动：托盘里的倍速拖进次组，收藏移出', () {
      final VideoRemoteControlLayout next = VideoRemoteControlLayout.defaults
          .moveItem(
            VideoRemoteControlItem.speed,
            VideoRemoteControlSlot.secondary,
            index: 0,
          )
          .moveItem(
            VideoRemoteControlItem.favorite,
            VideoRemoteControlSlot.hidden,
          );
      expect(next.secondaryItems.first, VideoRemoteControlItem.speed);
      expect(
        next.secondaryItems,
        isNot(contains(VideoRemoteControlItem.favorite)),
      );
      expect(next.removedItems, contains(VideoRemoteControlItem.favorite));
    });

    test('单实例：同一颗按钮不会同时在主组与次组', () {
      final VideoRemoteControlLayout next = VideoRemoteControlLayout.defaults
          .moveItem(
            VideoRemoteControlItem.replayCue,
            VideoRemoteControlSlot.primary,
          );
      expect(next.primaryItems, contains(VideoRemoteControlItem.replayCue));
      expect(
        next.secondaryItems,
        isNot(contains(VideoRemoteControlItem.replayCue)),
      );
    });
  });

  group('编解码', () {
    test('encode → decode 往返一致', () {
      final VideoRemoteControlLayout layout = VideoRemoteControlLayout.defaults
          .moveItem(
            VideoRemoteControlItem.seekBack,
            VideoRemoteControlSlot.primary,
            index: 0,
          )
          .moveItem(
            VideoRemoteControlItem.subtitleSearch,
            VideoRemoteControlSlot.hidden,
          );
      final VideoRemoteControlLayout decoded = VideoRemoteControlLayout.decode(
        layout.encode(),
      );
      expect(decoded, layout);
      expect(decoded.primaryItems.first, VideoRemoteControlItem.seekBack);
      final Map<String, dynamic> json =
          jsonDecode(layout.encode()) as Map<String, dynamic>;
      expect(json['version'], 1);
      expect(json['removed'], contains('subtitleSearch'));
    });

    test('空 / 坏 JSON 回出厂布局', () {
      for (final String raw in <String>[
        '',
        '   ',
        'not json',
        '[]',
        '{"slots": 3}',
        '{"version":1,"slots":{}}',
      ]) {
        expect(
          VideoRemoteControlLayout.decode(raw),
          VideoRemoteControlLayout.defaults,
          reason: raw,
        );
      }
    });

    test('存档里缺席的按钮（新版本新增）按出厂位置回填；未知名丢弃', () {
      final VideoRemoteControlLayout decoded = VideoRemoteControlLayout.decode(
        jsonEncode(<String, Object>{
          'version': 1,
          'slots': <String, List<String>>{
            'primary': <String>['playPause', 'futureButton'],
            'secondary': <String>['speed'],
          },
        }),
      );
      expect(decoded.primaryItems, <VideoRemoteControlItem>[
        VideoRemoteControlItem.playPause,
        VideoRemoteControlItem.previousCue,
        VideoRemoteControlItem.nextCue,
      ]);
      expect(decoded.secondaryItems.first, VideoRemoteControlItem.speed);
      expect(
        decoded.secondaryItems,
        contains(VideoRemoteControlItem.subtitleSearch),
      );
    });

    test('旧存档里的「制卡」按钮（已删除）解码时丢掉，其余按钮原位', () {
      final VideoRemoteControlLayout decoded = VideoRemoteControlLayout.decode(
        jsonEncode(<String, Object>{
          'version': 1,
          'slots': <String, List<String>>{
            'primary': <String>['previousCue', 'playPause', 'nextCue'],
            'secondary': <String>['replayCue', 'mine', 'favorite'],
          },
          'removed': <String>['mine', 'volume'],
        }),
      );
      expect(decoded.secondaryItems.take(2), <VideoRemoteControlItem>[
        VideoRemoteControlItem.replayCue,
        VideoRemoteControlItem.favorite,
      ]);
      expect(decoded.removedItems, contains(VideoRemoteControlItem.volume));
      expect(decoded.encode(), isNot(contains('"mine"')));
    });

    test('存档把播放暂停写进 removed 也会被恢复到主组', () {
      final VideoRemoteControlLayout decoded = VideoRemoteControlLayout.decode(
        jsonEncode(<String, Object>{
          'version': 1,
          'slots': <String, List<String>>{
            'primary': <String>['previousCue'],
            'secondary': <String>['replayCue'],
          },
          'removed': <String>['playPause'],
        }),
      );
      expect(decoded.primaryItems, contains(VideoRemoteControlItem.playPause));
      expect(
        decoded.removedItems,
        isNot(contains(VideoRemoteControlItem.playPause)),
      );
    });
  });

  group('偏好持久化', () {
    late FushiDatabase db;
    late PreferencesRepository prefs;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
    });

    tearDown(() async {
      prefs.dispose();
      await db.close();
    });

    test('没存过 = 出厂布局', () {
      expect(prefs.videoRemoteControlLayout, VideoRemoteControlLayout.defaults);
    });

    test('写入后重新加载仍读得回来，并通知监听者', () async {
      int notified = 0;
      prefs.addListener(() => notified++);
      final VideoRemoteControlLayout custom = VideoRemoteControlLayout.defaults
          .moveItem(
            VideoRemoteControlItem.subtitleVisibility,
            VideoRemoteControlSlot.secondary,
          );
      await prefs.setVideoRemoteControlLayout(custom);
      expect(notified, greaterThan(0));
      await prefs.loadFromDb();
      expect(prefs.videoRemoteControlLayout, custom);
    });

    test('键登记在 preference_keys.dart', () {
      expect(kKnownPreferenceKeys, contains('video_remote_control_layout'));
    });
  });
}
