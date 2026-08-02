import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/storage/app_paths.dart';

import '../helpers/source_guard.dart';

/// BUG-1400 守卫：`AppPaths` 的路径解析在 `testWidgets` 的 **fake async 相位内**必须能
/// 自行走完，不许把完成时机寄托在真实事件循环上。
///
/// **为什么这是一条必须钉住的不变量**——[AppPaths.documentsSubdirectory] 是运行时静态
/// 便捷层，封面抽取、字幕落点、缩略图、着色器列举等**页面级 fire-and-forget 链**都从它
/// 派生，因此它会被 widget 测试在 `pump()` 相位大量调用。而它每次解析都要 await
/// `SharedPreferences.getInstance()`：
///
///  * 装了进程内存储 → 应答在**进程内**由 in-memory store 以 microtask 给出，FakeAsync
///    会调度 microtask，解析在本相位内完成；
///  * 没装 → 调用穿到**真实**平台通道，应答只能由真实事件循环投递。FakeAsync 相位收不到
///    它，于是这次解析永久挂起——而 `SharedPreferences` 把首次调用的 `Completer` 存在
///    **进程级静态字段**里，后续每个调用者（包括别的用例、包括 `runAsync` 里的）都 join
///    同一条死 future。**一次**在 fake async 相位发起的解析就能钉死整个 isolate 的所有
///    `AppPaths` 解析。
///
/// 这正是 `home_video_remote_download_register_test.dart` 那条 flaky 的根因：页面的封面
/// 回填链在 fake async 相位里发起解析，把 prefs 钉死，随后 `runAsync` 里的下载登记链卡在
/// 派生字幕目录处，任务永远停在 running、`VideoBooks` 行写不出来。
///
/// **本守卫为什么不再自己装 mock（TODO-2610）**：触发面是「所有会 pump 真实页面的 widget
/// 测试」，是一个**开放集合**——逐文件补 `setUp` 只能追认已经踩过的坑，永远慢一个文件，
/// 而且这条陷阱默认沉默（fire-and-forget 链挂住通常不报错）。所以修法收敛到套件级：
/// `test/flutter_test_config.dart` 在 `testExecutable` 里装一次进程内 prefs，特殊情况直接
/// 不存在。本文件因此**刻意不写 `setUp`**——下面两个行为用例现在直接验的就是那个套件级
/// harness，任何人把它拆掉，这里立刻红。第三条是配套的正向源码规则，让失败信息自带修法。
///
/// 变异实测（2026-08-02，全部经 `tool/flutter_test_failures.dart` 判定）：
///  * 只删本文件旧的局部 `setUp`、保留套件级安装 → 2 tests PASSED（证明套件级安装真的
///    在起作用，不是局部 mock 在兜底）；
///  * 再把 `flutter_test_config.dart` 里的 `installInMemorySharedPreferences()` 也去掉 →
///    FAILED，两个用例**全红**（第一个 `resolved` 仍是 null，第二个 5s 超时）；
///  * 把该调用改成**注释**（断言字面量塞进注释）→ FAILED 3 红，源码规则没被骗绿；
///  * 保留调用但把 `installInMemorySharedPreferences` 函数体掏空 → FAILED 3 红。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documentsDir;

  setUpAll(() {
    documentsDir =
        Directory.systemTemp.createTempSync('hibiki_app_paths_fakeasync');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => documentsDir.path,
    );
  });

  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (documentsDir.existsSync()) {
      try {
        documentsDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  testWidgets('fake async 相位内发起的 AppPaths 解析在同一相位内就完成（不依赖真实事件循环）',
      (WidgetTester tester) async {
    Directory? resolved;
    // 刻意不 await：复刻页面里 fire-and-forget 的封面/字幕路径解析。
    // ignore: unawaited_futures
    AppPaths.documentsSubdirectory('bug1400_probe')
        .then((Directory d) => resolved = d);

    // 只 pump（纯 fake async，绝不进 runAsync）。解析若依赖真实事件循环，这里必然还是 null。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      resolved,
      isNotNull,
      reason: 'AppPaths 解析在 fake async 相位内没走完 —— prefs 通道被穿到真实平台层，'
          '会把进程级 SharedPreferences completer 永久钉死（BUG-1400）。'
          '套件级 harness test/flutter_test_config.dart 应当已装好进程内 prefs。',
    );
    expect(resolved!.path, endsWith('bug1400_probe'));
  });

  testWidgets('前一个用例的解析不会毒化后续 runAsync 里的 AppPaths 解析',
      (WidgetTester tester) async {
    await tester.runAsync(() async {
      final Directory dir =
          await AppPaths.documentsSubdirectory('bug1400_probe').timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError(
          'AppPaths 在 runAsync 里 5s 没解析出来 —— 进程级 prefs completer 已被'
          '前一个用例的 fake async 相位钉死（BUG-1400）',
        ),
      );
      expect(dir.path, endsWith('bug1400_probe'));
    });
  });

  // 正向规则：不枚举「哪些测试文件受影响」（那是开放集合，第 N+1 个文件天生落在集合
  // 外、守卫对它零覆盖），而是钉住**唯一的宿主**——套件级 harness 本身。只要它在，
  // `test/` 下每个文件都自动免疫。
  test('套件级 harness 必须为整个 test/ 装进程内 SharedPreferences', () {
    final File config = File('test/flutter_test_config.dart');
    expect(
      config.existsSync(),
      isTrue,
      reason: '找不到 test/flutter_test_config.dart —— 套件级 harness 没了，'
          'BUG-1400 的 prefs 钉死会对全部 widget 测试原地复活。'
          '（flutter test 的 cwd 是 hibiki 包根；扫描路径失效也走这一条，'
          '不许静默变成永远绿的摆设。）',
    );

    final String source = config.readAsStringSync();

    // 结构窗口而非固定字符窗口：注释里的同名文本不算数，方法体变长也不漂移。
    final String executable =
        methodBody(source, 'Future<void> testExecutable(');
    expect(
      containsCodeLine(executable, 'installInMemorySharedPreferences()'),
      isTrue,
      reason: 'test/flutter_test_config.dart 的 testExecutable 没有调用 '
          'installInMemorySharedPreferences() —— 少了它，任何在 fake async 相位里'
          '触达 AppPaths 的 widget 测试都会把本 isolate 的 prefs completer 钉死'
          '（挂死 / pumpAndSettle 超时 / A Timer is still pending / 资产回收计数偏少），'
          '而且默认沉默、跨用例传染。恢复这一行，不要改成逐文件补 setUp。',
    );

    final String installer =
        methodBody(source, 'void installInMemorySharedPreferences(');
    expect(
      containsCodeLine(installer, 'setMockInitialValues('),
      isTrue,
      reason: 'installInMemorySharedPreferences 没有真的换掉 SharedPreferences 的'
          '平台实现。它必须调 SharedPreferences.setMockInitialValues —— 那条路径走的是'
          'SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore，'
          '完全不经平台通道，并顺手把静态 _completer 复位。',
    );
  });
}
