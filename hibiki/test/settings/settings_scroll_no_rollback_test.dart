import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/models/theme_notifier.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';

import '../helpers/test_platform_services.dart';

/// 设置页深滚动被拉回的回归测试（用户报「设置页往下滑会自动跳到上面，得再滑一下」）。
///
/// 与 `test/focus/focus_repair_touch_no_scroll_test.dart` 互补：那条用**合成** ListView
/// 守住 HibikiFocusController 的 touch 门控根因（f6ef60d27：被动焦点修复 reveal 仅在
/// traditional 高亮模式生效，touch 下无光标 → 不 reveal）；本条用**真实
/// MaterialSettingsRenderer + 真实长 destination**，关闭「设置页专用」缺口 —— 证明真实
/// 设置列表的行（`_SettingsRowFocusTarget` 即 HibikiFocusTarget）也吃这个门控：深滚后
/// 被动焦点修复（行回收 → ensureFocus re-home）不把视口居中拽回。
void main() {
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  Future<({ScrollController controller, Element listElement})> pumpSettings(
    WidgetTester tester,
  ) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final ReaderSettings? prevReader = ReaderHibikiSource.readerSettings;
    final ReaderSettings readerSettings = ReaderSettings(db);
    await readerSettings.refreshFromDb();
    ReaderHibikiSource.readerSettings = readerSettings;
    addTearDown(() => ReaderHibikiSource.readerSettings = prevReader);

    final ThemeNotifier themeNotifier =
        ThemeNotifier(db, () => const TextTheme())
          ..loadFromPrefsSnapshot(<String, String>{
            'design_system': PrefCodec.encode('material'),
            'app_theme_key': PrefCodec.encode('system-theme'),
            'brightness_mode': PrefCodec.encode('system'),
            'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
          });
    addTearDown(themeNotifier.dispose);

    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_settings_scroll_');
    addTearDown(() {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final AppModel appModel = AppModel(testPlatformServices())
      ..themeNotifier = themeNotifier
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(
          prefsRepo: prefsRepo, databaseDirectory: tmpDir);

    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
      child: MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          platform: TargetPlatform.android,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
          extensions: <ThemeExtension<dynamic>>[
            HibikiDesignSystemTheme(themeNotifier.designSystemTheme),
          ],
        ),
        home: Scaffold(
          // 矮视口逼出滚动（reading 分组 26 项远超 240px）。
          body: SizedBox(
            height: 240,
            child: HibikiFocusRoot(
              child: Consumer(
                builder: (BuildContext ctx, WidgetRef ref, Widget? _) {
                  final SettingsContext sctx = SettingsContext(
                    context: ctx,
                    appModel: ref.read(appProvider),
                    ref: ref,
                    readerSource: ReaderHibikiSource.instance,
                    refresh: () {},
                  );
                  final SettingsDestination reading = buildSettingsSchema(sctx)
                      .firstWhere((SettingsDestination d) =>
                          d.id == SettingsDestinationId.reading);
                  return MaterialSettingsRenderer().buildDetailContent(
                    settingsContext: sctx,
                    destination: reading,
                    scrollController: controller,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    return (
      controller: controller,
      listElement: tester.element(find.byType(Scrollable).first),
    );
  }

  testWidgets('touch: deep-scrolling the real settings list does not roll back',
      (WidgetTester tester) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;

    final ({ScrollController controller, Element listElement}) s =
        await pumpSettings(tester);

    expect(s.controller.position.maxScrollExtent, greaterThan(0),
        reason: '内容必须超出视口，否则 no-rollback 断言为空');

    // 用户已滑到下方，原持焦行已回收。先深滚并 pumpAndSettle —— 设置列表行高可变、
    // 懒加载，jumpTo 后 maxScrollExtent 会重测，弹道滚动会把越界 offset clamp 到新
    // 上界；先把这一步的弹道吃掉，拿到**稳定**的落点，避免把"extent 重测 clamp"误当
    // 成"焦点修复拽回"。
    s.controller.jumpTo(s.controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final double settled = s.controller.offset;

    // 让原持焦控件失焦，逼 ensureFocus 走「无可用 primary → re-home + 被动 reveal」
    // 这条门控路径（否则走 _handleFocusChange 不命中门控，测不到回归）。
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    // 关键断言：被动焦点修复 re-home 到一个 now-visible 控件，touch 模式下
    // _maybeRevealOnRepair 必须早退、**不得** reveal 把视口拽回（f6ef60d27 把它门控到
    // traditional：无光标时移动 scroll 去「显示」一个被程序抓取的目标是多余跳动）。
    HibikiFocusRoot.controllerOf(s.listElement).ensureFocus();
    await tester.pumpAndSettle();

    expect(s.controller.offset, settled,
        reason: 'touch 下被动焦点修复把设置列表从 $settled 拽到 ${s.controller.offset}');
  });

  testWidgets(
      'traditional: directional move still reveals (fix did not over-suppress)',
      (WidgetTester tester) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;

    final ({ScrollController controller, Element listElement}) s =
        await pumpSettings(tester);
    expect(s.controller.position.maxScrollExtent, greaterThan(0));

    final HibikiFocusController focus =
        HibikiFocusRoot.controllerOf(s.listElement);
    focus.ensureFocus();
    await tester.pump();
    for (int i = 0; i < 12; i++) {
      focus.move(HibikiFocusDirection.down);
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(s.controller.offset, greaterThan(0),
        reason: '方向导航(手柄/键鼠)必须仍把焦点目标 reveal 进视口，fix 未误伤');
  });
}
