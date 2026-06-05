import 'dart:convert';
import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// mpv 着色器（Anime4K 等）管理：导入到固定目录、列出、启用集持久化、应用到播放器。
///
/// 着色器经 libmpv 的 `glsl-shaders` 属性生效——media_kit 底层即 libmpv。**仅桌面**
/// （Windows/macOS/Linux）实测可用；移动端 GPU 着色器性能/兼容性未验证，[applyShadersToPlayer]
/// 在非 libmpv 后端/属性不支持时静默 no-op（device 验证待用户）。

/// 着色器文件扩展名。
const Set<String> kShaderExtensions = <String>{'.glsl', '.hook'};

/// 着色器存放目录：`<appDocs>/mpv_shaders`（不存在则创建）。
Future<Directory> mpvShaderDirectory() async {
  final Directory docs = await getApplicationDocumentsDirectory();
  final Directory dir = Directory(p.join(docs.path, 'mpv_shaders'));
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

/// 把 [absolutePaths] 着色器应用到 media_kit [player]（仅 libmpv 后端/桌面生效）。
///
/// 先把 `glsl-shaders` 清空，再逐个 `glsl-shaders-append`——用 append 规避
/// `glsl-shaders` 单串里的**平台路径分隔符差异**（Unix `:` vs Windows `;`，且
/// Windows 路径含 `:`）。best-effort：`player.platform` 非 libmpv（无 setProperty）
/// 或属性不支持时静默吞掉（移动端 GPU 着色器后续再放）。
Future<void> applyShadersToPlayer(
    Player player, List<String> absolutePaths) async {
  // media_kit 的原生后端是 NativePlayer（libmpv），暴露 setProperty(name, value)
  // → mpv_set_property_string。用 dynamic 避免硬耦合 media_kit 内部导出；这是
  // 外部播放器边界，失败即静默是合理降级（见上方 doc）。
  final dynamic native = player.platform;
  if (native == null) return;
  try {
    await native.setProperty('glsl-shaders', '');
    for (final String path in absolutePaths) {
      await native.setProperty('glsl-shaders-append', path);
    }
  } catch (_) {
    // 非 libmpv 后端 / 属性不支持：静默 no-op。
  }
}
