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
///
/// 引擎去 Flutter 化后分两半：后端抽象 / CLI 后端 / 选择器在引擎
/// `ffmpeg_backend.dart`（不能碰 ffmpeg_kit 插件），`KitFfmpegBackend` 与「移动端才装
/// 它」的平台分流在 app 侧（`ffmpeg_kit_backend.dart` + `engine_bindings.dart` 的
/// `ffmpegPlatformBackendProvider` 装配）。守卫按两半各钉各的。
void main() {
  final String src =
      File('../packages/fushi_engine/lib/media/video/ffmpeg_backend.dart').readAsStringSync();
  final String kit =
      File('lib/src/media/video/ffmpeg_kit_backend.dart').readAsStringSync();
  final String bindings =
      File('lib/src/engine_bindings.dart').readAsStringSync();

  test('不再依赖崩溃的预编译 ffmpeg_kit_flutter_new_min', () {
    expect(src.contains('ffmpeg_kit_flutter_new'), isFalse);
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec.contains('ffmpeg_kit_flutter_new'), isFalse);
  });

  test('用自编 ffmpeg-kit：KitFfmpegBackend + ffmpeg_kit_flutter API（app 侧）', () {
    expect(
        kit, contains('import \'package:ffmpeg_kit_flutter/ffmpeg_kit.dart\''));
    expect(kit, contains('class KitFfmpegBackend implements FfmpegBackend'));
    expect(kit, contains('FFmpegKit.executeWithArguments'));
    // 引擎不得反向碰插件（纯度守卫另钉，这里顺手钉住后端文件本身）。
    expect(src.contains('ffmpeg_kit_flutter'), isFalse,
        reason: '引擎 ffmpeg_backend.dart 不得 import ffmpeg_kit 插件');
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
    // 引擎选择器：显式覆盖 → CLI；否则问平台装配点；装配点没装 → CLI。
    final RegExpMatch? body = RegExp(
      r'FfmpegBackend _selectBackend\(\) \{(.*?)\n\}',
      dotAll: true,
    ).firstMatch(src);
    expect(body, isNotNull, reason: '应有 _selectBackend 平台分流');
    final String b = body!.group(1)!;
    expect(b.contains('ffmpegPlatformBackendProvider'), isTrue,
        reason: '引擎选择器必须问平台装配点，移动端的自编后端从那里进来');
    // app 装配：移动端分流到自编后端，桌面不装（退回 CLI）；且真的把它装进装配点。
    final RegExpMatch? platform = RegExp(
      r'FfmpegBackend _platformFfmpegBackend\(\) \{(.*?)\n\}',
      dotAll: true,
    ).firstMatch(bindings);
    expect(platform, isNotNull, reason: 'engine_bindings 应有 _platformFfmpegBackend');
    final String pb = platform!.group(1)!;
    expect(pb.contains('Platform.isAndroid || Platform.isIOS'), isTrue,
        reason: '移动端必须分流到自编后端');
    expect(pb.contains('KitFfmpegBackend()'), isTrue);
    expect(
        bindings.contains('ffmpegPlatformBackendProvider = _platformFfmpegBackend;'),
        isTrue,
        reason: '分流函数必须真的装进引擎的 ffmpegPlatformBackendProvider');
    // BUG-1664：显式 ffmpeg 覆盖必须仍能把移动端拽回 CLI 后端。断言改钉**单一入口**
    // `ffmpegEnvOverride()`（原先钉的是 `FUSHI_FFMPEG` 字面量，那个字面量现在只存在于
    // 该入口内部）——语义不变，且下面额外钉住这个入口本身认新旧两个名字，比原来更严。
    expect(b.contains('ffmpegExplicitOverride()'), isTrue,
        reason: '_selectBackend 必须经 ffmpegExplicitOverride()（宿主装配 > 环境变量）'
            '判显式覆盖：只问 ffmpegEnvOverride() 会让无头服务端配置文件里的 '
            'ffmpeg: 路径对后端选择失效');
    expect(b.contains('CliFfmpegBackend()'), isTrue);
  });

  // BUG-1664：改名批次把 5 个调用点都写成 `env['FUSHI_FFMPEG'] ?? env['FUSHI_FFMPEG']`
  // （两边同名），注释承诺的旧名回退从未生效。收敛成单一入口后，这里钉住「入口确实问了
  // 新旧两个名字」，并禁止任何调用点再绕开入口手写裸 `Platform.environment['*_FFMPEG']`
  // ——自反回退只能在手写处复发。
  test('ffmpeg/ffprobe 环境覆盖：单一入口 + 新名优先旧名回退', () {
    expect(src, contains("'FUSHI_FFMPEG', 'HIBIKI_FFMPEG'"));
    expect(src, contains("'FUSHI_FFPROBE', 'HIBIKI_FFPROBE'"));
    // 除两个入口内的常量列表外，全文件不得再出现裸 env 读取。
    expect(
      RegExp(r"Platform\.environment\['(FUSHI|HIBIKI)_FF").allMatches(src),
      isEmpty,
      reason: '环境覆盖只能经 ffmpegEnvOverride()/ffprobeEnvOverride()',
    );
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
