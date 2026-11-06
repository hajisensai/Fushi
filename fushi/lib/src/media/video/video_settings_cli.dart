/// 视频设置自绘行在控制通道（`fushi_cli config get/set/items`）上的读写入口。
///
/// 全部复用 `video_settings_actions.dart` 里设置页同一组读改写函数（host 在场走
/// 播放页回调即时生效，不在场落偏好、下次播放生效），这里只做「文本 ↔ 值」与
/// 校验。这些行在全局设置页按 host 门控隐藏，但值都是全局偏好，所以声明
/// `offPageWritable`：播放页外经 CLI 写入同样有效。
library;

import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart' show Color;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/media/video/video_custom_action_bindings.dart';
import 'package:fushi/src/media/video/video_immersive_control_layout.dart';
import 'package:fushi/src/media/video/video_mpv_config.dart';
import 'package:fushi/src/media/video/video_quick_settings_host.dart';
import 'package:fushi/src/media/video/video_settings_actions.dart';
import 'package:fushi/src/media/video/video_shader_manager.dart';
import 'package:fushi/src/media/video/video_subtitle_style.dart';
import 'package:fushi/src/settings/settings_cli_values.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';

/// 字幕颜色行：`#AARRGGBB` 读写，写入走取色行同一个 apply 函数（阴影保 alpha、
/// 描边 / 背景把 0 粗细 / 透明度顶到可见基线）。
SettingsCliValue videoSubtitleColorCli({
  required Color Function(VideoSubtitleStyle style) read,
  required VideoSubtitleStyle Function(VideoSubtitleStyle style, Color color)
  apply,
}) => SettingsCliValue(
  help: '#RRGGBB 或 #AARRGGBB',
  offPageWritable: true,
  read: (SettingsContext c) =>
      formatSettingsCliColor(read(currentVideoSubtitleStyle(c)).toARGB32()),
  write: (SettingsContext c, String raw) {
    final Color color = Color(parseSettingsCliColor(raw));
    return commitVideoSubtitleStyle(
      c,
      (VideoSubtitleStyle s) => apply(s, color),
    );
  },
);

final SettingsCliValue videoSubtitleTextColorCli = videoSubtitleColorCli(
  read: (VideoSubtitleStyle s) => s.textColor ?? const Color(0xFFFFFFFF),
  apply: applyVideoSubtitleTextColor,
);

final SettingsCliValue videoSubtitleShadowColorCli = videoSubtitleColorCli(
  read: (VideoSubtitleStyle s) =>
      s.shadowColor ?? VideoSubtitleStyle.defaults.shadowColor!,
  apply: applyVideoSubtitleShadowColor,
);

final SettingsCliValue videoSubtitleOutlineColorCli = videoSubtitleColorCli(
  read: (VideoSubtitleStyle s) => s.resolveOutlineColor(),
  apply: applyVideoSubtitleOutlineColor,
);

final SettingsCliValue videoSubtitleBackgroundColorCli = videoSubtitleColorCli(
  read: (VideoSubtitleStyle s) =>
      s.backgroundColor ?? kDefaultSubtitleBackgroundColor,
  apply: applyVideoSubtitleBackgroundColor,
);

/// 原始 mpv.conf 文本（`VideoMpvConfig.rawConf`）。
final SettingsCliValue videoMpvRawConfCli = SettingsCliValue(
  help: '多行 mpv.conf 文本（key=value，每行一条）',
  offPageWritable: true,
  read: (SettingsContext c) => currentVideoMpvConfig(c).rawConf,
  write: (SettingsContext c, String raw) => commitVideoMpvConfig(
    c,
    (VideoMpvConfig config) => config.copyWith(rawConf: raw),
  ),
);

/// 弹幕屏蔽规则（多行，每行一条，`/pattern/` 为正则）。正则行写入前先编译校验：
/// 输入框边打字边存，可以容忍中间态；CLI 一次给全，写坏的正则直接拒。
final SettingsCliValue videoDanmakuBlockRulesCli = SettingsCliValue(
  help: '多行文本，每行一条；/pattern/ 为正则，其余为子串',
  offPageWritable: true,
  read: (SettingsContext c) => c.appModel.videoDanmakuBlockRulesText,
  write: (SettingsContext c, String raw) async {
    validateVideoDanmakuBlockRules(raw);
    await commitVideoDanmakuBlockRules(c, raw);
  },
);

/// 校验弹幕屏蔽规则里的正则行；不合法抛 [FormatException]。
void validateVideoDanmakuBlockRules(String text) {
  final List<String> lines = const LineSplitter().convert(text);
  for (int i = 0; i < lines.length; i++) {
    final String line = lines[i].trim();
    if (line.length >= 2 && line.startsWith('/') && line.endsWith('/')) {
      try {
        RegExp(line.substring(1, line.length - 1));
      } on FormatException catch (e) {
        throw FormatException('第 ${i + 1} 行正则无效：${e.message}');
      }
    }
  }
}

/// 控制条 9 槽位布局 + 「快捷键 1..4」按钮绑定。
///
/// 写法是一个 JSON 对象 `{"layout": <布局 JSON>, "customActions": "a,b,,"}`（两段
/// 都可省略，省略的不改）；也接受直接给布局 JSON。布局解码器对坏输入静默回落
/// 默认布局，所以这里先校验结构，写坏不会悄悄把用户布局清掉。
final SettingsCliValue videoControlLayoutCli = SettingsCliValue(
  help:
      '{"layout": <布局 JSON，含 version 与 slots>, "customActions": '
      '"动作key,动作key,,"}（config get 的输出可改后原样写回）',
  offPageWritable: true,
  read: (SettingsContext c) {
    final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(c);
    final VideoControlLayout layout =
        host?.controlLayout() ?? c.appModel.videoControlLayout;
    final VideoCustomActionBindings bindings =
        host?.customActionBindings?.call() ??
        c.appModel.videoCustomActionBindings;
    return jsonEncode(<String, Object?>{
      'layout': jsonDecode(layout.encode()),
      'customActions': bindings.encode(),
    });
  },
  write: (SettingsContext c, String raw) async {
    final ({VideoControlLayout? layout, VideoCustomActionBindings? bindings})
    parsed = parseVideoControlLayoutCli(raw);
    final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(c);
    final VideoControlLayout? layout = parsed.layout;
    if (layout != null) {
      if (host?.onControlLayoutChanged != null) {
        await host!.onControlLayoutChanged!(layout);
      } else {
        await c.appModel.setVideoControlLayout(layout);
      }
    }
    final VideoCustomActionBindings? bindings = parsed.bindings;
    if (bindings != null) {
      if (host?.onCustomActionBindingsChanged != null) {
        await host!.onCustomActionBindingsChanged!(bindings);
      } else {
        await c.appModel.setVideoCustomActionBindings(bindings);
      }
    }
    c.refresh();
  },
);

/// 沉浸布局（锁定后屏幕左右侧栏的按钮）。写法是布局 JSON（`{"version":1,"slots":{...}}`，
/// config get 的输出可改后原样写回）；空串 = 恢复默认（按普通布局派生）。解码器对坏
/// 输入静默回派生默认，所以这里先校验结构，写坏不会悄悄把用户布局清掉。
final SettingsCliValue videoImmersiveControlLayoutCli = SettingsCliValue(
  help: '<沉浸布局 JSON，含 version 与 slots>；空串 = 恢复默认',
  offPageWritable: true,
  read: (SettingsContext c) {
    final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(c);
    final VideoImmersiveControlLayout layout =
        host?.immersiveControlLayout?.call() ??
        c.appModel.videoImmersiveControlLayout;
    return layout.encode();
  },
  write: (SettingsContext c, String raw) async {
    final VideoImmersiveControlLayout? layout;
    if (raw.trim().isEmpty) {
      layout = null;
    } else {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != 1 ||
          decoded['slots'] is! Map<String, dynamic>) {
        throw const FormatException('沉浸布局须是 {"version":1,"slots":{...}}');
      }
      layout = VideoImmersiveControlLayout.decode(
        raw,
        base: c.appModel.videoControlLayout,
      );
    }
    final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(c);
    if (host?.onImmersiveControlLayoutChanged != null) {
      await host!.onImmersiveControlLayoutChanged!(layout);
    } else {
      await c.appModel.setVideoImmersiveControlLayout(layout);
    }
    c.refresh();
  },
);

/// [videoControlLayoutCli] 的写法解析（纯函数，便于单测）。
({VideoControlLayout? layout, VideoCustomActionBindings? bindings})
parseVideoControlLayoutCli(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    throw FormatException('不是 JSON：${e.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('必须是 JSON 对象');
  }
  final bool wrapped =
      decoded.containsKey('layout') || decoded.containsKey('customActions');
  final Object? layoutRaw = wrapped ? decoded['layout'] : decoded;
  VideoControlLayout? layout;
  if (layoutRaw != null) {
    if (layoutRaw is! Map<String, dynamic> ||
        !(layoutRaw['slots'] is Map || layoutRaw['placements'] is Map) ||
        (layoutRaw.containsKey('slots') &&
            layoutRaw['version'] != 2 &&
            layoutRaw['version'] != 3)) {
      throw const FormatException('布局必须含 version(2/3) 与 slots 对象');
    }
    layout = VideoControlLayout.decode(jsonEncode(layoutRaw));
  }
  VideoCustomActionBindings? bindings;
  final Object? actionsRaw = wrapped ? decoded['customActions'] : null;
  if (actionsRaw != null) {
    if (actionsRaw is! String) {
      throw const FormatException('customActions 必须是逗号分隔的动作 key 字符串');
    }
    final List<String> keys = actionsRaw.isEmpty
        ? const <String>[]
        : actionsRaw.split(',');
    if (keys.length > VideoCustomActionBindings.slotCount) {
      throw FormatException(
        'customActions 最多 ${VideoCustomActionBindings.slotCount} 个槽位',
      );
    }
    for (final String key in keys) {
      if (key.isNotEmpty && ShortcutAction.fromKey(key) == null) {
        throw FormatException('没有快捷键动作「$key」（keys ls 查看 action 列）');
      }
    }
    bindings = VideoCustomActionBindings.decode(actionsRaw);
  }
  return (layout: layout, bindings: bindings);
}

/// 写着色器启用集：host 在场走页面回调（即时下发 mpv），否则落偏好。
Future<void> _applyEnabledShaders(SettingsContext c, List<String> names) async {
  final VideoQuickSettingsHost? host = videoQuickSettingsHostOf(c);
  if (host != null) {
    await host.onApplyShaders(names);
  } else {
    await c.appModel.setVideoShadersEnabled(encodeEnabledShaders(names));
  }
}

/// 着色器：列表 = 着色器目录里的文件（带启用标记，按启用顺序生效），增 = 导入
/// 文件（可同时启用），改 = 启用 / 停用，删 = 删文件并移出启用集。
final SettingsCliList videoShadersCliList = SettingsCliList(
  offPageWritable: true,
  fields: const <SettingsCliParam>[
    SettingsCliParam(
      'path',
      help: '要导入的着色器文件（.glsl / .hook）绝对路径（add 用）',
      required: false,
      path: true,
    ),
    SettingsCliParam(
      'enabled',
      help: 'true / false：启用或停用（add 时缺省 true）',
      required: false,
    ),
  ],
  list: (SettingsContext c) async {
    final List<String> enabled = decodeEnabledShaders(
      c.appModel.videoShadersEnabled,
    );
    return <Map<String, Object?>>[
      for (final String name in await listShaderFiles())
        <String, Object?>{
          'id': name,
          'enabled': enabled.contains(name),
          if (enabled.contains(name)) 'order': enabled.indexOf(name) + 1,
        },
    ];
  },
  add: (SettingsContext c, Map<String, String> fields) async {
    final String? path = fields['path'];
    if (path == null || path.isEmpty) throw ArgumentError('add 需要 path');
    if (!kShaderExtensions.contains(p.extension(path).toLowerCase()) ||
        !File(path).existsSync()) {
      throw ArgumentError('不是存在的 .glsl / .hook 文件：$path');
    }
    final String name = await importShaderFile(path);
    final bool enable = _parseBool(fields['enabled'] ?? 'true');
    final List<String> enabled = List<String>.of(
      decodeEnabledShaders(c.appModel.videoShadersEnabled),
    )..remove(name);
    if (enable) enabled.add(name);
    await _applyEnabledShaders(c, enabled);
    return <String, Object?>{'id': name, 'enabled': enable};
  },
  update: (SettingsContext c, String id, Map<String, String> fields) async {
    final String? raw = fields['enabled'];
    if (raw == null) throw ArgumentError('只能改 enabled');
    final bool enable = _parseBool(raw);
    final List<String> enabled = List<String>.of(
      decodeEnabledShaders(c.appModel.videoShadersEnabled),
    )..remove(id);
    if (enable) enabled.add(id);
    await _applyEnabledShaders(c, enabled);
    return <String, Object?>{'id': id, 'enabled': enable};
  },
  remove: (SettingsContext c, String id) async {
    final Directory dir = await mpvShaderDirectory();
    final File file = File(p.join(dir.path, id));
    if (!p.isWithin(dir.path, file.path) || !file.existsSync()) {
      throw ArgumentError('着色器目录里没有 $id');
    }
    final List<String> enabled = decodeEnabledShaders(
      c.appModel.videoShadersEnabled,
    );
    if (enabled.contains(id)) {
      await _applyEnabledShaders(c, <String>[
        for (final String name in enabled)
          if (name != id) name,
      ]);
    }
    await file.delete();
  },
);

bool _parseBool(String raw) => switch (raw.trim().toLowerCase()) {
  'true' || '1' || 'on' || 'yes' => true,
  'false' || '0' || 'off' || 'no' => false,
  _ => throw ArgumentError('enabled 必须是 true / false，收到「$raw」'),
};
