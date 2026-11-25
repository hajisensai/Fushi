/// 「Apple（Cupertino）设计系统专属源文件」的唯一判据，供 M3E 令牌守卫
/// （`test/settings/m3e_design_system_static_test.dart`，跳过这些文件）与 Apple
/// 令牌守卫（`test/settings/apple_design_tokens_guard_test.dart`，只扫这些文件）
/// 共用。两边判据必须一致：否则一份文件会同时落在两个守卫外，或被两套规则夹击。
///
/// 约定：这类文件只在 `isGlassDesign(context)` 分派后的 Apple 分支里渲染，没有
/// M3E 外观。M3E 与 Apple 混写的文件不算，仍由 M3E 守卫逐个审。
library;

/// 文件名里带 `apple` 词元、但说的是 Apple **服务 / 平台**而不是 Apple 设计系统
/// 的命名空间：这些文件在 M3E 下同样渲染（或根本不渲染），不能当 Apple 专属。
const Set<String> kAppleNonDesignNamePrefixes = <String>{
  // Apple Music 服务（登录页、桥接、收藏、输出后端；两套设计系统下都可见）。
  'apple_music',
  // Apple 系统语音转写（平台通道 / 宿主服务，无 UI）。
  'apple_speech',
  // iOS / macOS 桌面小组件宿主（平台桥，无 UI）。
  'apple_widgets',
};

/// [path]（仓库内相对路径，`/` 分隔，如 `lib/src/.../x.dart`）是不是 Apple 设计
/// 系统专属文件：
/// - 路径里有 `/apple/` 目录（各模块的 Cupertino 版面，如 `srs/apple/`）；或
/// - 文件名带 `apple` 词元（`apple_*.dart`、`*_apple.dart`、`*_apple.part.dart`、
///   `fushi_apple_*`），且这个词元不是 [kAppleNonDesignNamePrefixes] 里的服务名，
///   也不在服务目录（`/apple_music/`）里。
bool isAppleDesignOnlySource(String path) {
  final String normalized = path.replaceAll(r'\', '/');
  if (normalized.contains('/apple/')) return true;
  for (final String service in kAppleNonDesignNamePrefixes) {
    if (normalized.contains('/$service/')) return false;
  }
  final String name = normalized.substring(normalized.lastIndexOf('/') + 1);
  for (final RegExpMatch match in RegExp(
    r'(?:^|_)apple(?=[_.])',
  ).allMatches(name)) {
    final String rest = name.substring(match.end);
    final bool service = kAppleNonDesignNamePrefixes.any(
      (String prefix) => 'apple$rest'.startsWith(prefix),
    );
    if (!service) return true;
  }
  return false;
}
