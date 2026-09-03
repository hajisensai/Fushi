// 内置网页播放器（内置档）的超分通道 Dart 侧（计划 P2）：把 mpv 视频页同一套 Anime4K 档位的
// `.glsl` 文本喂给 fork 的 libplacebo 通道（`custom_platform_view` 方法通道 `setShaders`）。
//
// 与 mpv 页的差异只在「怎么交给渲染器」：mpv 页给 libmpv 文件路径（`glsl-shaders`），这里把文件
// **内容**经 method channel 交给 fork（fork 进程内 `pl_mpv_user_shader_parse`），文件来源 / 下载 /
// 档位定义完全复用 `video_shader_tier.dart` + `video_shader_downloader.dart`。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/video_shader_downloader.dart';
import 'package:fushi/src/media/video/video_shader_manager.dart';
import 'package:fushi/src/media/video/video_shader_tier.dart';

/// fork `custom_platform_view.cc` 的每视图方法通道前缀（守卫测试比对字面量）。
const String kWebVideoPlatformViewChannelPrefix =
    'com.pichillilorenzo/custom_platform_view_';

/// fork 方法名（守卫测试比对 `kMethodSetShaders`）。
const String kWebVideoSetShadersMethod = 'setShaders';

/// 网页播放器超分档位偏好键（值 = [VideoShaderTier.name]；缺省 off）。与 mpv 页的两套状态
/// （内置缩放开关 + 启用集）无关：网页帧没有 mpv 缩放器可开，这里只有「GLSL 链」一个维度。
const String kWebVideoShaderTierPrefKey = 'web_video_shader_tier';

VideoShaderTier webVideoShaderTierFromPref(Object? raw) {
  for (final VideoShaderTier t in VideoShaderTier.values) {
    if (t.name == raw) return t;
  }
  return VideoShaderTier.off;
}

/// 该档要喂给 fork 的着色器文本（按叠加顺序）。文件不在本机则先经 [downloadAnime4kFiles]
/// 下载（与 mpv 页同目录、同镜像、同去重）；个别文件仍缺就跳过（链缩短但不空转）。
/// off / low（无 GLSL 档）回空表 = 直通。[loadText] / [download] 可注入便于单测。
Future<List<String>> loadWebVideoShaderTexts(
  VideoShaderTier tier, {
  Directory? shaderDir,
  Future<Anime4kDownloadResult> Function(Anime4kPreset preset, Directory dir)?
  download,
}) async {
  final VideoShaderTierSpec spec = shaderTierSpec(tier);
  final Anime4kPreset? preset = spec.preset;
  if (preset == null) return const <String>[];
  final Directory dir = shaderDir ?? await mpvShaderDirectory();
  final Set<String> present = listShaderFilesIn(dir).toSet();
  if (!present.containsAll(preset.fileNames)) {
    await (download ??
        (Anime4kPreset preset, Directory dir) =>
            downloadAnime4kFiles(preset, targetDir: dir))(preset, dir);
  }
  final List<String> ordered = orderedEnabledForTier(
    tier,
    listShaderFilesIn(dir).toSet(),
  );
  final List<String> texts = <String>[];
  for (final String name in ordered) {
    texts.add(await File(p.join(dir.path, name)).readAsString());
  }
  return texts;
}

/// 把着色器文本交给 fork 的 libplacebo 通道。[viewId] 是 InAppWebView 的平台视图 id
/// （`controller.platform.id`，Windows fork 下即 texture id）。fork 未构建 / 窗口宿主档 / DLL 缺失都回
/// false（fail-open：页面照常显示原帧）。[invoke] 可注入便于单测。
Future<bool> applyWebVideoShaders(
  Object? viewId,
  List<String> shaderTexts, {
  Future<Object?> Function(String channel, String method, Object? args)? invoke,
}) async {
  if (viewId == null) return false;
  final String channel = '$kWebVideoPlatformViewChannelPrefix$viewId';
  try {
    final Object? r =
        await (invoke ??
            (String channel, String method, Object? args) =>
                MethodChannel(channel).invokeMethod<Object?>(method, args))(
          channel,
          kWebVideoSetShadersMethod,
          shaderTexts,
        );
    return r == true;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}
