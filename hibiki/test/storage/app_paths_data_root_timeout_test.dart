import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/storage/app_paths.dart';

/// TODO-1260：自定义数据根**掉线盘**的超时降级契约（app 偶发无限加载根因之一）。
///
/// 旧代码用同步 `existsSync()` 探测 data_root——盘掉线时它在主 isolate 上阻塞到 OS 超时
/// （Windows 对断链网络盘可达数十秒），启动期又无逃生口 → 无限加载。修复改用带 2s 超时的
/// 异步 `exists()`：超时 / 不存在都退回 `path_provider` 默认根，数据仍留在原盘不动。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory fakeTemp;

  setUp(() {
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('data_root 不可用 → 快速退回默认根，绝不长时间阻塞（不 hang）', () async {
    final String missing = p.join(tmp.path, 'offline_drive_root');
    AppPaths.debugDataRootReader = () async => missing;

    final Stopwatch sw = Stopwatch()..start();
    final AppPaths paths = await AppPaths.resolve();
    sw.stop();

    // 退回默认根（数据根路径不生效）。
    expect(paths.documentsRoot.path,
        equals(p.join(tmp.path, 'default_documents')));
    // 关键：解析必须在超时上限（2s）+ 合理裕量内返回，绝不因坏根卡死主 isolate。
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)),
        reason: '坏 / 掉线数据根必须被超时降级，不得让 resolve() 无限阻塞');
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

  test('源码守卫：_resolveDataRoot 不得再用阻塞式 existsSync()，必须走带超时的异步 exists()', () {
    final File? f = <String>[
      'lib/src/storage/app_paths.dart',
      'hibiki/lib/src/storage/app_paths.dart',
    ].map(File.new).cast<File?>().firstWhere(
        (File? f) => f != null && f.existsSync(),
        orElse: () => null);
    expect(f, isNotNull, reason: 'app_paths.dart not found');
    final String src = f!.readAsStringSync();

    // 抽出 _resolveDataRoot 函数体做定向断言（避免误伤其它无关 existsSync 用法）。
    final int start = src.indexOf('_resolveDataRoot');
    expect(start, greaterThanOrEqualTo(0));
    // 到下一个静态解析函数为止的片段。
    final int end = src.indexOf('_resolveDocumentsRoot', start);
    final String rawBody = src.substring(start, end < 0 ? src.length : end);
    // 剥掉注释行再扫描：函数体注释里会**提到** existsSync（解释旧代码为何被换掉），
    // 只对真实代码断言，避免守卫被自己的说明性注释误伤。
    final String body = const LineSplitter()
        .convert(rawBody)
        .where((String line) => !line.trimLeft().startsWith('//'))
        .join(' ');

    expect(body.contains('existsSync()'), isFalse,
        reason: '掉线盘上同步 existsSync() 会阻塞主 isolate → 无限加载，禁止回归');
    expect(RegExp(r'\.exists\(\)\s*\.timeout\(').hasMatch(body), isTrue,
        reason: '必须用带超时的异步 exists().timeout(...) 探测数据根');
  });
}
