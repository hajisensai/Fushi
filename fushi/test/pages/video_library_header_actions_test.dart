import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/video_library_header_actions.dart';

/// 设计稿 #video V2：页头「后台任务」只在有任务时出现，带进度与数量。
void main() {
  test('没有任务：按钮不出现', () {
    final VideoBackgroundTasksSummary s = videoBackgroundTasksSummary(
      busy: false,
      queuedManualRequests: 0,
      needsConfirmation: false,
      current: 0,
      total: 0,
    );
    expect(s.visible, isFalse);
    expect(s.running, 0);
    expect(s.progress, isNull);
  });

  test('正在跑 + 排队：数量相加，进度取当前任务的确定比例', () {
    final VideoBackgroundTasksSummary s = videoBackgroundTasksSummary(
      busy: true,
      queuedManualRequests: 1,
      needsConfirmation: false,
      current: 3,
      total: 12,
    );
    expect(s.visible, isTrue);
    expect(s.running, 2);
    expect(s.progress, closeTo(0.25, 1e-9));
    expect(
      videoBackgroundTasksTooltip(s),
      t.video_background_tasks_running(n: 2),
    );
  });

  test('还没有总数：进度不定态', () {
    final VideoBackgroundTasksSummary s = videoBackgroundTasksSummary(
      busy: true,
      queuedManualRequests: 0,
      needsConfirmation: false,
      current: 0,
      total: 0,
    );
    expect(s.visible, isTrue);
    expect(s.progress, isNull);
  });

  test('只剩待确认：按钮仍出现，tooltip 回到「后台任务」', () {
    final VideoBackgroundTasksSummary s = videoBackgroundTasksSummary(
      busy: false,
      queuedManualRequests: 0,
      needsConfirmation: true,
      current: 5,
      total: 5,
    );
    expect(s.visible, isTrue);
    expect(s.running, 0);
    expect(s.progress, isNull);
    expect(videoBackgroundTasksTooltip(s), t.video_source_scrape_tasks_open);
  });
}
