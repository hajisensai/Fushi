import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/media/video/video_control_item_presentation.dart';
import 'package:fushi/src/media/video/video_custom_action_bindings.dart';
import 'package:fushi/src/media/video/video_player_shortcuts.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_labels.dart';

/// 哑动作实例：每个回调都是 no-op，只用来把 [videoActionCallbacks] 的 **keys** 取出来。
/// 守卫比对的是「哪些动作接过线」，与回调具体做什么无关。
VideoPlayerShortcutActions _dummyActions() {
  void noop() {}
  return VideoPlayerShortcutActions(
    togglePlayPause: noop,
    play: noop,
    pause: noop,
    previousSubtitle: noop,
    nextSubtitle: noop,
    replayCurrentSubtitle: noop,
    replayPreviousSubtitle: noop,
    seekBackward: noop,
    seekForward: noop,
    toggleShaderCompare: noop,
    volumeUp: noop,
    volumeDown: noop,
    toggleMute: noop,
    speedUp: noop,
    speedDown: noop,
    resetSpeed: noop,
    toggleHoldSpeed: noop,
    previousFrame: noop,
    nextFrame: noop,
    screenshot: noop,
    toggleFullscreen: noop,
    toggleSubtitleList: noop,
    toggleImmersiveLock: noop,
    toggleSubtitleBlur: noop,
    cycleSubtitleObscure: noop,
    toggleSubtitleHide: noop,
    cycleSecondarySubtitleObscure: noop,
    toggleSecondarySubtitleHide: noop,
    toggleFavoriteSentence: noop,
    previousChapter: noop,
    nextChapter: noop,
    openSubtitleAlign: noop,
    subtitleDelayIncrease: noop,
    subtitleDelayDecrease: noop,
    alignSubtitleToPrev: noop,
    alignSubtitleToNext: noop,
    enterCaret: noop,
    escape: noop,
  );
}

void main() {
  group('VideoCustomActionBindings 编解码', () {
    test('空串解出全空表', () {
      final VideoCustomActionBindings b = VideoCustomActionBindings.decode('');
      expect(b, VideoCustomActionBindings.empty);
      expect(b.isEmpty, isTrue);
      for (int i = 0; i < VideoCustomActionBindings.slotCount; i++) {
        expect(b.actionAt(i), isNull);
      }
    });

    test('全空表编码回空串（「全空」只有一种写法）', () {
      // 与偏好默认值（空串）重合：解绑回初始态后存储里不该留一条 ",,," 这样
      // 看着像配置过、实际什么都没绑的垃圾。
      expect(VideoCustomActionBindings.empty.encode(), '');
      final VideoCustomActionBindings roundTrip = VideoCustomActionBindings
          .empty
          .withAction(0, ShortcutAction.videoPlay)
          .withAction(0, null);
      expect(roundTrip.encode(), '');
      expect(VideoCustomActionBindings.decode(roundTrip.encode()),
          VideoCustomActionBindings.empty);
    });

    test('round-trip 保持每个槽位的动作与位置', () {
      final VideoCustomActionBindings b = VideoCustomActionBindings.empty
          .withAction(0, ShortcutAction.videoNextSubtitle)
          .withAction(2, ShortcutAction.videoToggleSubtitleBlur);
      final VideoCustomActionBindings back =
          VideoCustomActionBindings.decode(b.encode());
      expect(back, b);
      expect(back.actionAt(0), ShortcutAction.videoNextSubtitle);
      expect(back.actionAt(1), isNull);
      expect(back.actionAt(2), ShortcutAction.videoToggleSubtitleBlur);
      expect(back.actionAt(3), isNull);
    });

    test('未知 / 已删除的动作 key 降级成未绑定，不抛异常', () {
      // 动作在新版里被删名后，老配置必须照样能读出一张合法的表（这条路径在启动读
      // 偏好时跑，抛异常就是白屏）。
      final VideoCustomActionBindings b = VideoCustomActionBindings.decode(
        'video_next_subtitle,this_action_no_longer_exists,,',
      );
      expect(b.actionAt(0), ShortcutAction.videoNextSubtitle);
      expect(b.actionAt(1), isNull);
    });

    test('长度不匹配的老 payload 按位截断 / 补空', () {
      final VideoCustomActionBindings short =
          VideoCustomActionBindings.decode('video_play');
      expect(short.actionAt(0), ShortcutAction.videoPlay);
      expect(short.actionAt(1), isNull);

      final VideoCustomActionBindings long = VideoCustomActionBindings.decode(
        'video_play,video_pause,video_play,video_pause,video_play,video_pause',
      );
      expect(long.actionAt(3), ShortcutAction.videoPause);
      // 超出 slotCount 的部分被丢弃，不影响表内合法槽位。
      expect(
          long.encode().split(',').length, VideoCustomActionBindings.slotCount);
    });

    test('越界读写安全：不抛异常、不改表', () {
      const VideoCustomActionBindings b = VideoCustomActionBindings.empty;
      expect(b.actionAt(-1), isNull);
      expect(b.actionAt(VideoCustomActionBindings.slotCount), isNull);
      expect(b.withAction(99, ShortcutAction.videoPlay), b);
    });
  });

  group('槽位与按钮的接线守卫', () {
    test('槽位数与 customAction 枚举项数一一对应', () {
      // 改 slotCount 却没加/删对应枚举项 = 「有槽位没按钮」或「有按钮没槽位」。
      expect(
        VideoControlItem.customActionItems.length,
        VideoCustomActionBindings.slotCount,
      );
      // 槽位下标必须是 0..slotCount-1 且不重不漏。
      expect(
        VideoControlItem.customActionItems
            .map((VideoControlItem i) => i.customActionSlotIndex)
            .toList(),
        List<int>.generate(VideoCustomActionBindings.slotCount, (int i) => i),
      );
    });

    test('自定义按钮是 chip-renderable（否则编辑器里根本摆不上去）', () {
      for (final VideoControlItem item in VideoControlItem.customActionItems) {
        expect(item.isChipRenderable, isTrue, reason: item.storageValue);
        expect(
          VideoControlItem.customizableItems.contains(item),
          isTrue,
          reason: '${item.storageValue} 必须出现在编辑器调色板里',
        );
      }
    });

    test('非自定义按钮的 customActionSlotIndex 恒为 null', () {
      for (final VideoControlItem item in VideoControlItem.values) {
        if (item.isCustomAction) continue;
        expect(item.customActionSlotIndex, isNull, reason: item.storageValue);
      }
    });
  });

  group('可绑动作表守卫', () {
    test('kVideoAssignableActions 与 videoActionCallbacks 的 keys 完全一致', () {
      // 这是本功能最关键的不变式：选择列表里出现、但页面没接线的动作 = 用户配得上、
      // 按了没反应；反过来接了线却不在列表里 = 用户根本选不到。设置页拿不到 live
      // controller，只能维护一份常量表，故必须在这里和真实接线逐个对齐。
      final Set<ShortcutAction> wired =
          videoActionCallbacks(_dummyActions()).keys.toSet();
      final Set<ShortcutAction> assignable = kVideoAssignableActions.toSet();
      expect(
        assignable.difference(wired),
        isEmpty,
        reason: '这些动作在选择列表里但页面没接线（按了会没反应）',
      );
      expect(
        wired.difference(assignable),
        isEmpty,
        reason: '这些动作页面接了线但用户选不到（漏加进 kVideoAssignableActions）',
      );
    });

    test('可绑动作表无重复项', () {
      expect(
        kVideoAssignableActions.toSet().length,
        kVideoAssignableActions.length,
      );
    });

    test('每个可绑动作都有专属图标', () {
      // 没有图标就会退化成通用闪电图标，而「按钮长成它绑的那个动作」正是这个功能的
      // 设计承诺（用户拍板：显示动作图标而非数字 1/2/3）。
      for (final ShortcutAction action in kVideoAssignableActions) {
        expect(
          action.buttonIcon,
          isNotNull,
          reason: '${action.key} 缺按钮图标（ShortcutActionIcon.buttonIcon）',
        );
      }
    });

    test('每个可绑动作都有非空本地化名字', () {
      for (final ShortcutAction action in kVideoAssignableActions) {
        expect(action.label, isNotEmpty, reason: action.key);
      }
    });
  });

  group('默认布局向后兼容', () {
    test('老配置解码后自定义按钮落底栏右区（可见），且不打乱原有布局', () {
      // 用户拍板「未绑定也显示」后，这条的语义反过来了：老用户升级**必须**能在播放器上
      // 看到这 4 个按钮，否则得先翻进编辑器把它们从隐藏托盘拖出来才知道有这功能。
      // 兜底槽位由 [VideoControlLayout.currentChrome] 的 assignment 决定——它同时是老
      // 布局解码时「这个没见过的 item 该放哪」的唯一依据，漏写就会被判成「用户移除过」。
      const String legacyV2 =
          '{"version":2,"slots":{"bottomRight":["speed","settings"],'
          '"bottomCenter":["playPause"]}}';
      final VideoControlLayout layout = VideoControlLayout.decode(legacyV2);
      // 老 payload 原有按钮原地不动。
      expect(
        layout.itemsIn(VideoControlSlot.bottomCenter),
        contains(VideoControlItem.playPause),
      );
      expect(
        layout.itemsIn(VideoControlSlot.bottomRight),
        containsAll(<VideoControlItem>[
          VideoControlItem.speed,
          VideoControlItem.settings,
        ]),
      );
      for (final VideoControlItem item in VideoControlItem.customActionItems) {
        // 落在底栏右区且可见，不进 removed。
        expect(
          layout.itemsIn(VideoControlSlot.bottomRight),
          contains(item),
          reason: '${item.storageValue} 升级后应可见于底栏右区',
        );
        expect(layout.slotOf(item), VideoControlSlot.bottomRight);
        // 不挤进老用户的底栏中区（传输键簇）。
        expect(
          layout.itemsIn(VideoControlSlot.bottomCenter).contains(item),
          isFalse,
          reason: '${item.storageValue} 不该出现在底栏中区',
        );
      }
    });

    test('用户把自定义按钮拖进隐藏托盘后，解码回来仍是隐藏的', () {
      // 「未绑定也显示」是默认值，不是强制值——不想要的人拖走之后必须留得住，
      // 否则每次启动都会自己冒回来。
      const String v3Hidden =
          '{"version":3,"slots":{"bottomCenter":["playPause"]},'
          '"removed":["customAction1","customAction2",'
          '"customAction3","customAction4"]}';
      final VideoControlLayout layout = VideoControlLayout.decode(v3Hidden);
      for (final VideoControlItem item in VideoControlItem.customActionItems) {
        expect(
          layout.slotOf(item),
          VideoControlSlot.hidden,
          reason: '${item.storageValue} 被移除后不该自己回到播放器上',
        );
      }
    });

    test('默认布局里自定义按钮可被移除（不是 pinned）', () {
      for (final VideoControlItem item in VideoControlItem.customActionItems) {
        expect(item.canBeRemovedFromPlayer, isTrue);
        expect(item.pinnedRequired, isFalse);
      }
    });
  });

  group('presentation 按绑定解析', () {
    testWidgets('未绑定显示槽位名 + 通用图标；绑定后显示动作名 + 动作图标', (WidgetTester tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              ctx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      const VideoControlItem slot1 = VideoControlItem.customAction1;
      // 未绑定：通用图标 + 「快捷键 1」这类槽位名（非空）。
      expect(
        videoControlItemIcon(
          slot1,
          bindings: VideoCustomActionBindings.empty,
        ),
        Icons.bolt_outlined,
      );
      // 完全不传 bindings 也必须退回通用图标（编辑器调色板路径）。
      expect(videoControlItemIcon(slot1), Icons.bolt_outlined);
      final String emptyLabel = videoControlItemLabel(
        slot1,
        ctx,
        bindings: VideoCustomActionBindings.empty,
      );
      expect(emptyLabel, isNotEmpty);
      expect(emptyLabel, isNot(ShortcutAction.videoNextSubtitle.label));

      // 绑定后：图标与名字都跟着动作走。
      final VideoCustomActionBindings bound = VideoCustomActionBindings.empty
          .withAction(0, ShortcutAction.videoNextSubtitle);
      expect(
        videoControlItemIcon(slot1, bindings: bound),
        ShortcutAction.videoNextSubtitle.buttonIcon,
      );
      expect(
        videoControlItemLabel(slot1, ctx, bindings: bound),
        ShortcutAction.videoNextSubtitle.label,
      );
      // 只绑了槽位 1，槽位 2 仍是未绑定外观（不串位）。
      expect(
        videoControlItemIcon(
          VideoControlItem.customAction2,
          bindings: bound,
        ),
        Icons.bolt_outlined,
      );
    });
  });
}
