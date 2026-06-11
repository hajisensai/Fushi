import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('video page locks desktop window aspect ratio from decoded video size',
      () {
    final String source =
        File('lib/src/pages/implementations/video_hibiki_page.dart')
            .readAsStringSync();

    expect(
      source,
      contains("import 'package:window_manager/window_manager.dart';"),
    );
    expect(
      source,
      contains('_lockWindowAspectRatio = appModel.videoLockWindowAspectRatio'),
    );
    expect(source, contains('_syncWindowAspectRatioLock'));
    expect(source, contains('windowManager.setAspectRatio(aspectRatio)'));
    expect(source, contains('windowManager.setAspectRatio(0)'));
    expect(source, contains('isDesktopPlatform'));
    expect(source, contains('controller.videoWidth'));
    expect(source, contains('controller.videoHeight'));
  });

  test('video aspect-ratio lock preference defaults on', () {
    final String appModel =
        File('lib/src/models/app_model.dart').readAsStringSync();
    final String prefs =
        File('lib/src/models/preferences_repository.dart').readAsStringSync();

    expect(appModel, contains('bool get videoLockWindowAspectRatio'));
    expect(appModel, contains('setVideoLockWindowAspectRatio'));
    expect(prefs, contains("'video_lock_window_aspect_ratio'"));
    expect(prefs, contains('defaultValue: true'));
  });

  // TODO-122：窗口模式（非全屏 / 非最大化）视频占满媒体框、无 letterbox/pillarbox 黑边。
  // 根因：media_kit 默认 BoxFit.contain 在「媒体框宽高比 ≠ 视频宽高比」时两侧补黑；窗口
  // 比例锁（window_manager setAspectRatio）只在用户拖动窗口边框时约束、不矫正当前窗口
  // 尺寸（平台限制），故当前窗口比例不匹配时仍黑边。修法=窗口模式 Video 用 BoxFit.cover
  // 铺满裁切。媒体框/全屏路由的 Video 不在此处硬编码 cover（仍走 notifier 的 fit）。
  test('TODO-122 窗口模式 Video 用 BoxFit.cover 占满（无左右黑边）', () {
    final String source =
        File('lib/src/pages/implementations/video_hibiki_page.dart')
            .readAsStringSync();

    // 窗口模式本体 Video 显式 fit: BoxFit.cover。
    expect(
      source.contains('fit: BoxFit.cover'),
      isTrue,
      reason: '窗口模式 Video 必须用 BoxFit.cover 占满媒体框（消除左右黑边）',
    );
    // _buildVideoBody（窗口模式本体）里的 Video 块包含 BoxFit.cover——锚到该方法之后。
    final int bodyIdx = source.indexOf('Widget _buildVideoBody(');
    expect(bodyIdx, greaterThanOrEqualTo(0));
    final int coverIdx = source.indexOf('fit: BoxFit.cover', bodyIdx);
    final int controlsIdx =
        source.indexOf('controls: (VideoState state)', bodyIdx);
    expect(coverIdx, greaterThanOrEqualTo(0),
        reason: '窗口模式 _buildVideoBody 的 Video 必须设 fit: BoxFit.cover');
    expect(coverIdx, lessThan(controlsIdx),
        reason: 'BoxFit.cover 必须在 _buildVideoBody 的 Video 参数内');

    // 全屏路由的 Video 不被硬编码 cover——仍走 videoViewParameters 的 fit（默认 contain），
    // 不破坏全屏（全屏黑边是另一回事，由 notifier 决定）。
    expect(
      source.contains('fit: params.fit'),
      isTrue,
      reason: '全屏路由 Video 必须沿用 notifier 的 fit，不被 TODO-122 硬编码 cover 改动',
    );
    // BoxFit.cover 只出现一次（仅窗口模式本体），没有蔓延到全屏路由。
    expect(
      'fit: BoxFit.cover'.allMatches(source).length,
      1,
      reason: 'BoxFit.cover 只应用于窗口模式本体一处，不得蔓延到全屏路由',
    );
  });
}
