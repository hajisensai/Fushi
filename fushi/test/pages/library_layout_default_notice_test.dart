import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/library_layout_default_notice.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/settings/settings_schema_appearance.dart';
import 'package:fushi_core/fushi_core.dart';

/// 库页默认布局改成封面网格后的一次性提示（拍板台 pr3454，2026-11-16：
/// 「默认改封面网格，更新后提醒可选拼贴」）：只对升级上来、从没选过布局的用户弹一次。
void main() {
  group('decideLibraryLayoutDefaultNotice', () {
    LibraryLayoutDefaultNoticeDecision decide({
      bool handled = false,
      bool freshInstall = false,
      bool layoutChosen = false,
      bool layoutActive = true,
      bool layoutChoiceOffered = false,
    }) => decideLibraryLayoutDefaultNotice(
      handled: handled,
      freshInstall: freshInstall,
      layoutChosen: layoutChosen,
      layoutActive: layoutActive,
      layoutChoiceOffered: layoutChoiceOffered,
    );

    test('升级上来、没选过布局（此前看到的是拼贴）：弹一次', () {
      expect(decide(), LibraryLayoutDefaultNoticeDecision.show);
    });

    test('已处理过：不再弹，也不重复落标记', () {
      expect(decide(handled: true), LibraryLayoutDefaultNoticeDecision.none);
    });

    test('全新安装：只落标记（从没见过拼贴默认）', () {
      expect(
        decide(freshInstall: true),
        LibraryLayoutDefaultNoticeDecision.markHandled,
      );
    });

    test('显式选过布局：默认值改动对他无影响，只落标记', () {
      expect(
        decide(layoutChosen: true),
        LibraryLayoutDefaultNoticeDecision.markHandled,
      );
    });

    test('归「选一种库页布局」选择框管的升级用户：只落标记，不在「稍后再说」后再弹一遍', () {
      // 选择框里点「稍后再说」不写布局（layoutChosen 仍为 false），此前这条提示
      // 紧接着又弹，且与选择框对「新默认」的说法相反。
      expect(
        decide(layoutChoiceOffered: true),
        LibraryLayoutDefaultNoticeDecision.markHandled,
      );
    });

    test('墨水屏（库页布局恒为封面网格、设置项隐藏）：不提示一个看不到的选项', () {
      expect(
        decide(layoutActive: false),
        LibraryLayoutDefaultNoticeDecision.markHandled,
      );
    });
  });

  group('偏好', () {
    late FushiDatabase db;
    late PreferencesRepository prefs;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
    });

    tearDown(() async {
      prefs.dispose();
      await db.close();
    });

    test('已处理标记默认 false，落标记后读得回来', () async {
      expect(prefs.libraryLayoutDefaultNoticeHandled, isFalse);
      await prefs.setLibraryLayoutDefaultNoticeHandled();
      await prefs.loadFromDb();
      expect(prefs.libraryLayoutDefaultNoticeHandled, isTrue);
    });

    test('标记登记在注册表，且不随 Profile 快照走', () {
      expect(
        kKnownPreferenceKeys,
        contains('library_layout_default_notice_handled'),
      );
      expect(
        ProfileKeys.isExcludedPref('library_layout_default_notice_handled'),
        isTrue,
        reason: '进快照的话切到老 Profile 会删掉标记，提示又弹一遍',
      );
    });

    test('shellContentLayoutChosen 只认落库值非空（含已删的 blocks）', () {
      ThemeNotifier notifier(Map<String, String> snapshot) =>
          ThemeNotifier(db, () => const TextTheme())
            ..loadFromPrefsSnapshot(snapshot);

      expect(notifier(<String, String>{}).shellContentLayoutChosen, isFalse);
      expect(
        notifier(<String, String>{
          'shell_content_layout': PrefCodec.encode(''),
        }).shellContentLayoutChosen,
        isFalse,
      );
      for (final String stored in <String>['collage', 'grid', 'blocks']) {
        expect(
          notifier(<String, String>{
            'shell_content_layout': PrefCodec.encode(stored),
          }).shellContentLayoutChosen,
          isTrue,
          reason: stored,
        );
      }
    });
  });

  /// 挂一个按钮打开提示框；返回读取对话框结果的闭包。
  Future<bool? Function()> openDialog(WidgetTester tester) async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    bool? result;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showLibraryLayoutDefaultNoticeDialog(context);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => result;
  }

  testWidgets('提示框路径取设置页真实标签；点「换成拼贴」返回 true', (WidgetTester tester) async {
    final bool? Function() result = await openDialog(tester);
    expect(
      find.byKey(const ValueKey<String>('library_layout_default_notice')),
      findsOneWidget,
    );
    // 路径的分类名与行名取设置页真实标题：任何一方改名，提示框都跟着变。
    final String appearance = buildAppearanceDestination().title;
    expect(appearance, t.settings_destination_appearance);
    final String body = t.library_layout_default_notice_body(
      collage: t.library_layout_collage,
      settings: t.settings,
      appearance: appearance,
      layout: t.library_layout,
    );
    expect(find.text(body), findsOneWidget);
    expect(body, contains(t.library_layout_collage));

    await tester.tap(
      find.byKey(
        const ValueKey<String>('library_layout_default_notice_collage'),
      ),
    );
    await tester.pumpAndSettle();
    expect(result(), isTrue);
    expect(
      find.byKey(const ValueKey<String>('library_layout_default_notice')),
      findsNothing,
    );
  });

  testWidgets('点「保留封面网格」返回 false', (WidgetTester tester) async {
    final bool? Function() result = await openDialog(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('library_layout_default_notice_keep')),
    );
    await tester.pumpAndSettle();
    expect(result(), isFalse);
  });

  test('首页首帧接线：用改写 first_time_setup 之前的判据，排在更新弹窗之前', () {
    final String source = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();
    final int fresh = source.indexOf(
      'final bool freshInstall = appModelNoUpdate.isFirstTimeSetup;',
    );
    final int notice = source.indexOf(
      'await maybeShowLibraryLayoutDefaultNotice(',
    );
    final int update = source.indexOf('UpdateChecker.scheduleCheck(');
    expect(fresh, isNonNegative);
    expect(notice, greaterThan(fresh));
    expect(
      source.substring(notice, notice + 200),
      contains('freshInstall: freshInstall'),
    );
    expect(update, greaterThan(notice), reason: '与更新弹窗串行，排在它之前');
  });
}
