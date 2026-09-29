import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/browse_moved_notice.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi_core/fushi_core.dart';

/// 「下载」改名「浏览」的一次性搬迁提示（所有者 2026-09-28 拍板「保持关闭 +
/// 提示」）：升级前关着下载的用户照旧关着，只弹一次告诉他们东西搬到了哪里。
void main() {
  group('decideBrowseMovedNotice', () {
    BrowseMovedNoticeDecision decide({
      bool handled = false,
      bool freshInstall = false,
      bool browseAvailable = true,
      bool browseEnabled = false,
    }) => decideBrowseMovedNotice(
      handled: handled,
      freshInstall: freshInstall,
      browseAvailable: browseAvailable,
      browseEnabled: browseEnabled,
    );

    test('升级前关着下载的用户：弹一次', () {
      expect(decide(), BrowseMovedNoticeDecision.show);
    });

    test('已处理过：不再弹，也不重复落标记', () {
      expect(decide(handled: true), BrowseMovedNoticeDecision.none);
    });

    test('全新安装：只落标记（之后再关浏览也不会被提示）', () {
      expect(decide(freshInstall: true), BrowseMovedNoticeDecision.markHandled);
    });

    test('升级前开着下载：只落标记', () {
      expect(
        decide(browseEnabled: true),
        BrowseMovedNoticeDecision.markHandled,
      );
    });

    test('本平台没有浏览模块（iOS 合规）：不提示一个打不开的开关', () {
      expect(
        decide(browseAvailable: false),
        BrowseMovedNoticeDecision.markHandled,
      );
    });
  });

  group('已处理标记', () {
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

    test('默认未处理，落标记后读得回来', () async {
      expect(prefs.browseMovedNoticeHandled, isFalse);
      await prefs.setBrowseMovedNoticeHandled();
      await prefs.loadFromDb();
      expect(prefs.browseMovedNoticeHandled, isTrue);
    });

    test('键登记在注册表，且不随 Profile 快照走', () {
      expect(kKnownPreferenceKeys, contains('browse_moved_notice_handled'));
      expect(
        ProfileKeys.isExcludedPref('browse_moved_notice_handled'),
        isTrue,
        reason: '进快照的话切到老 Profile 会删掉标记，关着浏览的用户又被提示一遍',
      );
    });
  });

  testWidgets('提示框的路径用界面上真实显示的标签', (WidgetTester tester) async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: TextButton(
                onPressed: () => showBrowseMovedNoticeDialog(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('browse_moved_notice')),
      findsOneWidget,
    );
    final String body = t.browse_moved_notice_body(
      browse: t.nav_browse,
      settings: t.settings,
      appearance: t.settings_destination_appearance_interaction,
      modules: t.settings_section_modules,
    );
    expect(find.text(body), findsOneWidget);
    expect(body, contains(t.nav_browse));
    expect(body, contains(t.settings_section_modules));

    await tester.tap(
      find.byKey(const ValueKey<String>('browse_moved_notice_ok')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('browse_moved_notice')),
      findsNothing,
    );
  });

  test('首页首帧接线：先取全新安装判据，在更新弹窗之前提示', () {
    final String source = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();
    final int fresh = source.indexOf(
      'final bool freshInstall = appModelNoUpdate.isFirstTimeSetup;',
    );
    final int tutorial = source.indexOf(
      'appModelNoUpdate.setFirstTimeSetupFlag()',
    );
    final int notice = source.indexOf('await maybeShowBrowseMovedNotice(');
    final int update = source.indexOf('UpdateChecker.scheduleCheck(');
    expect(fresh, isNonNegative);
    expect(tutorial, greaterThan(fresh), reason: '改写 first_time_setup 之前取');
    expect(notice, greaterThan(fresh));
    expect(update, greaterThan(notice), reason: '与更新弹窗串行，排在它之前');
  });
}
