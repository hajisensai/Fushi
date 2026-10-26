import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/media/video/video_immersive_control_layout.dart';

/// 沉浸布局模型（设计案 `docs/specs/2026-10-25-video-immersive-one-hand.md` §3.2）：
/// 默认派生、锁按钮必选且唯一、编解码与坏值回落。
void main() {
  VideoControlLayout baseWithLock(List<VideoControlSlot> slots) {
    VideoControlLayout layout = VideoControlLayout.currentChrome
        .removeItemFromSlot(
          VideoControlItem.immersiveLock,
          VideoControlSlot.screenLeft,
        );
    for (final VideoControlSlot slot in slots) {
      layout = layout.addItemToSlot(VideoControlItem.immersiveLock, slot);
    }
    return layout;
  }

  List<VideoImmersiveItem> left(VideoImmersiveControlLayout l) =>
      l.itemsIn(VideoImmersiveSlot.screenLeft);
  List<VideoImmersiveItem> right(VideoImmersiveControlLayout l) =>
      l.itemsIn(VideoImmersiveSlot.screenRight);

  group('默认派生：只有锁按钮，位置跟普通布局', () {
    test('出厂普通布局（锁在左栏）→ 锁在左栏，右栏为空', () {
      final VideoImmersiveControlLayout l =
          VideoImmersiveControlLayout.derivedFrom(
            VideoControlLayout.currentChrome,
          );
      expect(left(l), <VideoImmersiveItem>[VideoImmersiveItem.immersiveLock]);
      expect(right(l), isEmpty);
    });

    test('普通布局锁只在右栏 → 右栏', () {
      final VideoImmersiveControlLayout l =
          VideoImmersiveControlLayout.derivedFrom(
            baseWithLock(<VideoControlSlot>[VideoControlSlot.screenRight]),
          );
      expect(left(l), isEmpty);
      expect(right(l), <VideoImmersiveItem>[VideoImmersiveItem.immersiveLock]);
    });

    test('普通布局锁在顶栏 / 底栏 / 已移出 → 左栏（历史解锁口位置）', () {
      for (final List<VideoControlSlot> slots in <List<VideoControlSlot>>[
        <VideoControlSlot>[VideoControlSlot.topRight],
        <VideoControlSlot>[VideoControlSlot.bottomRight],
        <VideoControlSlot>[],
      ]) {
        final VideoImmersiveControlLayout l =
            VideoImmersiveControlLayout.derivedFrom(baseWithLock(slots));
        expect(left(l), <VideoImmersiveItem>[
          VideoImmersiveItem.immersiveLock,
        ], reason: '$slots');
        expect(right(l), isEmpty, reason: '$slots');
      }
    });

    test('普通布局两侧都有锁 → 左栏', () {
      final VideoImmersiveControlLayout l =
          VideoImmersiveControlLayout.derivedFrom(
            baseWithLock(<VideoControlSlot>[
              VideoControlSlot.screenLeft,
              VideoControlSlot.screenRight,
            ]),
          );
      expect(left(l), <VideoImmersiveItem>[VideoImmersiveItem.immersiveLock]);
      expect(right(l), isEmpty);
    });

    test('空串 / 坏值 / 未知版本解码一律回派生默认', () {
      final VideoImmersiveControlLayout derived =
          VideoImmersiveControlLayout.derivedFrom(
            VideoControlLayout.currentChrome,
          );
      for (final String raw in <String>[
        '',
        'not json',
        '[]',
        '{"version":2,"slots":{}}',
        '{"version":1}',
      ]) {
        expect(
          VideoImmersiveControlLayout.decode(
            raw,
            base: VideoControlLayout.currentChrome,
          ),
          derived,
          reason: raw,
        );
      }
    });
  });

  group('锁按钮必选且唯一', () {
    test('锁按钮拖不进隐藏托盘', () {
      final VideoImmersiveControlLayout l =
          VideoImmersiveControlLayout.derivedFrom(
            VideoControlLayout.currentChrome,
          );
      final VideoImmersiveControlLayout moved =
          VideoImmersiveControlLayout.fromCore(
            l.core.moveItem(
              VideoImmersiveItem.immersiveLock,
              VideoImmersiveSlot.hidden,
            ),
          );
      expect(left(moved), contains(VideoImmersiveItem.immersiveLock));
      expect(
        VideoImmersiveItem.immersiveLock.canMoveToSlot(
          VideoImmersiveSlot.hidden,
        ),
        isFalse,
      );
    });

    test('载荷两侧都写了锁 → 只留左栏那一份', () {
      final VideoImmersiveControlLayout l = VideoImmersiveControlLayout.decode(
        jsonEncode(<String, Object>{
          'version': 1,
          'slots': <String, Object>{
            'screenLeft': <String>['immersiveLock'],
            'screenRight': <String>['immersiveLock', 'favoriteSentence'],
          },
        }),
        base: VideoControlLayout.currentChrome,
      );
      expect(left(l), <VideoImmersiveItem>[VideoImmersiveItem.immersiveLock]);
      expect(right(l), <VideoImmersiveItem>[
        VideoImmersiveItem.favoriteSentence,
      ]);
    });

    test('载荷里没有锁 → 回到派生那一侧', () {
      final VideoImmersiveControlLayout l = VideoImmersiveControlLayout.decode(
        jsonEncode(<String, Object>{
          'version': 1,
          'slots': <String, Object>{
            'screenRight': <String>['previousCue', 'nextCue'],
          },
        }),
        base: baseWithLock(<VideoControlSlot>[VideoControlSlot.screenRight]),
      );
      expect(l.lockSlot, VideoImmersiveSlot.screenRight);
      expect(right(l), contains(VideoImmersiveItem.previousCue));
      expect(right(l), contains(VideoImmersiveItem.nextCue));
    });
  });

  test('单手排列编码后原样解码回来（顺序保留，未放的按钮不冒出来）', () {
    final VideoImmersiveControlLayout l = VideoImmersiveControlLayout.decode(
      jsonEncode(<String, Object>{
        'version': 1,
        'slots': <String, Object>{
          'screenLeft': <String>['immersiveLock'],
          'screenRight': <String>['previousCue', 'favoriteSentence', 'nextCue'],
        },
      }),
      base: VideoControlLayout.currentChrome,
    );
    expect(right(l), <VideoImmersiveItem>[
      VideoImmersiveItem.previousCue,
      VideoImmersiveItem.favoriteSentence,
      VideoImmersiveItem.nextCue,
    ]);
    final VideoImmersiveControlLayout round =
        VideoImmersiveControlLayout.decode(
          l.encode(),
          base: VideoControlLayout.currentChrome,
        );
    expect(round, l);
    expect(left(round), <VideoImmersiveItem>[VideoImmersiveItem.immersiveLock]);
    expect(
      <VideoImmersiveItem>[...left(round), ...right(round)],
      isNot(contains(VideoImmersiveItem.playPause)),
      reason: '没放进来的按钮（含以后新增的）一律留在隐藏托盘',
    );
  });

  test('可放按钮全部能对应到普通按钮库，且存储名一致', () {
    for (final VideoImmersiveItem item in VideoImmersiveItem.values) {
      expect(item.storageValue, item.controlItem.storageValue);
    }
  });
}
