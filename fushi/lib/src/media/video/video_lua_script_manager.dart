import 'dart:io';

import 'package:fushi/src/media/video/video_lua_capability.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

export 'package:fushi/src/media/video/video_lua_capability.dart';

/// mpv Lua 脚本管理：固定目录、列出、导入、经 `load-script` 命令装载到播放器，
/// 以及把 mpv 日志归因到脚本（BUG-2032 诊断面）。
///
/// 语义对齐 mpv 自己的 `scripts/` 目录：放进 [mpvLuaScriptDirectory] 的 `.lua`
/// 文件在开关开启时**整目录**装载（按文件名排序），删掉/移走文件即禁用——不引入
/// 每文件启用集这层多余状态（与着色器不同：脚本没有"档位组合"语义）。
///
/// 装载走 libmpv 的 `load-script` **命令**（`mpv_command`），不是 property——
/// `scripts` 选项是 init-only，media_kit 建 handle 后经 setProperty 写它是静默
/// no-op。与 [applyShadersToPlayer]（video_shader_manager.dart）同一条
/// `NativePlayer.command` 边界。**命令可达 ≠ 脚本能跑**：随包 libmpv 有没有编
/// Lua 是按平台固定的二进制事实（[MpvLuaCapability]；Android 随包 jar 自 BUG-3325
/// 起编入 Lua 5.2；Windows 随包 libmpv 自 `fushi-discnav1-hwcrop1-lua1` 起由
/// `tool/bluray/build_libmpv.ps1` 以 `-Dlua=luajit` 构建、有（BUG-3325），此前的
/// `fushi-discnav1` 系是 `-Dlua=disabled`），没编时 `load-script` 可能照样返回成功、
/// 然后什么都不发生。
/// 能力由 [VideoPlayerController] 建 Player 后读 `mpv-configuration` 探测并落
/// pref，设置页据此如实说明；不按平台名硬编码。
///
/// **不可卸载**：mpv 没有 unload-script 命令，脚本一旦装进 Player 实例就伴随其
/// 整个生命周期；重复 `load-script` 同一路径会实例化第二份脚本。因此装载必须
/// **每 Player 实例幂等**（[VideoPlayerController.applyLuaScripts] 用已装载集
/// 去重），关闭开关只对之后新建的 Player 生效（下次进入视频页）。
///
/// **OSD**：media_kit 建 handle 写死 `osd-level=0`（media_kit-1.2.6
/// real.dart:2421），mpv 在 `set_osd_msg_va` 里 `level > osd_level` 直接丢弃
/// （player/osd.c），脚本最常用的 `mp.osd_message` 一个字都画不出来。装载脚本时
/// 同批下发 [buildLuaOsdProperties] 把文字 OSD 层打开，并用 `osd-on-seek=no` 防止
/// Fushi 自己的 seek 顺带弹出原生进度条。没装脚本的播放器保持 media_kit 默认。
///
/// **诊断**：mpv 对 `load-script` 成功不打任何日志，失败只打 error/fatal 日志
/// （`Could not load lua script <path>` / `<脚本名>: Lua error: ...`），
/// media_kit 默认 `logLevel=error` 恰好收得到。[matchLuaLogToScripts] 把日志行
/// 归到脚本路径，[VideoPlayerController.luaScriptStates] 据此给设置页每脚本一行
/// 状态——"貌似用不了"必须变成"哪个脚本、哪一行报了什么"。
///
/// **字幕镜像**（#2014）：Fushi 的字幕全部由 Flutter overlay 自己画，libmpv 侧
/// `sid` 平时恒为 `no`——依赖 `sub-text` / `sub-start` / `sub-end` 的脚本（字幕结束
/// 自动暂停、`sub-seek` 逐句跳转这类最常见的脚本）因此永远收不到任何一句字幕。装了
/// 脚本且主字幕是 Dart 侧文本 cue 时，[VideoPlayerController] 把同一份 cue 写成 SRT
/// （[buildLuaSubtitleMirrorSrt]）经 `sub-add` 挂成一条隐藏轨（标题
/// [kLuaSubtitleMirrorTrackTitle]）：`sub-visibility=no` 不画，Dart 侧调轴直接烘进 SRT
/// 时间戳，脚本读到的就是 overlay 正显示的那句。这条轨不是用户的字幕源，按序号选轨
/// / 数轨的地方都要用 [isLuaSubtitleMirrorTrack] 滤掉它（它是 `sub-add` 追加的外挂
/// 轨，排在全部内嵌轨之后，不会挤占内嵌轨序号）。
///
/// 能力边界（用户可感，设置页列表底部原样说明）：键盘/鼠标事件由 Flutter 层消费、
/// 到不了 libmpv，依赖按键绑定或 OSC 交互的脚本无处触发；监听属性/事件、自动改
/// 属性的逻辑型脚本正常工作，脚本 OSD 随视频帧渲染。`script-opts` 属性运行时可设，
/// 高级用户可经 [VideoMpvConfig.rawConf] 给脚本传参。

/// Lua 脚本文件扩展名。
const String kLuaScriptExtension = '.lua';

/// Lua 脚本存放目录：`<documents>/mpv_scripts`（不存在则创建）。
Future<Directory> mpvLuaScriptDirectory() async {
  final Directory dir = await AppPaths.mpvLuaScriptsDirectory();
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

/// 列出 [dir] 里的 Lua 脚本**绝对路径**（仅顶层、按路径排序）。纯函数（只读目录），
/// 便于用临时目录单测。不递归——子目录留给用户放脚本自己的资源/模块，避免把
/// `xxx/modules/*.lua` 这类依赖文件当独立脚本重复装载。
List<String> listLuaScriptFilesIn(Directory dir) {
  if (!dir.existsSync()) return const <String>[];
  final List<String> out = <String>[];
  for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
    if (e is! File) continue;
    if (p.extension(e.path).toLowerCase() == kLuaScriptExtension) {
      out.add(e.path);
    }
  }
  out.sort();
  return out;
}

/// 把 [sourcePath] 脚本复制进 [dir]，返回目标文件名（basename）。重名覆盖。
/// 与 [importShaderFileTo]（video_shader_manager.dart）同范式，便于临时目录单测。
String importLuaScriptFileTo(Directory dir, String sourcePath) {
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final String name = p.basename(sourcePath);
  File(sourcePath).copySync(p.join(dir.path, name));
  return name;
}

/// 列出脚本目录里的 Lua 脚本绝对路径（异步包装 [listLuaScriptFilesIn]）。
Future<List<String>> listLuaScriptPaths() async =>
    listLuaScriptFilesIn(await mpvLuaScriptDirectory());

/// 导入脚本到默认目录（异步包装 [importLuaScriptFileTo]）。
Future<String> importLuaScriptFile(String sourcePath) async =>
    importLuaScriptFileTo(await mpvLuaScriptDirectory(), sourcePath);

/// 构建把 [absolutePaths] 装载进 libmpv 的 `load-script` 命令序列。纯函数，便于单测。
/// 每个路径一条独立命令（`mpv_command` 数组形式），天然规避路径转义问题。
List<List<String>> buildLoadScriptCommands(List<String> absolutePaths) {
  return <List<String>>[
    for (final String path in absolutePaths) <String>['load-script', path],
  ];
}

/// 装载脚本时同批下发的 OSD 属性（见文件头"OSD"段）。纯函数。
///
/// `osd-level=1`：文字 OSD 只在有人主动 `show-text` / `mp.osd_message` 时出现
/// （不常驻时间/状态行）。`osd-on-seek=no`：seek 命令不再顺带画原生进度条——
/// Fushi 的进度条是 Flutter 层自己的，两条叠着就是 bug。
Map<String, String> buildLuaOsdProperties() => const <String, String>{
  'osd-level': '1',
  'osd-on-seek': 'no',
};

/// 每次 `open` 之前都下发的 Lua 宿主基线属性，与有没有装用户脚本无关。纯函数。
///
/// libmpv 一旦编了 Lua，mpv 内置的 `ytdl_hook.lua` 也随之生效（`ytdl` 默认
/// `yes`）：网络流加载失败时它会去拉起 `yt-dlp` / `youtube-dl` 子进程重新解析
/// URL。Fushi 的在线流一律由 Dart 侧解析、经应用内中继（`http-proxy`）取字节，
/// 不需要也不允许 mpv 绕开这条链路自己解析——移动端更没有那个可执行文件，只会
/// 白白多一轮失败重试、把真实的加载错误盖掉。必须在 `open` 之前设：钩子挂在
/// loadfile 的 `on_load` / `on_load_fail` 上。
Map<String, String> buildLuaHostBaselineProperties() => const <String, String>{
  'ytdl': 'no',
};

final RegExp _nonIdentifierChar = RegExp(r'[^A-Za-z0-9]');

/// mpv 给脚本起的客户端名（日志 prefix / `script-message-to` 目标），复刻
/// `player/scripting.c: script_name_from_filename`：取 basename、去前导 `@`、
/// 去最后一个 `.` 起的扩展名、非 `[A-Za-z0-9]` 一律改 `_`。纯函数。
String luaScriptNameForPath(String path) {
  String name = p.basename(path);
  if (name.startsWith('@')) name = name.substring(1);
  final int dot = name.lastIndexOf('.');
  if (dot >= 0) name = name.substring(0, dot);
  return name.replaceAll(_nonIdentifierChar, '_');
}

/// 一条 mpv 日志归因到脚本的结果：命中的脚本路径（≥1）+ 去首尾空白的原文。
class LuaScriptLogHit {
  const LuaScriptLogHit({required this.paths, required this.message});

  final List<String> paths;
  final String message;
}

/// 把一条 mpv 日志（media_kit `PlayerLog` 的三元组）归到 [scriptPaths] 里的脚本。
/// 纯函数；与脚本无关的行返回 null。
///
/// 只认 `error` / `fatal` 两级——成功没有日志，info 级是脚本自己的闲聊。两条归因路径
/// 对应 mpv 两个报错点：
///  - `cplayer` 前缀 + 正文含脚本**完整路径**：装载阶段失败
///    （scripting.c `Could not load lua script %s` / `Can't load unknown script: %s`
///    / `Failed to create client for script: %s`），mpv 原样回显我们传入的路径。
///  - 前缀 == 脚本客户端名（[luaScriptNameForPath]）：脚本已实例化但 Lua 运行时报错
///    （lua.c `Lua error: %s`，fatal）或脚本自己 `mp.msg.error`。同名多脚本一起命中——
///    宁可多标不可漏标。
LuaScriptLogHit? matchLuaLogToScripts({
  required String prefix,
  required String level,
  required String text,
  required Iterable<String> scriptPaths,
}) {
  if (level != 'error' && level != 'fatal') return null;
  final String message = text.trim();
  if (message.isEmpty) return null;
  final List<String> hits = prefix == 'cplayer'
      ? <String>[
          for (final String path in scriptPaths)
            if (message.contains(path)) path,
        ]
      : <String>[
          for (final String path in scriptPaths)
            if (luaScriptNameForPath(path) == prefix) path,
        ];
  if (hits.isEmpty) return null;
  return LuaScriptLogHit(paths: hits, message: message);
}

/// 把 [absolutePaths] 逐条经 `load-script` 装载到 media_kit [player]。
///
/// best-effort 且**逐条**兜异常（与 [applyShadersToPlayer] 的整体 try 不同）：
/// 单个脚本坏了（语法错/路径失效）不挡后面的脚本。幂等去重由调用方负责
/// （见文件头"不可卸载"段），本函数只管下发。
Future<void> applyLuaScriptsToPlayer(
  Player player,
  List<String> absolutePaths,
) async {
  final dynamic native = player.platform;
  if (native == null) return;
  for (final List<String> cmd in buildLoadScriptCommands(absolutePaths)) {
    try {
      await native.command(cmd);
    } catch (_) {
      // 非 libmpv 后端 / 单个脚本装载失败：跳过这条，继续下一条。失败原因由
      // mpv 日志经 [matchLuaLogToScripts] 归因到脚本，不在这里吞成"没事"。
    }
  }
}

/// 字幕镜像轨在 mpv `track-list` 里的标题（`sub-add` 第三参数），据此把它与用户的
/// 真实字幕轨区分开（见文件头"字幕镜像"段）。
const String kLuaSubtitleMirrorTrackTitle = 'fushi-lua-subtitle-mirror';

/// [track] 是否是 Fushi 给 Lua 脚本挂的字幕镜像轨（不是用户的字幕源）。纯函数。
bool isLuaSubtitleMirrorTrack(SubtitleTrack track) =>
    track.title == kLuaSubtitleMirrorTrackTitle;

/// `sub-add <srt> select <标题>` 之后，从 libmpv 当前主字幕轨
/// （`current-tracks/sub/id` / `current-tracks/sub/title`）认回镜像轨 id。纯函数。
///
/// 只认当前选中轨、不按 `track-list` 末尾认：TS / 网络流会在播放中途动态追加轨，
/// 末尾那条未必是刚挂的镜像。标题对不上（选中被别处改掉）或属性不可用（读到空串）
/// 时返回 null——宁可不记，也不能把用户的真实轨记成镜像拿去 `sub-remove`。
String? resolveLuaSubtitleMirrorTrackId({
  required String selectedId,
  required String selectedTitle,
}) {
  final String id = selectedId.trim();
  if (selectedTitle != kLuaSubtitleMirrorTrackTitle) return null;
  if (id.isEmpty || id == 'no' || id == 'auto') return null;
  return id;
}

/// 删除一份字幕镜像 SRT（`systemTemp/fushi_lua_subtitle_mirror` 下的临时文件）。
///
/// [after] 非 null 时先等它完成再删——典型是 libmpv Player 的释放：Windows 上仍被
/// mpv 打开的文件删不掉。[after] 自身失败不影响删除（释放失败由它自己的调用方报告）。
/// 文件已不存在 / 删不掉不算错误：临时目录里的残留无害，调用方也做不了更多。
Future<void> discardLuaSubtitleMirrorFile(
  File file, {
  Future<void>? after,
}) async {
  if (after != null) {
    try {
      await after;
    } catch (_) {
      // 释放失败照样删文件。
    }
  }
  try {
    await file.delete();
  } on FileSystemException {
    // 已被清理 / 仍被占用：临时目录里的残留无害。
  }
}

/// 字幕镜像该不该挂：装了脚本、主字幕是 Dart 侧文本 cue（非图形轨 / 非 libmpv
/// 解码回流——后两者 libmpv 已有真实 `sid`，脚本本就读得到）、且不在蓝光导航会话
/// （那里的轨归碟片菜单所有）。纯函数，供控制器与单测共用同一判据。
bool shouldMirrorSubtitlesForLua({
  required bool hasLoadedScripts,
  required bool hasTextCues,
  required bool graphicSubtitleActive,
  required bool playerDecodedSubtitleActive,
  required bool blurayNavigationSession,
}) =>
    hasLoadedScripts &&
    hasTextCues &&
    !graphicSubtitleActive &&
    !playerDecodedSubtitleActive &&
    !blurayNavigationSession;

/// 把 [cues]（Dart 侧主字幕）连同调轴 [delayMs] 写成 SRT。纯函数。
///
/// 调轴**烘进时间戳**，不走 mpv `sub-delay`：实测（mpv 0.41）`sub-start` /
/// `sub-end` 报的是未叠 `sub-delay` 的原始时间，而 `sub-text` 按叠过的时间出现——
/// 拿 `sub-end` 对 `time-pos` 判句尾的脚本会在句中就停。烘进去后三者同口径，与
/// overlay（`posMs - delayMs` 落在 cue 内即显示）同一句、同一刻。负偏移把时间推到
/// 0 之前的部分截到 0。
///
/// 只保留 `endMs > startMs` 且有正文的 cue，按 startMs 排序后连续编号。SRT 以空行
/// 分隔条目，正文里的空行会把一条拆成两条，故压掉空行、换行统一成 `\n`。返回空串
/// 表示没有可镜像的 cue（调用方据此不挂轨）。
String buildLuaSubtitleMirrorSrt(List<AudioCue> cues, {int delayMs = 0}) {
  final List<AudioCue> usable = <AudioCue>[
    for (final AudioCue cue in cues)
      if (cue.endMs > cue.startMs && cue.text.trim().isNotEmpty) cue,
  ]..sort((AudioCue a, AudioCue b) => a.startMs.compareTo(b.startMs));
  final StringBuffer out = StringBuffer();
  int index = 0;
  for (final AudioCue cue in usable) {
    final int startMs = cue.startMs + delayMs;
    final int endMs = cue.endMs + delayMs;
    if (endMs <= 0) continue; // 整句被负偏移推到片头之前：不可能再显示。
    index++;
    final String text = cue.text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((String line) => line.trimRight())
        .where((String line) => line.isNotEmpty)
        .join('\n');
    out
      ..write('$index\n')
      ..write('${_srtTimestamp(startMs)} --> ${_srtTimestamp(endMs)}\n')
      ..write('$text\n\n');
  }
  return out.toString();
}

/// 毫秒 → SRT 时间戳 `HH:MM:SS,mmm`（负值按 0）。
String _srtTimestamp(int ms) {
  final int t = ms < 0 ? 0 : ms;
  String pad(int value, int width) => value.toString().padLeft(width, '0');
  return '${pad(t ~/ 3600000, 2)}:${pad(t ~/ 60000 % 60, 2)}:'
      '${pad(t ~/ 1000 % 60, 2)},${pad(t % 1000, 3)}';
}
