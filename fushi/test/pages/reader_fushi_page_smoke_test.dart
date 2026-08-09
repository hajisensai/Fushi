import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// ReaderFushiPage 首个 widget 冒烟测试（阅读器渐进重建 phase1）。
///
/// 背景：13000+ 行的阅读器页此前**零运行时覆盖**——全部依赖源码字符串守卫，
/// 对「代码被搬走/重写但行为变了」几乎无效。本文件对齐
/// video_fushi_page_smoke_test.dart 的骨架，把「页面挂载编排彻底坏掉」这类
/// 灾难从真机提前到 CI。
///
/// 锁定 BUG-437 的恢复契约：init 链上任何一步失败（这里用「书不存在」这个最
/// 容易确定性构造的失败）都必须确定性归还加载态——toast + pop 退回上一页，
/// 绝不让 spinner 永挂。
void main() {
  testWidgets('missing book pops back to shelf instead of a stuck loader',
      (WidgetTester tester) async {
    final FushiDatabase db =
        FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PlatformServices platformServices = testPlatformServices();
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_reader_smoke_');
    addTearDown(() {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final AppModel appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      // 阅读器 post-frame 读 lowMemoryMode、dispose 读 audiobookBackgroundPlay，
      // 都走 prefsRepo（late）——按 video_quick_settings_harness 同款精简接线。
      ..wireLocalAudioForTesting(
          prefsRepo: prefsRepo, databaseDirectory: tmpDir);
    // 阅读器 build 读 appThemeKey → themeNotifier（late，正常由 initialise() 构造，
    // 见 HBK-AUDIT-003 同款接线）；测试走精简接线，与 popup 分支同参构造。
    appModel.themeNotifier = ThemeNotifier(db, () => appModel.textTheme);
    final FakeAnkiRepository ankiRepository = FakeAnkiRepository();

    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[
        platformServicesProvider.overrideWithValue(platformServices),
        ankiRepositoryProvider.overrideWithValue(ankiRepository),
        appProvider.overrideWith((ref) => appModel),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) =>
                        const ReaderFushiPage(bookKey: 'no/such-book'),
                  ));
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pump();
    // init 链（profile/settings 并行 + 书本定位）跑完：书不在盘上 → toast + pop。
    await tester.pumpAndSettle();

    expect(find.byType(ReaderFushiPage), findsNothing,
        reason: 'BUG-437 契约：init 失败必须 pop 退回上一页');
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '不允许把 spinner 永挂在屏幕上');
    expect(find.text('open'), findsOneWidget, reason: 'pop 后应回到出发页');
    expect(tester.takeException(), isNull, reason: '恢复路径不得向框架抛未处理异常');
  });
}
