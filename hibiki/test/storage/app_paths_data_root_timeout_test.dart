import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/storage/app_paths.dart';

import '../helpers/source_guard.dart';

/// TODO-1260 / BUG-815：自定义数据根**掉线盘**的启动契约。
///
/// TODO-1260（旧）：同步 `existsSync()` 在掉线盘上阻塞主 isolate 到 OS 超时 → 无限加载。
/// 修复改用带 2s 超时的异步 `exists()`，绝不 hang。
///
/// BUG-815（新契约）：修复前，探测失败就**静默退回 `path_provider` 默认根**打开空库——
/// 用户看到「全空」误以为数据被清空（其真实数据其实原封不动躺在配置盘上），甚至在空态里
/// 把新内容写进错误位置。现改为：**配置了自定义根但不可达 → `resolve()` 抛
/// [DataRootUnavailableException]**（UI 显逃生屏，绝不静默把空当真）；只有用户**显式**选择
/// （置 [AppPaths.forceDefaultRootForSession]）才退回默认根。无自定义根的普通用户不受影响。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory fakeTemp;

  /// BUG-1115：默认 documents 根 = `<平台 Documents>/Hibiki/data`。本文件 mock 的 support
  /// 根下没有 `hibiki.db`，故 resolve() 一律判为**全新安装** → 新布局。
  String nestedDefaultDocs() => p.joinAll(<String>[
        p.join(tmp.path, 'default_documents'),
        ...AppPaths.defaultDocumentsChildSegments,
      ]);

  setUp(() {
    AppPaths.debugResetDocumentsLayoutCache();
    tmp = Directory.systemTemp.createTempSync('hibiki_dataroot_timeout_');
    fakeTemp = Directory(p.join(tmp.path, 'systemp'))..createSync();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async {
        if (call.method == 'getTemporaryDirectory') return fakeTemp.path;
        if (call.method == 'getApplicationSupportDirectory') {
          return p.join(tmp.path, 'default_support');
        }
        if (call.method == 'getApplicationDocumentsDirectory') {
          return p.join(tmp.path, 'default_documents');
        }
        return null;
      },
    );
  });

  tearDown(() {
    AppPaths.debugDataRootReader = null;
    AppPaths.debugResetDocumentsLayoutCache();
    // 静态开关必须每个 test 复位，否则跨 test 泄漏（一个 test 置 true 会污染后续）。
    AppPaths.forceDefaultRootForSession = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test(
      '配置了自定义根但不可达 → resolve() 抛 DataRootUnavailableException，不静默回退空默认根，且快速返回不 hang (BUG-815)',
      () async {
    final String missing = p.join(tmp.path, 'offline_drive_root');
    AppPaths.debugDataRootReader = () async => missing;

    final Stopwatch sw = Stopwatch()..start();
    await expectLater(
      AppPaths.resolve(),
      throwsA(
        isA<DataRootUnavailableException>().having(
            (DataRootUnavailableException e) => e.configuredPath,
            'configuredPath',
            missing),
      ),
      reason: '配置了自定义根但不可达时必须抛异常让 UI 决策，绝不静默派生空默认根（数据全空观感）',
    );
    sw.stop();
    // 关键：探测必须在 2s 超时 + 合理裕量内返回（抛出），绝不因坏根卡死主 isolate。
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)),
        reason: '坏 / 掉线数据根必须被超时降级，不得让 resolve() 无限阻塞');
  });

  test('配置不可达 + 用户显式选择用默认位置 (forceDefaultRootForSession) → 退回默认根，不抛 (BUG-815)',
      () async {
    final String missing = p.join(tmp.path, 'offline_drive_root');
    AppPaths.debugDataRootReader = () async => missing;
    // 用户在逃生屏点「仍用默认位置启动」。
    AppPaths.forceDefaultRootForSession = true;

    final AppPaths paths = await AppPaths.resolve();
    expect(paths.documentsRoot.path, equals(nestedDefaultDocs()),
        reason: '用户显式选择后应退回默认根打开（空态），而不是抛异常');
    expect(paths.supportRoot.path, equals(p.join(tmp.path, 'default_support')));
  });

  test('未配置自定义根（普通默认用户）→ 不抛，正常用默认根', () async {
    AppPaths.debugDataRootReader = () async => null;
    final AppPaths paths = await AppPaths.resolve();
    expect(paths.documentsRoot.path, equals(nestedDefaultDocs()),
        reason: '无自定义根配置的用户不受 BUG-815 预检影响');
  });

  test('data_root 存在 → 正常派生（超时降级不误伤正常根）', () async {
    final Directory dataRoot = Directory(p.join(tmp.path, 'GoodRoot'))
      ..createSync(recursive: true);
    AppPaths.debugDataRootReader = () async => dataRoot.path;

    final AppPaths paths = await AppPaths.resolve();
    expect(
        paths.documentsRoot.path, equals(p.join(dataRoot.path, 'documents')));
    expect(paths.supportRoot.path, equals(p.join(dataRoot.path, 'support')));
  });

  test('源码守卫：数据根存在性探测不得再用阻塞式 existsSync()，必须走带超时的异步 exists()', () {
    final File? f = <String>[
      'lib/src/storage/app_paths.dart',
      'hibiki/lib/src/storage/app_paths.dart',
    ].map(File.new).cast<File?>().firstWhere(
        (File? f) => f != null && f.existsSync(),
        orElse: () => null);
    expect(f, isNotNull, reason: 'app_paths.dart not found');
    final String src = f!.readAsStringSync();

    // 先把注释换成**等长空白**（共享 `maskComments`）再定位与切片：注释里会
    // **提到** existsSync 解释旧代码为何被换掉，连注释一起扫会误红；反过来旧的
    // 行式剥离（只丢整行 `//`）放过块注释与行尾注释，把 `.exists().timeout(` 塞进
    // `/* */` 就能把下面那条要求型断言骗绿。等长掩码同时保证下标仍对齐原文。
    final String code = maskComments(src);

    // 抽出 _probeDataRootExists **函数定义体**做定向断言（锚定 signature，避免抓到
    // resolve() 里的调用点；也避免误伤其它无关 existsSync 用法）。
    final int start = code.indexOf('static Future<bool> _probeDataRootExists(');
    expect(start, greaterThanOrEqualTo(0),
        reason: '找不到 _probeDataRootExists 定义 —— 探测函数被改名/移除？');
    // 到下一个静态解析函数（_resolveDataRoot 定义）为止的片段。
    final int end =
        code.indexOf('static Future<Directory?> _resolveDataRoot(', start);
    final String body = code.substring(start, end < 0 ? code.length : end);

    expect(body.contains('existsSync()'), isFalse,
        reason: '掉线盘上同步 existsSync() 会阻塞主 isolate → 无限加载，禁止回归');
    expect(RegExp(r'\.exists\(\)\s*\.timeout\(').hasMatch(body), isTrue,
        reason: '必须用带超时的异步 exists().timeout(...) 探测数据根');
  });
}
