import 'dart:convert';
import 'dart:io';

import 'package:hibiki/src/storage/app_paths.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

/// mpv 着色器（Anime4K 等）管理：导入到固定目录、列出、启用集持久化、应用到播放器。
///
/// 着色器经 libmpv 的 `glsl-shaders` 属性生效——media_kit 五平台底层都是 libmpv
/// （NativePlayer）。**Android/iOS 同样走 libmpv 的 GPU 渲染管线**：media_kit 在
/// 移动端默认 `vo=gpu` + `gpu-context=android`/`opengl-es=yes`、`hwdec=auto-safe`
/// （非 `mediacodec_embed` 旁路），故 `glsl-shaders` 在标准渲染路径下生效，不是「移动端
/// no-op」。依据：media_kit_video 2.0.1
/// `lib/src/video_controller/android_video_controller/real.dart:151`（`vo ?? 'gpu'`）
/// 与 `:199-208`（`gpu-context=android` / `opengl-es=yes`），见
/// `.codex-test/todo-041-shader-tier-research.md` 复核补查。
/// [applyShadersToPlayer] 只在 `player.platform` 非 libmpv（无 NativePlayer）或属性
/// 不支持时才静默 no-op；性能/实际增益因机型 GPU 而异（高档可能掉帧/发热）。

/// 着色器文件扩展名。
const Set<String> kShaderExtensions = <String>{'.glsl', '.hook'};

/// 着色器存放目录：`<appDocs>/mpv_shaders`（不存在则创建）。
Future<Directory> mpvShaderDirectory() async {
  // TODO-935 E0：经唯一入口 [AppPaths] 派生 `<documents>/mpv_shaders`。
  final Directory dir = await AppPaths.mpvShadersDirectory();
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

/// 列出 [dir] 里的着色器文件名（basename，按名排序）。纯函数（只读目录），便于单测。
List<String> listShaderFilesIn(Directory dir) {
  if (!dir.existsSync()) return const <String>[];
  final List<String> out = <String>[];
  for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
    if (e is! File) continue;
    if (kShaderExtensions.contains(p.extension(e.path).toLowerCase())) {
      out.add(p.basename(e.path));
    }
  }
  out.sort();
  return out;
}

/// 把 [sourcePath] 着色器复制进 [dir]，返回目标文件名（basename）。重名覆盖。
/// 纯到只依赖文件系统拷贝，便于用临时目录单测。
String importShaderFileTo(Directory dir, String sourcePath) {
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final String name = p.basename(sourcePath);
  File(sourcePath).copySync(p.join(dir.path, name));
  return name;
}

/// 列出着色器目录里的着色器文件名（异步包装 [listShaderFilesIn]）。
Future<List<String>> listShaderFiles() async =>
    listShaderFilesIn(await mpvShaderDirectory());

/// 导入着色器到默认目录（异步包装 [importShaderFileTo]）。
Future<String> importShaderFile(String sourcePath) async =>
    importShaderFileTo(await mpvShaderDirectory(), sourcePath);

/// 启用集编码为持久化字符串（JSON 字符串数组）。纯函数。
String encodeEnabledShaders(List<String> names) => jsonEncode(names);

/// 解码启用集（容错：null/空/非法 JSON → 空列表）。纯函数。
List<String> decodeEnabledShaders(String? json) {
  if (json == null || json.isEmpty) return const <String>[];
  try {
    final dynamic decoded = jsonDecode(json);
    if (decoded is List) {
      return decoded.whereType<String>().toList(growable: false);
    }
  } catch (_) {
    // 损坏的持久化值：当作无启用着色器。
  }
  return const <String>[];
}

/// 把启用的着色器文件名（相对目录）解析成存在的绝对路径，过滤掉已删除的。纯函数
/// （除存在性检查外不碰内容），便于注入临时目录单测。
List<String> resolveShaderPathsIn(Directory dir, List<String> enabledNames) {
  final List<String> out = <String>[];
  for (final String name in enabledNames) {
    final File f = File(p.join(dir.path, name));
    if (f.existsSync()) out.add(f.path);
  }
  return out;
}

/// 异步包装 [resolveShaderPathsIn]：用默认着色器目录解析启用集为绝对路径。
Future<List<String>> resolveEnabledShaderPaths(
    List<String> enabledNames) async {
  return resolveShaderPathsIn(await mpvShaderDirectory(), enabledNames);
}

/// 本机 mpv 配置目录的候选路径（按优先级），用于发现用户已有的着色器。纯函数
/// （注入 [env] 与平台标志），便于单测。
///
/// 优先级：`MPV_HOME`（mpv 官方支持的覆盖变量，全平台）→ 平台默认配置目录。
/// - Windows：`%APPDATA%\mpv`（mpv / mpv.net 默认）。
/// - 类 Unix：`$XDG_CONFIG_HOME/mpv`（设了则用它，符合 XDG 语义）否则 `~/.config/mpv`。
/// - macOS：再追加 `~/Library/Application Support/mpv`（部分安装放这里）。
List<String> mpvConfigDirCandidates({
  required Map<String, String> env,
  required bool isWindows,
  required bool isMacOS,
}) {
  final List<String> out = <String>[];
  void add(String? path) {
    if (path == null || path.isEmpty) return;
    if (!out.contains(path)) out.add(path);
  }

  add(env['MPV_HOME']);

  if (isWindows) {
    // mpv（默认）、mpv.net（流行 GUI 分支）、LOCALAPPDATA 变体都覆盖到（更正经）。
    final String? appData = env['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      add(p.join(appData, 'mpv'));
      add(p.join(appData, 'mpv.net'));
    }
    final String? localAppData = env['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      add(p.join(localAppData, 'mpv'));
    }
    return out;
  }

  final String? xdg = env['XDG_CONFIG_HOME'];
  final String? home = env['HOME'];
  if (xdg != null && xdg.isNotEmpty) {
    add(p.join(xdg, 'mpv'));
  }
  if (home != null && home.isNotEmpty) {
    // XDG 设了仍补 ~/.config/mpv（很多人两处都有）。
    add(p.join(home, '.config', 'mpv'));
  }
  if (isMacOS && home != null && home.isNotEmpty) {
    add(p.join(home, 'Library', 'Application Support', 'mpv'));
  }
  return out;
}

/// **纯函数**：从 `PATH` 环境变量里解析出可能的便携版 mpv 配置目录。
///
/// 便携版 mpv（解压即用）把配置放在 mpv.exe 同目录的 `portable_config/`（mpv 官方约定）。
/// 故对 `PATH` 里每个目录给出 `<dir>/portable_config` 候选（存在性由
/// [discoverLocalMpvShaders] 过滤）。**只给 `portable_config` 子目录、不给 `PATH` 目录
/// 本身**——否则发现逻辑会去递归扫 `System32` 等系统目录找着色器（极慢）。
/// [pathSeparator] 注入便于单测（Win `;` / Unix `:`）。
List<String> mpvPortableConfigCandidates({
  required Map<String, String> env,
  required String pathSeparator,
}) {
  final String? path = env['PATH'];
  if (path == null || path.isEmpty) return const <String>[];
  final List<String> out = <String>[];
  for (final String entry in path.split(pathSeparator)) {
    final String dir = entry.trim();
    if (dir.isEmpty) continue;
    final String pc = p.join(dir, 'portable_config');
    if (!out.contains(pc)) out.add(pc);
  }
  return out;
}

/// 扫 [mpvConfigDir] 下 `shaders/` 子目录里的着色器文件（绝对路径，按名排序）。纯函数。
/// mpv 配置约定写 `glsl-shaders=~~/shaders/xxx.glsl`，故着色器惯例放在 `shaders/` 子目录。
List<String> discoverMpvShadersIn(Directory mpvConfigDir) {
  final Directory shaderDir = Directory(p.join(mpvConfigDir.path, 'shaders'));
  if (!shaderDir.existsSync()) return const <String>[];
  final List<String> out = <String>[];
  for (final FileSystemEntity e in shaderDir.listSync(followLinks: false)) {
    if (e is! File) continue;
    if (kShaderExtensions.contains(p.extension(e.path).toLowerCase())) {
      out.add(e.path);
    }
  }
  out.sort();
  return out;
}

/// 在 [dir] 下**递归**发现着色器（绝对路径，按 basename 去重保序）。纯函数（只读）。
///
/// 「更正经」的发现：不再只盯死 `shaders/` 一层——用户可能直接指向 shaders 文件夹、
/// 指向 mpv 配置目录（着色器在 `shaders/`）、把着色器散在配置根、或装在 `shaders/<包名>/`
/// 子目录里，统统递归扫到。深度上限 [maxDepth]（默认 6）防病态深树。按全路径排序后
/// 按 basename 去重（同名取路径靠前者：配置根 < `shaders/` < 更深，符合直觉）。
List<String> discoverShadersInUserDir(Directory dir, {int maxDepth = 6}) {
  if (!dir.existsSync()) return const <String>[];
  final List<String> files = <String>[];
  void walk(Directory d, int depth) {
    if (depth > maxDepth) return;
    final List<FileSystemEntity> entries;
    try {
      entries = d.listSync(followLinks: false);
    } on FileSystemException {
      return; // 权限/IO 失败：跳过该子树，不抛。
    }
    for (final FileSystemEntity e in entries) {
      if (e is File) {
        if (kShaderExtensions.contains(p.extension(e.path).toLowerCase())) {
          files.add(e.path);
        }
      } else if (e is Directory) {
        walk(e, depth + 1);
      }
    }
  }

  walk(dir, 0);
  files.sort();
  final List<String> out = <String>[];
  final Set<String> seen = <String>{};
  for (final String f in files) {
    if (seen.add(p.basename(f))) out.add(f);
  }
  return out;
}

/// 发现本机 mpv 安装里已有的着色器（绝对路径，按 basename 去重保序）。
///
/// 「更正经」的多路探测，按优先级合并去重：
/// 1. [overrideDir]（用户手动指定）——递归扫，最优先；
/// 2. [mpvConfigDirCandidates] 标准配置目录（mpv / mpv.net / LOCALAPPDATA / XDG /
///    ~/.config / /etc/mpv / macOS App Support）——每个递归扫；
/// 3. [mpvPortableConfigCandidates] 便携版（`PATH` 里 mpv.exe 同目录的 `portable_config`）。
///
/// 移动端 / 未装 mpv 且无 override → 空列表（天然降级，UI 引导手动指定目录）。
Future<List<String>> discoverLocalMpvShaders({String? overrideDir}) async {
  final List<String> out = <String>[];
  final Set<String> seenNames = <String>{};
  void mergeDir(String dirPath) {
    final Directory dir = Directory(dirPath);
    if (!dir.existsSync()) return;
    for (final String s in discoverShadersInUserDir(dir)) {
      if (seenNames.add(p.basename(s))) out.add(s);
    }
  }

  // 1) 用户手动指定的目录优先。
  if (overrideDir != null && overrideDir.isNotEmpty) mergeDir(overrideDir);

  // 2) 标准配置目录候选。
  for (final String dirPath in mpvConfigDirCandidates(
    env: Platform.environment,
    isWindows: Platform.isWindows,
    isMacOS: Platform.isMacOS,
  )) {
    mergeDir(dirPath);
  }

  // 3) 便携版：PATH 里 mpv 同目录的 portable_config。
  for (final String dirPath in mpvPortableConfigCandidates(
    env: Platform.environment,
    pathSeparator: Platform.isWindows ? ';' : ':',
  )) {
    mergeDir(dirPath);
  }
  return out;
}

/// 把 [absolutePaths] 着色器应用到 media_kit [player]（libmpv 后端，五平台均生效）。
///
/// 先把 `glsl-shaders` 清空，再逐个 `glsl-shaders-append`——用 append 规避
/// `glsl-shaders` 单串里的**平台路径分隔符差异**（Unix `:` vs Windows `;`，且
/// Windows 路径含 `:`）。media_kit 在 Android/iOS 同样是 libmpv + `vo=gpu`（见本文件头
/// doc 的 media_kit 源码出处），故此处的 `setProperty` 在移动端也写穿、着色器进渲染管线，
/// **不是移动端 no-op**。best-effort：仅在 `player.platform` 非 libmpv（无 setProperty）
/// 或属性不支持时静默吞掉。
Future<void> applyShadersToPlayer(
    Player player, List<String> absolutePaths) async {
  // media_kit 的原生后端是 NativePlayer（libmpv），五平台一致，暴露 setProperty(name,
  // value) → mpv_set_property_string。用 dynamic 避免硬耦合 media_kit 内部导出；这是
  // 外部播放器边界，失败即静默是合理降级（见上方 doc）。移动端走 vo=gpu 渲染路径，属性
  // 同样生效，这里不按平台门控。
  final dynamic native = player.platform;
  if (native == null) return;
  try {
    await native.setProperty('glsl-shaders', '');
    for (final String path in absolutePaths) {
      await native.setProperty('glsl-shaders-append', path);
    }
  } catch (_) {
    // 非 libmpv 后端 / 属性不支持：静默 no-op（非按平台门控——移动端 libmpv 同样生效）。
  }
}
