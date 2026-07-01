import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：ffmpeg 后端选择的平台路由。
///
/// BUG-124：第三方预编译 `ffmpeg_kit_flutter_new_min` 的 `libffmpegkit_abidetect.so`
/// 在 Android 16/API 36 上 `JNI_OnLoad` 返回非法版本，且在 `onAttachedToActivity`
/// 强制加载 → app 启动即崩（Dart 拦不住）。改用「自编」ffmpeg-kit（arthenica 源码 +
/// NDK r25 重编最小变体，vendored 于 third_party/ffmpeg_kit_flutter，android 用自编
/// AAR），经 [KitFfmpegBackend] 接入。这里钉死：①用 ffmpeg_kit_flutter（非崩溃的
/// _new_min）②移动端路由 KitFfmpegBackend ③桌面仍 CLI ④两后端共用 runFfmpegProcess
/// ⑤android build.gradle 用本地自编 AAR、不再拉 maven 预编译。实际原生执行需真机验证。
void main() {
  final String src =
      File('lib/src/media/video/ffmpeg_backend.dart').readAsStringSync();

  test('不再依赖崩溃的预编译 ffmpeg_kit_flutter_new_min', () {
    expect(src.contains('ffmpeg_kit_flutter_new'), isFalse);
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec.contains('ffmpeg_kit_flutter_new'), isFalse);
  });

  test('用自编 ffmpeg-kit：KitFfmpegBackend + ffmpeg_kit_flutter API', () {
    expect(
        src, contains('import \'package:ffmpeg_kit_flutter/ffmpeg_kit.dart\''));
    expect(src, contains('class KitFfmpegBackend implements FfmpegBackend'));
    expect(src, contains('FFmpegKit.executeWithArguments'));
  });

  test('顶层进程 runner 各自一处 drain/超时（ffmpeg + ffprobe）', () {
    // ffmpeg 工作输出写 stderr、ffprobe JSON 写 stdout，两者收集/drain 的流相反，
    // 故各有一个顶层 runner（runFfmpegProcess / runFfprobeProcess），各自一处
    // sigkill 超时逻辑（TODO-1045 新增 ffprobe 路径）。钉死两处、不允许再散落第三处。
    expect(src, contains('Future<FfmpegRunResult> runFfmpegProcess('));
    expect(src, contains('Future<FfmpegRunResult> runFfprobeProcess('));
    expect('ProcessSignal.sigkill'.allMatches(src).length, 2);
  });

  test('Android/iOS 路由到 KitFfmpegBackend，桌面仍 CLI', () {
    final RegExpMatch? body = RegExp(
      r'FfmpegBackend _selectBackend\(\) \{(.*?)\n\}',
      dotAll: true,
    ).firstMatch(src);
    expect(body, isNotNull, reason: '应有 _selectBackend 平台分流');
    final String b = body!.group(1)!;
    expect(b.contains('Platform.isAndroid || Platform.isIOS'), isTrue,
        reason: '移动端必须分流到自编后端');
    expect(b.contains('KitFfmpegBackend()'), isTrue);
    expect(b.contains('HIBIKI_FFMPEG'), isTrue);
    expect(b.contains('CliFfmpegBackend()'), isTrue);
  });

  test('vendored 包用本地自编 AAR（不拉 maven 预编译）', () {
    final File gradle =
        File('../third_party/ffmpeg_kit_flutter/android/build.gradle');
    expect(gradle.existsSync(), isTrue,
        reason: 'vendored ffmpeg_kit_flutter 应存在');
    final String g = gradle.readAsStringSync();
    expect(g.contains('implementation(name: \'ffmpeg-kit\', ext: \'aar\')'),
        isTrue);
    expect(g.contains('com.arthenica:ffmpeg-kit-https'), isFalse,
        reason: '不再拉 maven 预编译');
    expect(
      File('../third_party/ffmpeg_kit_flutter/android/libs/ffmpeg-kit.aar')
          .existsSync(),
      isTrue,
      reason: '自编 AAR 应 vendored',
    );
  });
}
