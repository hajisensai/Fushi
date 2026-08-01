import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/storage/app_paths.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// BUG-1400 守卫：`AppPaths` 的路径解析在 `testWidgets` 的 **fake async 相位内**必须能
/// 自行走完，不许把完成时机寄托在真实事件循环上。
///
/// **为什么这是一条必须钉住的不变量**——[AppPaths.documentsSubdirectory] 是运行时静态
/// 便捷层，封面抽取、字幕落点、缩略图等**页面级 fire-and-forget 链**都从它派生，因此它
/// 会被 widget 测试在 `pump()` 相位大量调用。而它每次解析都要 await
/// `SharedPreferences.getInstance()`：
///
///  * 装了 mock（[SharedPreferences.setMockInitialValues]）→ 应答在**进程内**由 mock
///    handler 以 microtask 给出，FakeAsync 会调度 microtask，解析在本相位内完成；
///  * 没装 mock → 调用穿到**真实**平台通道，应答只能由真实事件循环投递。FakeAsync 相位
///    收不到它，于是这次解析永久挂起——而 `SharedPreferences` 把首次调用的 `Completer`
///    存在**进程级静态字段**里，后续每个调用者（包括别的用例、包括 `runAsync` 里的）都
///    join 同一条死 future。**一次**在 fake async 相位发起的解析就能钉死整个 isolate 的
///    所有 `AppPaths` 解析。
///
/// 这正是 `home_video_remote_download_register_test.dart` 那条 flaky 的根因：页面的
/// 封面回填链在 fake async 相位里发起解析，把 prefs 钉死，随后 `runAsync` 里的下载登记
/// 链卡在派生字幕目录处，任务永远停在 running、`VideoBooks` 行写不出来。
///
/// 变异实测（2026-08-02）：注掉下面 `setUp` 里的
/// [SharedPreferences.setMockInitialValues] → 两个用例**全红**（第一个 `resolved` 仍是
/// null，第二个 5s 超时）；还原 → 全绿。
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

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
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
          '会把进程级 SharedPreferences completer 永久钉死（BUG-1400）',
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
}
