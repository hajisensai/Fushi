import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_apple_chrome_plan.dart';
import 'package:fushi/src/media/video/video_control_customization.dart';

bool _all(VideoControlItem item) => true;

List<VideoControlItem> _items(List<VideoApplePlacement> placements) =>
    <VideoControlItem>[for (final VideoApplePlacement p in placements) p.item];

/// 一个按钮在方案 C 里能被找到的全部去处：可见区域、侧栏、或「⋯」（被移出播放器 /
/// 额外收进「⋯」）。
bool _reachable(
  VideoAppleChromePlan plan,
  VideoControlLayout layout,
  VideoControlItem item,
) {
  if (plan.placedItems.contains(item)) return true;
  if (_items(plan.extraFolded).contains(item)) return true;
  if (layout.removedItems.contains(item)) return true;
  for (final VideoControlSlot rail in const <VideoControlSlot>[
    VideoControlSlot.screenLeft,
    VideoControlSlot.screenRight,
  ]) {
    if (layout.itemsIn(rail).contains(item) &&
        !plan.railsExclude.contains(item)) {
      return true;
    }
  }
  return false;
}

void main() {
  group('planVideoAppleChrome 出厂布局（方案 C）', () {
    test('macOS：右上 字幕 / 截图，底部条 播放 −10 +10 起首、设置在全屏前', () {
      final VideoAppleChromePlan plan = planVideoAppleChrome(
        layout: VideoControlLayout.currentChrome,
        form: VideoAppleChromeForm.desktop,
        renders: _all,
      );
      expect(plan.showBack, isTrue);
      expect(plan.showTitle, isTrue);
      expect(_items(plan.transport), <VideoControlItem>[
        VideoControlItem.playPause,
        VideoControlItem.seekBackward,
        VideoControlItem.seekForward,
      ]);
      expect(_items(plan.topTrailing), <VideoControlItem>[
        VideoControlItem.episodeList,
        VideoControlItem.chapterList,
        VideoControlItem.subtitleTrack,
        VideoControlItem.liveChat,
        VideoControlItem.screenshot,
      ]);
      expect(_items(plan.bottomTrailing), <VideoControlItem>[
        VideoControlItem.volume,
        VideoControlItem.speed,
        VideoControlItem.subtitleList,
        VideoControlItem.settings,
        VideoControlItem.fullscreen,
      ]);
      expect(plan.bottomLeading, isEmpty);
      expect(plan.showPositionIndicator, isTrue);
      // 字幕列表从屏幕右侧栏搬进底部条，侧栏不再重复画。
      expect(plan.railsExclude, contains(VideoControlItem.subtitleList));
    });

    test('iOS：右上 字幕 / 设置（设置常驻、不进「⋯」），截图进「⋯」', () {
      final VideoAppleChromePlan plan = planVideoAppleChrome(
        layout: VideoControlLayout.currentChrome,
        form: VideoAppleChromeForm.touch,
        renders: _all,
      );
      expect(
        _items(plan.topTrailing),
        containsAllInOrder(<VideoControlItem>[
          VideoControlItem.subtitleTrack,
          VideoControlItem.settings,
        ]),
      );
      expect(
        _items(plan.topTrailing),
        isNot(contains(VideoControlItem.screenshot)),
      );
      expect(_items(plan.extraFolded), <VideoControlItem>[
        VideoControlItem.screenshot,
      ]);
      expect(
        _items(plan.bottomTrailing),
        isNot(contains(VideoControlItem.settings)),
      );
    });
  });

  group('画面中央不放控件', () {
    for (final VideoAppleChromeForm form in VideoAppleChromeForm.values) {
      test('${form.name}：播放 / ±10 只在底部传输组，别处不重复', () {
        // 用户把 ±10 与播放摆进顶部与底部别的槽：仍只在底部条首位出现一次。
        final VideoControlLayout layout = VideoControlLayout.currentChrome
            .addItemToSlot(
              VideoControlItem.seekBackward,
              VideoControlSlot.topRight,
            )
            .addItemToSlot(
              VideoControlItem.seekForward,
              VideoControlSlot.bottomRight,
            )
            .addItemToSlot(
              VideoControlItem.playPause,
              VideoControlSlot.topLeft,
            );
        final VideoAppleChromePlan plan = planVideoAppleChrome(
          layout: layout,
          form: form,
          renders: _all,
        );
        expect(_items(plan.transport), kVideoAppleTransportItems);
        for (final List<VideoApplePlacement> region
            in <List<VideoApplePlacement>>[
              plan.topTrailing,
              plan.bottomLeading,
              plan.bottomTrailing,
            ]) {
          for (final VideoControlItem item in kVideoAppleTransportItems) {
            expect(_items(region), isNot(contains(item)));
          }
        }
        // ±10 出厂在 hidden：「⋯」里也不再出现。
        expect(videoAppleFoldedExcludes(VideoControlItem.seekBackward), isTrue);
        expect(videoAppleFoldedExcludes(VideoControlItem.seekForward), isTrue);
      });
    }
  });

  group('自定义布局按钮不丢', () {
    // 截图里那位用户的布局：底中 8 键、左收藏、右音量 / 全屏 / 倍速 / 字幕列表 / 快捷键。
    final VideoControlLayout custom = VideoControlLayout.fromSlots(
      <VideoControlSlot, List<VideoControlItem>>{
        VideoControlSlot.topLeft: <VideoControlItem>[VideoControlItem.back],
        VideoControlSlot.topCenter: <VideoControlItem>[VideoControlItem.title],
        VideoControlSlot.topRight: <VideoControlItem>[
          VideoControlItem.screenshot,
          VideoControlItem.clipExport,
          VideoControlItem.subtitleTrack,
          VideoControlItem.audioTrack,
          VideoControlItem.settings,
        ],
        VideoControlSlot.bottomLeft: <VideoControlItem>[
          VideoControlItem.positionIndicator,
          VideoControlItem.favoriteSentence,
        ],
        VideoControlSlot.bottomCenter: <VideoControlItem>[
          VideoControlItem.previousCue,
          VideoControlItem.seekBackward,
          VideoControlItem.frameBackward,
          VideoControlItem.playPause,
          VideoControlItem.frameForward,
          VideoControlItem.seekForward,
          VideoControlItem.nextCue,
          VideoControlItem.replayCue,
        ],
        VideoControlSlot.bottomRight: <VideoControlItem>[
          VideoControlItem.volume,
          VideoControlItem.fullscreen,
          VideoControlItem.speed,
          VideoControlItem.subtitleList,
          VideoControlItem.customAction1,
        ],
        VideoControlSlot.screenLeft: <VideoControlItem>[
          VideoControlItem.immersiveLock,
        ],
      },
    );

    for (final VideoAppleChromeForm form in VideoAppleChromeForm.values) {
      test('${form.name}：每个放在播放器上的按钮都有去处', () {
        final VideoAppleChromePlan plan = planVideoAppleChrome(
          layout: custom,
          form: form,
          renders: _all,
        );
        for (final VideoControlItem item in VideoControlItem.values) {
          if (item == VideoControlItem.back ||
              item == VideoControlItem.title ||
              item == VideoControlItem.positionIndicator) {
            continue;
          }
          final bool onPlayer = custom.isOnPlayer(item);
          if (!onPlayer) continue;
          expect(
            _reachable(plan, custom, item),
            isTrue,
            reason: '${item.name} 在用户布局里，方案 C 不能丢',
          );
        }
        // 用户挪过的顶部按钮按槽位进右上胶囊（含片段导出 / 音轨）。
        expect(
          _items(plan.topTrailing),
          containsAll(<VideoControlItem>[
            VideoControlItem.clipExport,
            VideoControlItem.audioTrack,
            VideoControlItem.subtitleTrack,
          ]),
        );
        // 底中的学习三键与逐帧进前导簇（传输组之后）。
        expect(
          _items(plan.bottomLeading),
          containsAllInOrder(<VideoControlItem>[
            VideoControlItem.favoriteSentence,
            VideoControlItem.previousCue,
            VideoControlItem.frameBackward,
            VideoControlItem.frameForward,
            VideoControlItem.nextCue,
            VideoControlItem.replayCue,
          ]),
        );
        expect(
          _items(plan.bottomTrailing),
          containsAll(<VideoControlItem>[
            VideoControlItem.volume,
            VideoControlItem.speed,
            VideoControlItem.subtitleList,
            VideoControlItem.customAction1,
            VideoControlItem.fullscreen,
          ]),
        );
        // 用户挪过的字幕列表不在侧栏，也就不排除。
        expect(plan.railsExclude, isEmpty);
      });
    }

    test('运行期门控照旧：不渲染的按钮不进任何区域', () {
      final VideoAppleChromePlan plan = planVideoAppleChrome(
        layout: VideoControlLayout.currentChrome,
        form: VideoAppleChromeForm.desktop,
        renders: (VideoControlItem item) =>
            item != VideoControlItem.episodeList &&
            item != VideoControlItem.chapterList &&
            item != VideoControlItem.liveChat,
      );
      expect(_items(plan.topTrailing), <VideoControlItem>[
        VideoControlItem.subtitleTrack,
        VideoControlItem.screenshot,
      ]);
    });
  });
}
