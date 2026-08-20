import 'dart:io';

import 'package:fushi/src/storage/app_paths.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

/// mpv Lua 脚本管理：固定目录、列出、导入、经 `load-script` 命令装载到播放器。
///
/// 语义对齐 mpv 自己的 `scripts/` 目录：放进 [mpvLuaScriptDirectory] 的 `.lua`
/// 文件在开关开启时**整目录**装载（按文件名排序），删掉/移走文件即禁用——不引入
/// 每文件启用集这层多余状态（与着色器不同：脚本没有"档位组合"语义）。
///
/// 装载走 libmpv 的 `load-script` **命令**（`mpv_command`），不是 property——
/// `scripts` 选项是 init-only，media_kit 建 handle 后经 setProperty 写它是静默
/// no-op。与 [applyShadersToPlayer]（video_shader_manager.dart）同一条
/// `NativePlayer.command` 边界，五平台 libmpv 后端均可达；随包 libmpv 未编 Lua
/// 或非 libmpv 后端时单条命令失败静默吞掉（best-effort，不影响播放）。
///
/// **不可卸载**：mpv 没有 unload-script 命令，脚本一旦装进 Player 实例就伴随其
/// 整个生命周期；重复 `load-script` 同一路径会实例化第二份脚本。因此装载必须
/// **每 Player 实例幂等**（[VideoPlayerController.applyLuaScripts] 用已装载集
/// 去重），关闭开关只对之后新建的 Player 生效（下次进入视频页）。
///
/// 能力边界（用户可感）：键盘/鼠标事件由 Flutter 层消费、到不了 libmpv，依赖
/// 按键绑定或 OSC 交互的脚本无处触发；监听属性/事件、自动改属性的逻辑型脚本
/// 正常工作，脚本 OSD 会随视频帧渲染。`script-opts` 属性运行时可设，高级用户
/// 可经 [VideoMpvConfig.rawConf] 给脚本传参。

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

/// 把 [absolutePaths] 逐条经 `load-script` 装载到 media_kit [player]。
///
/// best-effort 且**逐条**兜异常（与 [applyShadersToPlayer] 的整体 try 不同）：
/// 单个脚本坏了（语法错/路径失效）不挡后面的脚本。幂等去重由调用方负责
/// （见文件头"不可卸载"段），本函数只管下发。
Future<void> applyLuaScriptsToPlayer(
    Player player, List<String> absolutePaths) async {
  final dynamic native = player.platform;
  if (native == null) return;
  for (final List<String> cmd in buildLoadScriptCommands(absolutePaths)) {
    try {
      await native.command(cmd);
    } catch (_) {
      // 非 libmpv 后端 / 未编 Lua / 单个脚本装载失败：跳过这条，继续下一条。
    }
  }
}
