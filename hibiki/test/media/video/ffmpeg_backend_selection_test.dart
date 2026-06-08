import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：ffmpeg 后端选择的平台路由。
///
/// BUG-NNN：第三方 `ffmpeg_kit_flutter_new_min` 的 `libffmpegkit_abidetect.so` 在
/// Android 16/API 36 上 `JNI_OnLoad` 返回非法版本，且在 `onAttachedToActivity` 强制
/// 加载 → app 启动即崩（Dart 拦不住）。改走自编 libffmpeg + FFI（[FfiFfmpegBackend]）。
/// 这里钉死：①不再依赖 ffmpeg_kit ②移动端路由到 FfiFfmpegBackend ③桌面仍 CLI
/// ④两后端共用 runFfmpegProcess（不重复 drain/超时逻辑）。
/// 实际执行需真机验证（原生 libffmpeg），故源码层守卫路由不被回退。
void main() {
  final String src =
      File('lib/src/media/video/ffmpeg_backend.dart').readAsStringSync();

  test('不再依赖崩溃的 ffmpeg_kit', () {
    expect(src.contains('ffmpeg_kit_flutter'), isFalse);
    expect(src.contains('FFmpegKit'), isFalse);
    expect(src.contains('KitFfmpegBackend'), isFalse);
  });

  test('存在 FfiFfmpegBackend（移动端进程内自编 ffmpeg）', () {
    expect(src, contains('class FfiFfmpegBackend implements FfmpegBackend'));
  });

  test('两后端共用顶层 runFfmpegProcess（drain/超时只此一处）', () {
    expect(src, contains('Future<FfmpegRunResult> runFfmpegProcess('));
    // SIGKILL 的真实调用（非注释）只应出现在共享函数里一次。
    expect('ProcessSignal.sigkill'.allMatches(src).length, 1);
  });

  test('Android/iOS 路由到 FfiFfmpegBackend，桌面仍 CLI', () {
    final RegExpMatch? body = RegExp(
      r'FfmpegBackend _selectBackend\(\) \{(.*?)\n\}',
      dotAll: true,
    ).firstMatch(src);
    expect(body, isNotNull, reason: '应有 _selectBackend 平台分流');
    final String b = body!.group(1)!;
    expect(b.contains('Platform.isAndroid || Platform.isIOS'), isTrue,
        reason: '移动端必须分流到自编后端');
    expect(b.contains('FfiFfmpegBackend()'), isTrue);
    // HIBIKI_FFMPEG 覆盖与桌面回退仍走 CLI。
    expect(b.contains('HIBIKI_FFMPEG'), isTrue);
    expect(b.contains('CliFfmpegBackend()'), isTrue);
  });

  test('pubspec 不再含 ffmpeg_kit 依赖', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec.contains('ffmpeg_kit_flutter'), isFalse);
  });
}
