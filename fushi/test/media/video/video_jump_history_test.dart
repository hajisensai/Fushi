import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_jump_history.dart';
import 'package:fushi/src/utils/components/fushi_jump_history_controls.dart';
import 'package:fushi/src/utils/misc/jump_history.dart';

void main() {
  group('isVideoPositionJump', () {
    test('跨度达到阈值才算跳转（两个方向）', () {
      expect(isVideoPositionJump(fromMs: 60000, toMs: 75000), isTrue);
      expect(isVideoPositionJump(fromMs: 75000, toMs: 60000), isTrue);
      expect(isVideoPositionJump(fromMs: 60000, toMs: 74999), isFalse);
    });

    test('±10 秒步进与逐句不算', () {
      expect(isVideoPositionJump(fromMs: 60000, toMs: 70000), isFalse);
      expect(isVideoPositionJump(fromMs: 60000, toMs: 57000), isFalse);
    });

    test('出发点未知不算', () {
      expect(isVideoPositionJump(fromMs: null, toMs: 600000), isFalse);
    });
  });

  test('同一处判据：1 秒内视为同一位置', () {
    final JumpHistory<int> history = createVideoJumpHistory();
    expect(history.recordDeparture(60000), isTrue);
    expect(history.recordDeparture(60900), isFalse);
    expect(history.backEntries, hasLength(1));
    expect(history.recordDeparture(62000), isTrue);
    expect(history.backEntries, hasLength(2));
  });

  group('VideoSeekBarJumpTracker', () {
    test('进度条按下后的大跨度落点返回出发点，且只消费一次', () {
      final VideoSeekBarJumpTracker tracker = VideoSeekBarJumpTracker();
      tracker.begin(60000, relativeBaseCaptureCount: 3);
      expect(tracker.commit(600000, relativeBaseCaptureCount: 3), 60000);
      expect(tracker.originMs, isNull);
      expect(tracker.commit(900000, relativeBaseCaptureCount: 3), isNull);
    });

    test('没按过进度条的落点（横滑 / 双击）不算', () {
      final VideoSeekBarJumpTracker tracker = VideoSeekBarJumpTracker();
      expect(tracker.commit(600000, relativeBaseCaptureCount: 0), isNull);
    });

    test('按下后中间插进了相对步进（取过相对基准）不算', () {
      final VideoSeekBarJumpTracker tracker = VideoSeekBarJumpTracker();
      tracker.begin(60000, relativeBaseCaptureCount: 3);
      expect(tracker.commit(600000, relativeBaseCaptureCount: 4), isNull);
    });

    test('进度条上的小幅拖动不算', () {
      final VideoSeekBarJumpTracker tracker = VideoSeekBarJumpTracker();
      tracker.begin(60000, relativeBaseCaptureCount: 0);
      expect(tracker.commit(65000, relativeBaseCaptureCount: 0), isNull);
    });

    test('cancel 作废出发点', () {
      final VideoSeekBarJumpTracker tracker = VideoSeekBarJumpTracker();
      tracker.begin(60000, relativeBaseCaptureCount: 0);
      tracker.cancel();
      expect(tracker.commit(600000, relativeBaseCaptureCount: 0), isNull);
    });
  });

  test('formatJumpHistoryTime：满一小时 h:mm:ss，否则 m:ss，负数按 0', () {
    expect(formatJumpHistoryTime(0), '0:00');
    expect(formatJumpHistoryTime(-5), '0:00');
    expect(formatJumpHistoryTime(754000), '12:34');
    expect(formatJumpHistoryTime(3723000), '1:02:03');
  });

  test('timelineJumpMarkFraction：时长未知不画，否则按时长换算', () {
    expect(timelineJumpMarkFraction(60000, null), isNull);
    expect(timelineJumpMarkFraction(60000, 0), isNull);
    expect(timelineJumpMarkFraction(60000, 240000), 0.25);
  });

  test('刻度落点：返回点 / 前进点分开，按时长换算', () {
    final JumpHistory<int> history = createVideoJumpHistory();
    history.recordDeparture(60000, source: JumpSource.progressBar);
    history.recordDeparture(120000, source: JumpSource.cue);
    expect(history.goBack(180000), 120000);
    final ({List<double> back, List<double> forward}) marks =
        jumpHistoryMarkFractions<int>(
          history,
          (int ms) => timelineJumpMarkFraction(ms, 240000),
        );
    expect(marks.back, <double>[0.25]);
    expect(marks.forward, <double>[0.75]);
    expect(history.backEntries.single.source, JumpSource.progressBar);
  });

  group('视频页接线（2026-11-02 胶囊改顶栏图标）', () {
    const String dir = 'lib/src/pages/implementations';
    String read(String path) => File(path).readAsStringSync();

    test('不再挂浮动胶囊、不再闪现 / 悬停冻结', () {
      final String page = read('$dir/video_fushi_page.dart');
      final String part = read('$dir/video_fushi/jump_history.part.dart');
      final String layout = read('$dir/video_fushi/layout.part.dart');
      for (final String src in <String>[page, part, layout]) {
        expect(src, isNot(contains('FushiJumpHistoryPill')));
        expect(src, isNot(contains('fushi_jump_history_pill.dart')));
        expect(src, isNot(contains('video_jump_pill_hover.dart')));
        expect(src, isNot(contains('videoJumpPillAutoHideSeconds')));
        expect(src, isNot(contains('_videoJumpFlash')));
      }
    });

    test('顶栏按钮 / 「⋯」入口 / 刻度 / 面板都接上了', () {
      final String page = read('$dir/video_fushi_page.dart');
      final String part = read('$dir/video_fushi/jump_history.part.dart');
      final String theme = read('$dir/video_fushi/controls_theme.part.dart');
      final String mini = read('$dir/video_fushi/mini_window.part.dart');
      expect(page, contains('_videoJumpHistoryTopBarGroup('));
      expect(page, contains('_videoJumpHistoryMenuEntry(jumpContext)'));
      expect(part, contains('jumpHistoryToolbarItems('));
      expect(part, contains('jumpHistoryPanelMenuItem('));
      expect(part, contains('showJumpHistoryPanel<int>('));
      // 三项设置经只在它们变化时通知的选择器接进重建源（设置一改立刻生效）。
      expect(
        page,
        contains(
          'JumpHistoryPrefsListenable.fromRepository(appModel.prefsRepo)',
        ),
      );
      expect(page, contains('prefs: _videoJumpPrefs'));
      expect(part, contains('_videoJumpPrefs.value.toolbar'));
      expect(part, contains('_videoJumpPrefs.value.progressMarks'));
      final int merge = part.indexOf('_videoJumpToolbarListenable =>');
      expect(
        part.substring(merge, part.indexOf(']);', merge)),
        contains('_videoJumpPrefs'),
      );
      expect(theme, contains('_videoJumpProgressMarks('));
      expect(mini, contains('_videoJumpProgressMarks('));
    });

    // #ekVmlGuze5：返回 / 前进组自己是一枚浮动胶囊，按钮再上 tonal（M3E 开关「开」态，
    // 方圆角色块）就在圆胶囊里叠出第二颗按钮。按钮必须是中性档。
    test('返回 / 前进按钮是中性档，不在胶囊里再叠 tonal 色块', () {
      final String part = read('$dir/video_fushi/jump_history.part.dart');
      final int start = part.indexOf('Widget _videoJumpHistoryTopBarGroup(');
      expect(start, greaterThanOrEqualTo(0));
      final int end = part.indexOf('\n  }\n', start);
      final String group = part.substring(start, end);
      expect(group, contains('_chromeIconButton('));
      expect(group, contains('clusterStyle: _m3eFloatingBarStyle('));
      expect(group, isNot(contains('VideoM3eButtonTone.secondary')));
      expect(group, isNot(contains('VideoM3eButtonTone.tertiary')));
      expect(group, isNot(contains('tonal: true')));
      expect(group, isNot(contains('selected: true')));
    });
  });
}
