import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：桌面 sidecar 与 Android 宿主提供给 Mihon 扩展的 ABI 版本必须一致。
///
/// 为什么需要这条守卫（实测事故，不是假想）：Mihon 扩展 APK 把宿主提供的一切
/// （Kotlin 运行时、coroutines、okhttp、jsoup、rx、source-api……）都当 compileOnly，
/// dex 里只留**引用**、不带定义，运行期由宿主解析。于是宿主给的版本一旦落后于
/// 扩展编译时链接的版本，就会在调用点直接 `NoSuchMethodError`。
///
/// 真实事故：Android 宿主用 kotlinx-coroutines `1.11.0`，桌面 sidecar 的 vendored
/// `libs.versions.toml` 停在 `1.10.2`。keiyoushi 的 rawkuma 扩展调用
/// `kotlinx.coroutines.BuildersKt.runBlockingK`——这个方法 1.11.0 才有，1.10.2 只有
/// `runBlocking` / `runBlocking$default`。结果桌面端每次打开搜索都 500：
///
///     java.lang.NoSuchMethodError: 'java.lang.Object
///       kotlinx.coroutines.BuildersKt.runBlockingK(...)'
///       at ...extension.ja.rawkuma.ExtensionGenerated.getFilterList(Unknown Source)
///       at mextensionserver.impl.MihonInvoker.invokeFiltersManga(MihonInvoker.kt:178)
///
/// 而 Android 端同一个扩展完全正常——**这类漂移天然只在一个平台上暴露**，两边的
/// 依赖声明又分处两个文件、互不知情，所以只能靠静态守卫锁住。
///
/// 症状还特别容易被误判成「网站挂了」：`getFilterList()` 只在**搜索**路径上被调用
/// （`MihonInvoker.kt:178` 与 `:223`），浏览热门/最新不碰它。用户看到的就是
/// 「浏览正常、一搜就报错」。
void main() {
  group('Mihon 宿主 ABI 版本对齐（桌面 sidecar ↔ Android 宿主）', () {
    late final File androidGradle = File('android/app/build.gradle');
    late final File sidecarVersions =
        File('../third_party/m_extension_server/upstream_src/gradle/libs.versions.toml');
    late final File sidecarPatch =
        File('../third_party/m_extension_server/server-build.gradle.patch');

    test('三个真相源文件都在（挪位置要同步改本守卫）', () {
      for (final File file in <File>[
        androidGradle,
        sidecarVersions,
        sidecarPatch,
      ]) {
        expect(
          file.existsSync(),
          isTrue,
          reason: '找不到 ${file.path}；文件挪位置了就必须同步更新这条守卫。',
        );
      }
    });

    test('共享 ABI 依赖两边同版本', () {
      final Map<String, String> sidecar = _effectiveSidecarVersions(
        sidecarVersions.readAsStringSync(),
        sidecarPatch.readAsStringSync(),
      );
      final Map<String, String> android =
          _androidArtifactVersions(androidGradle.readAsStringSync());

      final List<String> mismatches = <String>[];
      _sharedAbi.forEach((String label, _SharedAbi entry) {
        final String? desktop = sidecar[entry.sidecarKey];
        final String? mobile = android[entry.androidArtifact];
        if (desktop == null) {
          mismatches.add('$label: sidecar 侧解析不出 ${entry.sidecarKey} 的版本');
          return;
        }
        if (mobile == null) {
          mismatches.add('$label: Android 侧解析不出 ${entry.androidArtifact} 的版本');
          return;
        }
        if (desktop != mobile) {
          mismatches.add(
            '$label: 桌面 sidecar=$desktop，Android 宿主=$mobile'
            '（${entry.androidArtifact}）',
          );
        }
      });

      expect(
        mismatches,
        isEmpty,
        reason: '桌面 sidecar 与 Android 宿主提供给扩展的 ABI 版本漂移了：\n'
            '${mismatches.join('\n')}\n\n'
            '扩展只带引用不带定义，宿主版本落后就会在调用点 NoSuchMethodError，'
            '而且只在落后的那一端暴露。改法：在 '
            'third_party/m_extension_server/server-build.gradle.patch 的 '
            'libs.versions.toml hunk 里对齐版本（补丁必须带上下文，见 BUG-1428），'
            '或同步调整 android/app/build.gradle。两边动完都要重建 sidecar。',
      );
    });
  });
}

/// 桌面 sidecar 的**有效**版本：vendored 上游 `libs.versions.toml` 的值，再让
/// Hibiki 补丁里对该文件的 `+` 行覆盖。
///
/// 只认补丁里 `libs.versions.toml` 那一段——同一个补丁还改 `build.gradle.kts` 和
/// Kotlin 源码，不隔离的话 `+coroutines = ...` 会被别处同名行污染。
Map<String, String> _effectiveSidecarVersions(String toml, String patch) {
  final Map<String, String> versions = <String, String>{};

  // [versions] 段的 `name = "1.2.3"`
  bool inVersions = false;
  for (final String line in const LineSplitter().convert(toml)) {
    final String trimmed = line.trim();
    if (trimmed.startsWith('[')) {
      inVersions = trimmed == '[versions]';
      continue;
    }
    if (inVersions) {
      final String? entry = _versionEntry(trimmed);
      if (entry != null) versions[entry] = _versionValue(trimmed)!;
    } else {
      // 裸坐标行，如 `jsoup = "org.jsoup:jsoup:1.21.2"`
      final RegExpMatch? coordinate =
          RegExp(r'^(\w[\w.-]*)\s*=\s*"([^":]+:[^":]+):([^"]+)"').firstMatch(trimmed);
      if (coordinate != null) {
        versions[coordinate.group(1)!] = coordinate.group(3)!;
      }
    }
  }

  for (final String line in _patchAddedLines(patch, 'gradle/libs.versions.toml')) {
    final String trimmed = line.trim();
    final String? entry = _versionEntry(trimmed);
    if (entry != null) {
      versions[entry] = _versionValue(trimmed)!;
      continue;
    }
    final RegExpMatch? coordinate =
        RegExp(r'^(\w[\w.-]*)\s*=\s*"([^":]+:[^":]+):([^"]+)"').firstMatch(trimmed);
    if (coordinate != null) versions[coordinate.group(1)!] = coordinate.group(3)!;
  }
  return versions;
}

String? _versionEntry(String trimmed) {
  final RegExpMatch? match =
      RegExp(r'^(\w[\w.-]*)\s*=\s*"([^":]+)"\s*(#.*)?$').firstMatch(trimmed);
  return match?.group(1);
}

String? _versionValue(String trimmed) {
  final RegExpMatch? match =
      RegExp(r'^(\w[\w.-]*)\s*=\s*"([^":]+)"\s*(#.*)?$').firstMatch(trimmed);
  return match?.group(2);
}

/// 取统一 diff 中指定目标文件那一段里的新增行（去掉前导 `+`），跳过 `+++` 文件头。
List<String> _patchAddedLines(String patch, String targetPath) {
  final List<String> added = <String>[];
  bool inTarget = false;
  for (final String line in const LineSplitter().convert(patch)) {
    if (line.startsWith('diff --git ')) {
      inTarget = line.contains(' b/$targetPath');
      continue;
    }
    if (!inTarget) continue;
    if (line.startsWith('+++') || line.startsWith('---')) continue;
    if (line.startsWith('+')) added.add(line.substring(1));
  }
  return added;
}

/// Android 宿主 `implementation 'group:artifact:version'` → `group:artifact` 到版本。
Map<String, String> _androidArtifactVersions(String gradle) {
  final Map<String, String> artifacts = <String, String>{};
  final RegExp pattern = RegExp(
    r'''implementation\s+['"]([^'":]+:[^'":]+):([^'"]+)['"]''',
  );
  for (final RegExpMatch match in pattern.allMatches(gradle)) {
    artifacts[match.group(1)!] = match.group(2)!;
  }
  return artifacts;
}

class _SharedAbi {
  const _SharedAbi(this.sidecarKey, this.androidArtifact);

  /// `libs.versions.toml` 里的 key（[versions] 条目名或裸坐标条目名）。
  final String sidecarKey;

  /// Android `build.gradle` 里的 `group:artifact`。
  final String androidArtifact;
}

/// 两边都提供给扩展、且版本必须一致的 ABI 面。
///
/// 只列**扩展会直接引用**的运行时库；sidecar 独有的服务端依赖（javalin/jackson/
/// logback/dex2jar…）不在此列，Android 那边根本没有对应物。
const Map<String, _SharedAbi> _sharedAbi = <String, _SharedAbi>{
  'kotlinx-coroutines': _SharedAbi(
    'coroutines',
    'org.jetbrains.kotlinx:kotlinx-coroutines-android',
  ),
  'kotlinx-serialization': _SharedAbi(
    'serialization',
    'org.jetbrains.kotlinx:kotlinx-serialization-json',
  ),
  'okhttp': _SharedAbi('okhttp', 'com.squareup.okhttp3:okhttp'),
  'jsoup': _SharedAbi('jsoup', 'org.jsoup:jsoup'),
  'rxjava': _SharedAbi('rxjava', 'io.reactivex:rxjava'),
};
