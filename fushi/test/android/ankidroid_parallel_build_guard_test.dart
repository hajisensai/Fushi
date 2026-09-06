import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-2195：AnkiDroid 并行版（`com.ichi2.anki.A` 等）支持的源码守卫。
///
/// 为什么需要守卫而不是只靠单测：这条链路的关键事实全在 **Java 源码和
/// AndroidManifest** 里，而本仓库的 Android 侧没有 JVM 单测基建（历史上同类不变式
/// 也都是用源码扫描钉的，见 `anki_native_createmodel_guard_test.dart`）。
///
/// 三条不变式：
///  1. 候选包清单与 manifest 的 `<queries>` / `<uses-permission>` **逐条对应**。
///     漏一条 = 那个并行版在 Android 11+ 上恒不可见，权限框永远不弹——正是本 bug。
///  2. 可用性判断不得回到 `AddContentApi.getAnkiDroidPackageName`（它按写死的主包
///     authority 解析）。
///  3. 我们自己发出去的 provider URI 与 `grantUriPermission` 不得写死主包。
void main() {
  final Directory javaDir = Directory(
    'android/app/src/main/java/app/fushi/reader',
  );
  String java(String name) =>
      maskComments(File('${javaDir.path}/$name').readAsStringSync());
  String javaRaw(String name) =>
      File('${javaDir.path}/$name').readAsStringSync();

  final String manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

  /// 从 `AnkiDroidTarget.CANDIDATE_PACKAGES` 里把候选包名读出来。
  List<String> candidatePackages() {
    final String source = java('AnkiDroidTarget.java');
    final int start = source.indexOf('CANDIDATE_PACKAGES');
    expect(start, greaterThan(-1),
        reason: 'AnkiDroidTarget 必须有 CANDIDATE_PACKAGES 清单');
    final int open = source.indexOf('{', start);
    final int close = source.indexOf('}', open);
    final String body = source.substring(open + 1, close);
    final List<String> packages = <String>[];
    for (final String raw in body.split(',')) {
      final String entry = raw.trim();
      if (entry.isEmpty) continue;
      if (entry == 'MAIN_PACKAGE') {
        packages.add('com.ichi2.anki');
        continue;
      }
      final RegExpMatch? m =
          RegExp(r'MAIN_PACKAGE\s*\+\s*"([^"]+)"').firstMatch(entry);
      expect(m, isNotNull, reason: '看不懂的候选项：$entry');
      packages.add('com.ichi2.anki${m!.group(1)}');
    }
    return packages;
  }

  test('候选包清单非空，且主包排第一', () {
    final List<String> packages = candidatePackages();
    expect(packages.length, greaterThanOrEqualTo(6),
        reason: '至少要覆盖主包 + 官方并行版 A–E');
    expect(packages.first, 'com.ichi2.anki',
        reason: '同时装了主包和并行版时，主包必须先命中（与修复前行为一致）');
    expect(packages.toSet().length, packages.length, reason: '候选不得重复');
  });

  test('每个候选包都在 manifest 的 <queries> 里声明了包可见性', () {
    for (final String pkg in candidatePackages()) {
      expect(
        manifest.contains('<package android:name="$pkg" />'),
        isTrue,
        reason: '$pkg 没有 <queries> 声明：Android 11+ 上 resolveContentProvider '
            '查不到它，isApiAvailable 恒 false，权限框一次都不会弹',
      );
    }
  });

  test('每个候选包的读写权限都单独声明了', () {
    for (final String pkg in candidatePackages()) {
      expect(
        manifest.contains(
          '<uses-permission android:name="$pkg.permission.READ_WRITE_DATABASE"/>',
        ),
        isTrue,
        reason: '$pkg 定义的是它自己那个带后缀的权限；只声明主包那一个时，'
            '即便包可见，requestPermissions 也会静默判拒',
      );
    }
  });

  test('可用性判断不得回到写死主包 authority 的 getAnkiDroidPackageName', () {
    final String helper = java('AnkiDroidHelper.java');
    expect(helper.contains('AnkiDroidTarget.resolve('), isTrue,
        reason: 'isApiAvailable 必须走逐候选探测');
    expect(helper.contains('AddContentApi.getAnkiDroidPackageName'), isFalse,
        reason: '它只认写死的 com.ichi2.anki.flashcards，并行版恒 null');
  });

  test('权限名按解析出的目标拼，不用 AAR 的写死常量', () {
    final String helper = java('AnkiDroidHelper.java');
    expect(helper.contains('readWritePermission()'), isTrue);
    // 三个用到权限名的地方（检查 / 申请 / rationale）都必须走那个方法。
    expect(
      RegExp(r'readWritePermission\(\)').allMatches(helper).length,
      greaterThanOrEqualTo(4),
      reason: 'checkSelfPermission / requestPermissions / '
          'shouldShowRequestPermissionRationale 三处 + 定义本身',
    );
  });

  test('grantUriPermission 授给解析出的包，不写死主包', () {
    final String handler = java('AnkiChannelHandler.java');
    expect(handler.contains('context.grantUriPermission("com.ichi2.anki"'),
        isFalse,
        reason: '写死主包时并行版拿不到媒体 URI 的读权限，插入必失败');
    expect(
        handler.contains('grantUriPermission(mediaTarget.packageName'), isTrue);
  });

  test('我们自己发的 provider URI 都重挂过 authority', () {
    final String handler = java('AnkiChannelHandler.java');
    // 契约常量里的 CONTENT_URI 带的是写死的主包 authority；凡是直接交给
    // ContentResolver 的，都必须先过 rebase。
    final Iterable<RegExpMatch> inserts =
        RegExp(r'resolver\.insert\(|contentResolver\.insert\(')
            .allMatches(handler);
    expect(inserts.isNotEmpty, isTrue);
    expect(handler.contains('.rebase('), isTrue,
        reason: 'AnkiMedia.CONTENT_URI 必须重挂 authority');
  });

  test('两个 provider 实现都存在，主包那条仍是纯委托', () {
    expect(File('${javaDir.path}/AddContentApiProvider.java').existsSync(),
        isTrue);
    expect(
        File('${javaDir.path}/DirectAnkiProvider.java').existsSync(), isTrue);
    final String delegating = java('AddContentApiProvider.java');
    // 纯委托的判据：没有 ContentResolver、没有 Cursor —— 一旦有人在这里写逻辑，
    // 「支持并行版不碰主包路径」这条保证就没了。
    expect(delegating.contains('ContentResolver'), isFalse,
        reason: '主包实现必须是对 AddContentApi 的直白转发，不许有自己的查询逻辑');
    expect(delegating.contains('Cursor'), isFalse);
  });

  test('并行版实现不得残留写死的主包 authority', () {
    final String direct = javaRaw('DirectAnkiProvider.java');
    // 注释里允许出现（说明为什么要有这个类），代码里不许。
    final String code = java('DirectAnkiProvider.java');
    expect(code.contains('com.ichi2.anki.flashcards'), isFalse);
    expect(code.contains('target.rebase('), isTrue);
    expect(direct.contains('FIELD_SEPARATOR'), isTrue,
        reason: 'Anki 的字段分隔符是 0x1f，必须有单一常量而不是散落的字面量');
  });
}
