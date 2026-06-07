import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：ffmpeg 后端选择的平台路由——移动端必须走捆绑 [KitFfmpegBackend]
/// （ffmpeg_kit），否则移动端无系统 ffmpeg → 内封字幕/cue 动图/句子音频全部降级。
/// 实际执行只能真机验证（ffmpeg-kit 原生库），故在源码层钉死路由不被回退。
void main() {
  final String src =
      File('lib/src/media/video/ffmpeg_backend.dart').readAsStringSync();

  test('存在 KitFfmpegBackend 且经 ffmpeg_kit 执行', () {
    expect(src, contains('class KitFfmpegBackend implements FfmpegBackend'));
    expect(src, contains('FFmpegKit.executeWithArguments'));
    expect(src, contains('getReturnCode'));
    expect(src, contains('getOutput'));
  });

  test('Android/iOS 路由到 KitFfmpegBackend，桌面仍 CLI', () {
    final RegExpMatch? body = RegExp(
      r'FfmpegBackend _selectBackend\(\) \{(.*?)\n\}',
      dotAll: true,
    ).firstMatch(src);
    expect(body, isNotNull, reason: '应有 _selectBackend 平台分流');
    final String b = body!.group(1)!;
    expect(b.contains('Platform.isAndroid || Platform.isIOS'), isTrue,
        reason: '移动端必须分流到捆绑后端');
    expect(b.contains('KitFfmpegBackend()'), isTrue);
    // HIBIKI_FFMPEG 覆盖与桌面回退仍走 CLI。
    expect(b.contains('HIBIKI_FFMPEG'), isTrue);
    expect(b.contains('CliFfmpegBackend()'), isTrue);
  });
}
