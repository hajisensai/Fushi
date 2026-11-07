// 守卫：Mihon 桌面 runtime 构建期的 Android 桩 jar 必须钉在不可变的 commit 上。
//
// 背景（2026-11-03 实测）：`com.github.Suwayomi:android-jar:1.0.0` 是**可变坐标**——
// Suwayomi 每当自家 AndroidCompat 接管一个类，就在 android-jar 分支上重发同一个
// 1.0.0 jar 并删掉那个桩。2026-11-01（Suwayomi-Server 6830765f）删掉了
// android.net.Network / NetworkRequest / NetworkCapabilities，而本仓 vendored 的
// AndroidCompat `ConnectivityManager.java` 仍按它们编译：macOS job 的 runtime 缓存
// 一失效、从源码重编，就是 67 个 `cannot find symbol`（run 41634186830）。
// 桩 jar 还被 shadow 进 sidecar jar，字节漂移同时改了随包的运行时。
//
// 本守卫盯住两类回归：
//   ① 补丁里重新出现按分支名解析的仓库 URL（`.../raw/android-jar/`）；
//   ② android-jar 不再走 exclusiveContent，或钉的不是 40 位 commit SHA。
import 'dart:io';

import 'package:test/test.dart';

/// 仓库根（测试从 `fushi/` 下跑，与本目录其它 build 守卫同约定）。
const String _patchPath =
    '../third_party/m_extension_server/server-build.gradle.patch';

void main() {
  final String patch = File(_patchPath).readAsStringSync();
  final List<String> addedLines = patch
      .split('\n')
      .where((String line) => line.startsWith('+') && !line.startsWith('+++'))
      .toList();
  final String added = addedLines.join('\n');

  test('补丁删掉了按分支名解析 android-jar 的可变仓库', () {
    expect(
      patch.contains(
        '-        maven("https://github.com/Suwayomi/Suwayomi-Server/raw/android-jar/")',
      ),
      isTrue,
      reason:
          '上游 build.gradle.kts 的 `.../raw/android-jar/` 仓库必须被补丁删掉：'
          '它解析的是分支尖端，Suwayomi 随时重发 1.0.0 并删桩。',
    );
    expect(
      addedLines.any((String line) => line.contains('/raw/android-jar/')),
      isFalse,
      reason: '补丁不得重新加回按分支名解析的 android-jar 仓库。',
    );
  });

  test('android-jar 只从 commit SHA 钉死的仓库解析', () {
    final RegExp pinnedRepo = RegExp(
      r'maven\("https://raw\.githubusercontent\.com/Suwayomi/Suwayomi-Server/'
      r'([0-9a-f]{40})/"\)',
    );
    final RegExpMatch? match = pinnedRepo.firstMatch(added);
    expect(
      match,
      isNotNull,
      reason: 'android-jar 仓库必须是 raw.githubusercontent.com/<40 位 SHA>/ 形式。',
    );
    expect(
      added.contains('exclusiveContent {'),
      isTrue,
      reason: '必须用 exclusiveContent，否则 jitpack 等仓库仍可能先命中同名坐标。',
    );
    expect(
      added.contains(
        'filter { includeModule("com.github.Suwayomi", "android-jar") }',
      ),
      isTrue,
      reason:
          'exclusiveContent 的 filter 必须精确到 com.github.Suwayomi:android-jar。',
    );
  });
}
