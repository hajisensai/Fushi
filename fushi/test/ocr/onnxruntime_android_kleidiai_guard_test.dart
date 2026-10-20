// BUG-3622 守卫：Android 的 ONNX Runtime 不得回到会在 SME-only CPU 上 SIGILL 的版本，
// 且每个 Android 会话都必须关掉 KleidiAI。
//
// 崩溃形状：realme GT 8 Pro（骁龙 8 Elite Gen 5，Oryon 核只有 SME、没有 SME2）上，
// `OrtSession.run` 在 `libonnxruntime.so` 里 SIGILL ILL_ILLOPC。onnxruntime-android
// 1.23.0（BuildId 34a68042…）的 MLAS 只看 CPU 有没有 SME 就选 KleidiAI 的 SME2 内核，
// 崩溃 PC 反汇编是 `smstart` 之后的 `whilelt pn8.h, x11, x24, vlx2`——predicate-as-counter
// 是 SME2 专有指令（上游 microsoft/onnxruntime#26377，修复 PR #27403）。
//
// 只升版本不够：1.28.0 按 SME/SME2 分派内核了，但 KleidiAI MatMul 仍按每线程见过的最大
// 输入形状滞留缓冲、永不归还（microsoft/onnxruntime#29538，1.28.0 上实测 GB 级），而 OCR
// 正是动态形状。所以 Android 插件对每个会话设 `mlas.disable_kleidiai=1`，让 SME 机型与其它
// Android 机走同一条 NEON MLAS 路径。这个配置键 1.25 才有，1.23.0 里设了也无效。
//
// 这类回归在本仓任何 CI 机器和非 SME 手机上都看不出来（KleidiAI 只在 SME 设备上启用），
// 只能在源码层钉住。清理条件：上游修掉 #29538 且在 SME-only 设备上验证过 KleidiAI 路径后，
// 才可以去掉配置项。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 从当前 cwd 向上找含 `third_party/flutter_onnxruntime` 的仓库根。
Directory _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 6; i++) {
    if (Directory('${dir.path}/third_party/flutter_onnxruntime').existsSync()) {
      return dir;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail(
    '找不到含 third_party/flutter_onnxruntime 的仓库根'
    '（从 ${Directory.current.path} 向上）',
  );
}

/// 把 `X.Y.Z` 解析成可比较的三元组；解析不了返回 null。
List<int>? _parseVersion(String version) {
  final RegExpMatch? m = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(version);
  if (m == null) return null;
  return <int>[
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
  ];
}

int _compareVersion(List<int> a, List<int> b) {
  for (int i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return 0;
}

/// 读出 Android 插件 build.gradle 里钉的 onnxruntime-android 版本。
String _androidOrtVersion(Directory root) {
  final File gradle = File(
    '${root.path}/third_party/flutter_onnxruntime/android/build.gradle',
  );
  final List<RegExpMatch> pins = RegExp(
    r"""^\s*implementation\s+['"]com\.microsoft\.onnxruntime:onnxruntime-android:([^'"]+)['"]""",
    multiLine: true,
  ).allMatches(gradle.readAsStringSync()).toList();
  expect(
    pins,
    hasLength(1),
    reason: '${gradle.path} 里应当恰好一条 onnxruntime-android 依赖',
  );
  return pins.single.group(1)!;
}

void main() {
  late Directory root;

  setUpAll(() {
    root = _repoRoot();
  });

  test('onnxruntime-android 版本在 [1.28.0, 1.29.0) 内', () {
    final String version = _androidOrtVersion(root);
    final List<int>? parsed = _parseVersion(version);
    expect(parsed, isNotNull, reason: '版本号 "$version" 不是 X.Y.Z');
    expect(
      _compareVersion(parsed!, <int>[1, 28, 0]),
      greaterThanOrEqualTo(0),
      reason:
          'onnxruntime-android $version < 1.28.0：1.23.x 在 SME-only CPU（骁龙 8 Elite '
          'Gen 5）上跑 KleidiAI SME2 内核直接 SIGILL（BUG-3622），1.27.0 在同一颗芯片上'
          '还会静默算错；`mlas.disable_kleidiai` 也要 1.25 起才认。',
    );
    expect(
      _compareVersion(parsed, <int>[1, 29, 0]),
      lessThan(0),
      reason:
          'onnxruntime-android $version >= 1.29.0：1.29 起官方 Android 包默认发送遥测'
          '（microsoft/onnxruntime#27379 / #29872）。真要升，先确认遥测已关、再改本守卫。',
    );
  });

  test('Android 插件在 createSession 之前对每个会话关掉 KleidiAI', () {
    final File plugin = File(
      '${root.path}/third_party/flutter_onnxruntime/android/src/main/kotlin/'
      'com/masicai/flutteronnxruntime/FlutterOnnxruntimePlugin.kt',
    );
    final String source = plugin.readAsStringSync();

    expect(
      source,
      contains('const val DISABLE_KLEIDIAI_KEY = "mlas.disable_kleidiai"'),
      reason: '配置键常量被改名或改值；ORT 只认 "mlas.disable_kleidiai"',
    );

    final int handler = source.indexOf('"createSession" ->');
    expect(handler, isNot(-1), reason: '找不到 createSession 分支');
    final int optionsAt = source.indexOf(
      'OrtSession.SessionOptions()',
      handler,
    );
    final int configAt = source.indexOf(
      'ortSessionOptions.addConfigEntry(DISABLE_KLEIDIAI_KEY, "1")',
      handler,
    );
    final int createAt = source.indexOf(
      'ortEnvironment.createSession(',
      handler,
    );
    expect(
      optionsAt,
      isNot(-1),
      reason: 'createSession 分支里没有新建 SessionOptions',
    );
    expect(
      createAt,
      isNot(-1),
      reason: 'createSession 分支里没有 ortEnvironment.createSession',
    );
    expect(
      configAt,
      allOf(greaterThan(optionsAt), lessThan(createAt)),
      reason:
          'createSession 分支必须在新建 SessionOptions 之后、ortEnvironment.createSession '
          '之前设 mlas.disable_kleidiai=1（BUG-3622；理由见本文件头）',
    );
  });

  test('许可证清单的 Android ONNX Runtime 条目与 build.gradle 同版本', () {
    final String version = _androidOrtVersion(root);
    final Object? manifest = jsonDecode(
      File(
        '${root.path}/native/third_party_licenses/manifest.json',
      ).readAsStringSync(),
    );
    final List<Map<String, Object?>> androidOrt = <Map<String, Object?>>[];
    void visit(Object? node) {
      if (node is Map<String, Object?>) {
        final Object? platforms = node['platforms'];
        if (node['name'] == 'ONNX Runtime' &&
            platforms is List<Object?> &&
            platforms.contains('android')) {
          androidOrt.add(node);
        }
        node.values.forEach(visit);
      } else if (node is List<Object?>) {
        node.forEach(visit);
      }
    }

    visit(manifest);
    expect(
      androidOrt,
      hasLength(1),
      reason: 'manifest.json 里应当恰好一条 platforms 含 android 的 ONNX Runtime 条目',
    );
    expect(
      androidOrt.single['version'],
      version,
      reason:
          '升级 onnxruntime-android 后要同步 native/third_party_licenses/manifest.json，'
          '再跑 `dart run tool/native_licenses.dart` 重生成 index.json',
    );
  });
}
