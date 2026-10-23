// 反馈 _sZllpFQWm / BUG-3698：互联下载（从已配对设备拉到本机）的任务此前只在
// 「浏览 → 下载」里列出，iOS 没有浏览模块，iPad 上点了「下载远端集」就停不下来。
//
// 钉两件事：
// ① 独立的「互联下载」页能把管理器里的任务列出来并给暂停动作（不经浏览页）；
// ② 页面本身与设置 › 互联里的入口都**不问**商店合规门 / 浏览模块开关——互联下载
//    不是受限能力，挂上那道门 iOS 上就又没有入口了。
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/interconnect_download_tasks_page.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('互联下载页列出管理器里的任务并给暂停', (WidgetTester tester) async {
    LocaleSettings.setLocale(AppLocale.en);
    final InterconnectDownloadManager manager = InterconnectDownloadManager();
    final Directory dir = Directory.systemTemp.createTempSync('fushi_ic_page');
    addTearDown(() => dir.deleteSync(recursive: true));
    final Completer<void> gate = Completer<void>();
    unawaited(
      manager
          .startVideoDownload(
            id: 'video/e1',
            title: 'Show 01',
            dest: File('${dir.path}/e1.mp4'),
            run:
                (
                  File target, {
                  void Function(double progress)? onProgress,
                  void Function(int received, int? total)? onBytes,
                  Future<void>? cancelSignal,
                }) async {
                  await Future.any(<Future<void>>[
                    gate.future,
                    if (cancelSignal != null) cancelSignal,
                  ]);
                },
          )
          .then((_) {}, onError: (Object _) {}),
    );

    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          interconnectDownloadManagerProvider.overrideWith((ref) => manager),
        ],
        child: TranslationProvider(
          child: const MaterialApp(home: InterconnectDownloadTasksPage()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Show 01'), findsWidgets, reason: '在跑的互联下载必须列出来');
    expect(manager.canPause('video/e1'), isTrue);

    gate.complete();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  test('互联下载页与设置入口不挂商店合规门 / 浏览模块开关', () {
    final String page = File(
      'lib/src/pages/implementations/interconnect_download_tasks_page.dart',
    ).readAsStringSync();
    final String code = page
        .split('\n')
        .where((String line) => !line.trimLeft().startsWith('///'))
        .join('\n');
    expect(code.contains('StoreRestrictedCapability'), isFalse);
    expect(code.contains('ModuleId.browse'), isFalse);

    final String schema = File(
      'lib/src/sync/sync_settings_schema.dart',
    ).readAsStringSync();
    final int at = schema.indexOf("id: 'interconnect.download_tasks'");
    expect(at, greaterThan(0), reason: '设置 › 互联里必须有互联下载入口');
    // 入口所在条目（到下一个条目的 id 为止）里不能出现任何合规 / 模块判据。
    final int next = schema.indexOf("id: '", at + 1);
    final String item = schema.substring(at, next < 0 ? schema.length : next);
    expect(item.contains('StoreRestrictedCapability'), isFalse);
    expect(item.contains('ModuleId'), isFalse);
    expect(item.contains('visible:'), isFalse);
  });
}
