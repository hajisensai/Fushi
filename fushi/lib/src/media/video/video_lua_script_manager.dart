import 'dart:io';

import 'package:fushi/src/media/video/video_lua_capability.dart';
import 'package:fushi/src/storage/app_paths.dart';
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
/// Lua 是按平台固定的二进制事实（[MpvLuaCapability]，Windows 有、Android 实测
/// `-Dlua=disabled` 没有），没编时 `load-script` 照样返回成功、然后什么都不发生。
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
/// Hibiki 自己的 seek 顺带弹出原生进度条。没装脚本的播放器保持 media_kit 默认。
///
/// **诊断**：mpv 对 `load-script` 成功不打任何日志，失败只打 error/fatal 日志
/// （`Could not load lua script <path>` / `<脚本名>: Lua error: ...`），
/// media_kit 默认 `logLevel=error` 恰好收得到。[matchLuaLogToScripts] 把日志行
/// 归到脚本路径，[VideoPlayerController.luaScriptStates] 据此给设置页每脚本一行
/// 状态——"貌似用不了"必须变成"哪个脚本、哪一行报了什么"。
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
/// Hibiki 的进度条是 Flutter 层自己的，两条叠着就是 bug。
Map<String, String> buildLuaOsdProperties() => const <String, String>{
      'osd-level': '1',
      'osd-on-seek': 'no',
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
