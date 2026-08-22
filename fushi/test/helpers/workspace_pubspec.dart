import 'dart:io';

/// vendored 依赖「是否真的被接线」的单一判据来源。
///
/// 迁到 Pub workspace 之前，接线只有一种写法：`fushi/pubspec.yaml` 的
/// `dependency_overrides` 里一条 `path:`。守卫因此直接 `File('pubspec.yaml')`
/// 读 fushi 自己的 pubspec 去 contains 字符串。
///
/// workspace 之后有**两种**接线，都在仓库根的 pubspec.yaml 里：
///   1. `dependency_overrides:` —— 顶替 pub.dev 上的包（third_party/* 那批）。
///      workspace 只认根的 overrides，写在成员包里 pub 会直接拒绝。
///   2. `workspace:` 成员 —— 包名就是被顶替的上游包名时（
///      flutter_inappwebview_windows / gamepads_windows /
///      packages/gamepads_android_stub 的包名是 gamepads_android），成员身份
///      天然优先于 pub.dev 版本，再写 override 反而报
///      "Cannot override workspace packages."
///
/// 守卫要守的不变量是「用的是我们 vendored 的那份源码」，不是某一种 YAML 写法。
/// 这里把两种接线都解析出来，避免每个守卫各自 contains 一个字符串——那样下次
/// 接线方式再变，一批守卫会同时红，而它们守的东西其实一个都没坏。
class WorkspacePubspec {
  WorkspacePubspec._(this.raw, this.overridePaths, this.members);

  /// 仓库根 pubspec.yaml 的原文。
  final String raw;

  /// `dependency_overrides` 里 name -> path 的映射（只收 path 型 override）。
  final Map<String, String> overridePaths;

  /// `workspace:` 列出的成员路径（相对仓库根，如 `packages/gamepads_windows`）。
  final List<String> members;

  /// 测试的 cwd 是 `fushi/`，仓库根在上一级。
  static WorkspacePubspec load({String path = '../pubspec.yaml'}) {
    final String text = File(path).readAsStringSync();
    return WorkspacePubspec._(
      text,
      _parseOverridePaths(text),
      _parseMembers(text),
    );
  }

  /// vendored 包是否生效：要么是 workspace 成员，要么有指向该路径的 override。
  bool isVendored(String packageName, String repoRelativePath) {
    if (members.contains(repoRelativePath)) return true;
    final String? p = overridePaths[packageName];
    return p != null && p == repoRelativePath;
  }

  static Map<String, String> _parseOverridePaths(String text) {
    final Map<String, String> out = <String, String>{};
    final List<String> lines = text.split('\n');
    bool inSection = false;
    String? pending;
    for (final String line in lines) {
      if (line.startsWith('dependency_overrides:')) {
        inSection = true;
        continue;
      }
      if (!inSection) continue;
      // 段落在下一个顶格 key 处结束（注释和空行不算）。
      if (line.isNotEmpty &&
          !line.startsWith(' ') &&
          !line.startsWith('#') &&
          !line.startsWith('\t')) {
        break;
      }
      final RegExpMatch? name = RegExp(
        r'^  ([A-Za-z_][A-Za-z0-9_]*):\s*$',
      ).firstMatch(line);
      if (name != null) {
        pending = name.group(1);
        continue;
      }
      final RegExpMatch? p = RegExp(r'^    path:\s*(\S+)\s*$').firstMatch(line);
      if (p != null && pending != null) {
        out[pending] = p.group(1)!;
        pending = null;
      }
    }
    return out;
  }

  static List<String> _parseMembers(String text) {
    final List<String> out = <String>[];
    final List<String> lines = text.split('\n');
    bool inSection = false;
    for (final String line in lines) {
      if (line.startsWith('workspace:')) {
        inSection = true;
        continue;
      }
      if (!inSection) continue;
      final RegExpMatch? m = RegExp(r'^  - (\S+)\s*$').firstMatch(line);
      if (m != null) {
        out.add(m.group(1)!);
        continue;
      }
      if (line.trim().isEmpty ||
          line.startsWith('#') ||
          line.startsWith('  #')) {
        continue;
      }
      break;
    }
    return out;
  }
}
