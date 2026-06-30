import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码扫描守卫（BUG-465 / TODO-984）：Android「闪烁 + 空白无画面」现场诊断日志点
/// 必须长期保留，让用户复现后能上传 `[VIDEO-DIAG]` 日志据其分层定位根因（解码层 vs
/// 渲染层）。无法对 libmpv 真实播放做单测（测试宿主无 libmpv，`new Player()` 即抛），
/// 故守卫诊断仪表化不被后续重构静默删除——这是此现场诊断改动可落地的最强测试层。
void main() {
  final File controller = File(
    'lib/src/media/video/video_player_controller.dart',
  );
  final File page = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  );

  late final String controllerSrc;
  late final String pageSrc;

  setUpAll(() {
    expect(controller.existsSync(), isTrue,
        reason: 'controller 源文件应存在: ${controller.path}');
    expect(page.existsSync(), isTrue, reason: 'page 源文件应存在: ${page.path}');
    controllerSrc = controller.readAsStringSync();
    pageSrc = page.readAsStringSync();
  });

  group('VideoPlayerController TODO-984 诊断仪表', () {
    test('暴露 onDiagLog 回调 + 统一 [VIDEO-DIAG] 前缀', () {
      expect(controllerSrc,
          contains('void Function(String message)? onDiagLog'),
          reason: '上层（页面）须能接入诊断日志回调');
      expect(controllerSrc, contains('[VIDEO-DIAG]'),
          reason: '诊断行须带统一前缀，便于用户筛选/上传');
    });

    test('解码层信号：hwdec 回读 / video-codec / videoParams / 首帧出帧', () {
      expect(controllerSrc, contains("'hwdec'"));
      expect(controllerSrc, contains("'hwdec-current'"));
      expect(controllerSrc, contains("'video-codec'"));
      expect(controllerSrc, contains('videoParams'));
      expect(controllerSrc, contains('hwPixelformat'));
      expect(controllerSrc, contains('first frame decoded'));
      expect(controllerSrc, contains('_maybeLogFirstFrame'));
    });

    test('渲染层信号：纹理(texture)创建 + vo/gpu 后端回读', () {
      expect(controllerSrc, contains('textureId='),
          reason: '纹理 id = GL surface 创建信号（渲染层）');
      expect(controllerSrc, contains("'vo'"));
      expect(controllerSrc, contains("'gpu-context'"));
      expect(controllerSrc, contains("'gpu-api'"));
    });

    test('libmpv error/log 流订阅 + 诊断期提 verbose 日志级', () {
      expect(controllerSrc, contains('player.stream.error.listen'),
          reason: '订阅 libmpv error 流捕获致命错误字符串');
      expect(controllerSrc, contains('player.stream.log.listen'),
          reason: '订阅 libmpv log 流捕获解码/渲染告警');
      expect(controllerSrc, contains('msg-level'),
          reason: '诊断期把 vd/vo/ad/ffmpeg 提到 verbose 才能收到关键行');
    });

    test('诊断流订阅在 dispose 与换片(load 重入)时取消', () {
      expect(controllerSrc, contains('_diagErrorSub'));
      expect(controllerSrc, contains('_diagLogSub'));
      expect(controllerSrc, contains('_diagVideoParamsSub'));
      expect(controllerSrc, contains('_diagBufferingSub'));
    });
  });

  group('VideoHibikiPage TODO-984 诊断接线', () {
    test('把控制器诊断行接到 ErrorLogService（用户可查看/上传）', () {
      expect(pageSrc, contains('controller.onDiagLog'),
          reason: '页面须把 controller 诊断回调接到日志服务');
      expect(pageSrc,
          contains("ErrorLogService.instance.log('VideoHibiki.diag'"),
          reason: '诊断行落 ErrorLogService 的 VideoHibiki.diag 源');
    });

    test('load 失败 catch 落结构化日志（不只 debugPrint）', () {
      expect(pageSrc,
          contains("ErrorLogService.instance.log('VideoHibiki.load'"),
          reason: 'load 抛异常须落结构化错误日志，Android 上 debugPrint 收不到');
    });

    test('本地资源缺失短路也落诊断行', () {
      expect(pageSrc, contains('local video resource missing'));
    });
  });
}
