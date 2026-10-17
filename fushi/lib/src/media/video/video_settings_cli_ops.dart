/// 播放页里「着色器视图」与「拖动调字幕位置」的控制通道入口。
///
/// 两者在 app 里都是播放页上的交互（选档按钮 + 下载进度框、mpv 目录选择器 +
/// 多选导入框、在画面上拖字幕），控制通道把交互收集的值改成参数，落到同一组
/// 函数上：
/// - 一键选档：[resolveShaderTierEnabledNames]（与着色器视图共用）→ 播放中走页面
///   `onSelectShaderTier`（原子写「内置缩放 + 启用集」并即时应用），否则写同两项偏好；
/// - 发现本机 mpv 着色器：[discoverLocalMpvShaders] + [importShaderFile]；
/// - mpv 着色器目录：`AppModel.videoMpvShaderDir`（页面回调也只写这一项）；
/// - 字幕位置：[commitVideoSubtitleStyle]（播放中 = 页面 `onSubtitleStyleCommit`，
///   即拖动松手时的 `_persistSubtitleStyle`，同一处落盘、即时生效）。
///
/// 「播放中」由 [withActiveVideoHost] 判断：控制通道的设置上下文里没有播放页，
/// 这里从 [videoPlaybackRemotes] 借最上层播放页的快捷设置宿主。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/video_mpv_config.dart';
import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi/src/media/video/video_quick_settings_host.dart';
import 'package:fushi/src/media/video/video_settings_actions.dart';
import 'package:fushi/src/media/video/video_shader_downloader.dart';
import 'package:fushi/src/media/video/video_shader_manager.dart';
import 'package:fushi/src/media/video/video_shader_tier.dart';
import 'package:fushi/src/media/video/video_subtitle_style.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/video_settings_host.dart';

/// 有播放页在前台时，把它的快捷设置宿主挂进 [c]（同快捷设置面板）；否则原样返回。
SettingsContext withActiveVideoHost(SettingsContext c) {
  if (videoQuickSettingsHostOf(c) != null) return c;
  final VideoPlaybackRemote? remote = videoPlaybackRemotes.current.value;
  if (remote is! VideoQuickSettingsHostProvider) return c;
  final Object? host = (remote as VideoQuickSettingsHostProvider)
      .quickSettingsHost();
  if (host is! VideoSettingsHost) return c;
  return SettingsContext(
    context: c.context,
    appModel: c.appModel,
    ref: c.ref,
    readerSource: c.readerSource,
    refresh: c.refresh,
    video: host,
  );
}

// ── 着色器档位 ───────────────────────────────────────────────────────────────

/// 当前命中的档位名（按偏好里的「内置缩放开关 + 启用集」反查，同着色器视图的档位
/// 高亮）；不命中任何档 = `custom`（手工勾选）。
String videoShaderTierNameFromPrefs(SettingsContext c) {
  final VideoShaderTier? tier = tierFromState(
    highQuality: currentVideoMpvConfig(c).highQuality,
    enabledShaders: decodeEnabledShaders(c.appModel.videoShadersEnabled),
  );
  return tier?.name ?? 'custom';
}

VideoShaderTier _parseTier(String raw) {
  for (final VideoShaderTier tier in VideoShaderTier.values) {
    if (tier.name == raw.trim()) return tier;
  }
  throw ArgumentError(
    '档位取 ${VideoShaderTier.values.map((VideoShaderTier t) => t.name).join(' / ')}',
  );
}

/// 下载档位预设缺的着色器（同着色器视图的下载进度框，只是没有框）。
Future<bool> _downloadPresetForCli(Anime4kPreset preset) async {
  final Anime4kDownloadResult result;
  try {
    result = await downloadAnime4kFiles(preset);
  } on Exception catch (e) {
    throw StateError('下载 ${preset.name} 着色器失败：$e');
  }
  if (!result.allOk) {
    // 同对话框：没下全就不切档（不留半启用）。
    throw StateError(
      '下载 ${preset.name} 着色器没有全部成功（失败：${result.failed.join(', ')}），未切换档位',
    );
  }
  return true;
}

/// 一键选档（同着色器视图的档位按钮）：缺文件先下载，再原子写「内置缩放开关 +
/// 启用集」；播放中即时应用到当前播放器。
/// [listFiles] / [ensurePreset] 是测试缝（生产 = 着色器目录 + Anime4K 下载）。
Future<Map<String, Object?>> selectVideoShaderTierForCli(
  SettingsContext c,
  String raw, {
  Future<List<String>> Function()? listFiles,
  Future<bool> Function(Anime4kPreset preset)? ensurePreset,
}) async {
  final VideoShaderTier tier = _parseTier(raw);
  final List<String>? resolved = await resolveShaderTierEnabledNames(
    tier,
    listFiles: listFiles ?? listShaderFiles,
    ensurePreset: ensurePreset ?? _downloadPresetForCli,
  );
  if (resolved == null) {
    throw StateError('${tier.name} 档需要的着色器没有准备好，未切换档位');
  }
  final List<String> enabled = resolved;
  final bool highQuality = shaderTierSpec(tier).highQuality;
  final SettingsContext live = withActiveVideoHost(c);
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(live);
  if (host != null) {
    await host.onSelectShaderTier(tier, highQuality, enabled);
  } else {
    await live.appModel.setVideoMpvConfig(
      VideoMpvConfig.encode(
        currentVideoMpvConfig(live).copyWith(highQuality: highQuality),
      ),
    );
    await live.appModel.setVideoShadersEnabled(encodeEnabledShaders(enabled));
  }
  return <String, Object?>{
    'tier': tier.name,
    'highQuality': highQuality,
    'enabled': enabled,
    'appliedToPlayer': host != null,
  };
}

// ── 本机 mpv 着色器 ──────────────────────────────────────────────────────────

/// mpv 着色器目录写法校验：空串 = 清掉（回到自动候选目录），否则必须是存在的目录。
Future<void> setVideoMpvShaderDirForCli(SettingsContext c, String raw) async {
  final String dir = raw.trim();
  if (dir.isNotEmpty) {
    if (!p.isAbsolute(dir)) throw ArgumentError('mpv 目录必须是绝对路径');
    if (!Directory(dir).existsSync()) throw ArgumentError('目录不存在：$dir');
  }
  final SettingsContext live = withActiveVideoHost(c);
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(live);
  final Future<void> Function(String dir)? viaPage =
      host?.onMpvShaderDirChanged;
  if (viaPage != null) {
    await viaPage(dir);
  } else {
    await live.appModel.setVideoMpvShaderDir(dir);
  }
}

/// 「从本机 mpv 导入」：扫描（[dir] 给了就先记成 mpv 目录，同手动指定目录）→
/// 列出发现的着色器；[import] = `all` 或逗号分隔的文件名时把它们导入着色器目录
/// （同多选导入框；导入只拷文件，不改启用集）。
Future<Map<String, Object?>> discoverVideoMpvShadersForCli(
  SettingsContext c, {
  String? dir,
  String? import,
}) async {
  if (dir != null) await setVideoMpvShaderDirForCli(c, dir);
  final String overrideDir = c.appModel.videoMpvShaderDir;
  final List<String> found = await discoverLocalMpvShaders(
    overrideDir: overrideDir,
  );
  final Set<String> installed = (await listShaderFiles()).toSet();
  final List<String> imported = <String>[];
  if (import != null && import.trim().isNotEmpty) {
    final List<String> targets;
    if (import.trim() == 'all') {
      targets = found;
    } else {
      targets = <String>[];
      for (final String raw in import.split(',')) {
        final String name = raw.trim();
        if (name.isEmpty) continue;
        final String? match = found
            .where((String path) => p.basename(path) == name)
            .firstOrNull;
        if (match == null) {
          throw ArgumentError('没发现名为「$name」的着色器（先不带 import 跑一次看列表）');
        }
        targets.add(match);
      }
    }
    for (final String path in targets) {
      imported.add(await importShaderFile(path));
    }
  }
  return <String, Object?>{
    'mpvDir': overrideDir,
    'found': <Map<String, Object?>>[
      for (final String path in found)
        <String, Object?>{
          'name': p.basename(path),
          'path': path,
          'installed':
              installed.contains(p.basename(path)) ||
              imported.contains(p.basename(path)),
        },
    ],
    if (imported.isNotEmpty) 'imported': imported,
  };
}

// ── 字幕位置（拖动调整） ─────────────────────────────────────────────────────

SubtitleLayerVAnchor _parseAnchor(String raw, String name) =>
    switch (raw.trim()) {
      'bottom' => SubtitleLayerVAnchor.bottom,
      'top' => SubtitleLayerVAnchor.top,
      _ => throw ArgumentError('$name 取 bottom / top'),
    };

double _parsePadding(String raw, String name) {
  final double? value = double.tryParse(raw.trim());
  if (value == null || value < 0 || value > kVideoSubtitleMaxPadding) {
    throw ArgumentError(
      '$name 取 0…${kVideoSubtitleMaxPadding.toInt()}（离锚定边的距离，逻辑像素）',
    );
  }
  return value;
}

Map<String, Object?> _subtitlePositionJson(VideoSubtitleStyle style) =>
    <String, Object?>{
      'anchor': style.mainAnchor.name,
      'position': style.bottomPadding,
      // null = 跟随主字幕 / 自动对侧（与设置页、拖动同一语义）。
      'secondaryAnchor': style.secondaryAnchor?.name,
      'secondaryPosition': style.secondaryBottomPadding,
    };

/// 字幕位置（拖动松手写入的那几项）：不给参数 = 只读当前值；给了就按拖动松手同一
/// 条路径落盘（播放中即时生效）。`position` 在顶锚时是离顶距离。
Future<Map<String, Object?>> videoSubtitlePositionForCli(
  SettingsContext c,
  Map<String, String> args,
) async {
  final SettingsContext live = withActiveVideoHost(c);
  final SubtitleLayerVAnchor? anchor = args['anchor'] == null
      ? null
      : _parseAnchor(args['anchor']!, 'anchor');
  final double? position = args['position'] == null
      ? null
      : _parsePadding(args['position']!, 'position');
  final SubtitleLayerVAnchor? secondaryAnchor = args['secondary_anchor'] == null
      ? null
      : _parseAnchor(args['secondary_anchor']!, 'secondary_anchor');
  final double? secondaryPosition = args['secondary_position'] == null
      ? null
      : _parsePadding(args['secondary_position']!, 'secondary_position');
  final bool write =
      anchor != null ||
      position != null ||
      secondaryAnchor != null ||
      secondaryPosition != null;
  if (write) {
    await commitVideoSubtitleStyle(
      live,
      (VideoSubtitleStyle s) => s.copyWith(
        mainAnchor: anchor,
        bottomPadding: position,
        secondaryAnchor: secondaryAnchor,
        secondaryBottomPadding: secondaryPosition,
      ),
    );
  }
  return <String, Object?>{
    ..._subtitlePositionJson(currentVideoSubtitleStyle(live)),
    'appliedToPlayer': write && videoQuickSettingsHostOf(live) != null,
  };
}
