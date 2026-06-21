import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

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

  test('video aspect-ratio lock preference defaults off (regression)', () {
    final String appModel =
        File('lib/src/models/app_model.dart').readAsStringSync();
    final String prefs =
        File('lib/src/models/preferences_repository.dart').readAsStringSync();

    expect(appModel, contains('bool get videoLockWindowAspectRatio'));
    expect(appModel, contains('setVideoLockWindowAspectRatio'));
    expect(prefs, contains("'video_lock_window_aspect_ratio'"));
    // 回归：默认不主动锁窗口比例，用户没要求时别把 app 窗口贴成视频尺寸。
    expect(
      prefs,
      contains(
        "getPref('video_lock_window_aspect_ratio', defaultValue: false)",
      ),
    );
  });

  // TODO-122 -> TODO-152 子B：窗口模式无 letterbox/pillarbox 黑边的诉求升级为可配的
  // 画面缩放/比例偏好（VideoFitMode）。旧实现硬编码窗口 BoxFit.cover、全屏 params.fit；
  // 子B 把窗口 + 全屏两处统一改成 fit: videoFitModeToBoxFit(_videoFitMode)，TODO-257
  // 将新安装默认改为 contain（适应），同时保留用户已有 cover（裁切）/ fill（拉伸）偏好。
  test('TODO-122/152/257 窗口+全屏 Video 经 videoFitModeToBoxFit 跟随偏好（默认 contain）',
      () {
    // TODO-590 batch15：全屏路由侧 Video（含 fit: videoFitModeToBoxFit(_videoFitMode)）
    // 随 fullscreen 域搬到 fullscreen.part.dart，故改读合并语料；窗口侧 _buildVideoBody
    // 仍在主壳（语料最前段），其内的窗口侧 fit 锚点不受影响。
    final String source = readVideoHibikiSource();

    // 窗口模式本体 Video 经偏好换算 fit——锚到 _buildVideoBody 方法之后。
    final int bodyIdx = source.indexOf('Widget _buildVideoBody(');
    expect(bodyIdx, greaterThanOrEqualTo(0));
    final int fitIdx =
        source.indexOf('fit: videoFitModeToBoxFit(_videoFitMode)', bodyIdx);
    final int controlsIdx =
        source.indexOf('controls: (VideoState state)', bodyIdx);
    expect(fitIdx, greaterThanOrEqualTo(0),
        reason: '窗口模式 _buildVideoBody 的 Video 必须经 videoFitModeToBoxFit 跟随偏好');
    expect(fitIdx, lessThan(controlsIdx),
        reason:
            'videoFitModeToBoxFit(_videoFitMode) 必须在 _buildVideoBody 的 Video 参数内');

    // 窗口 + 全屏两处都经同一偏好换算（不再窗口硬编码 cover、全屏 params.fit）。
    expect(
      'fit: videoFitModeToBoxFit(_videoFitMode)'.allMatches(source).length,
      greaterThanOrEqualTo(2),
      reason: '窗口与全屏 Video 必须共用 _videoFitMode 偏好换算 fit',
    );
    // 旧硬编码窗口 cover 已移除（升级为偏好驱动，默认由 PreferencesRepository 给 contain）。
    expect(
      source.contains('fit: BoxFit.cover'),
      isFalse,
      reason: '窗口模式 fit 不得再硬编码 BoxFit.cover（已改偏好驱动，默认 contain）',
    );
  });
}
