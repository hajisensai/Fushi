import 'dart:io' show Platform;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/theme_notifier.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema_video.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

// TODO-1116/1119 / BUG-545 real render verification.
//
// The Windows GPU black-flicker known-issue row is a plain informational text
// row inside the video image-quality group, gated by
// SettingsCustomItem(visible: (_) => isWindowsPlatform). The gate uses runtime
// Platform.isWindows (real host OS), NOT defaultTargetPlatform, so it cannot be
// flipped via debugDefaultTargetPlatformOverride. On the real host this test:
//
// 1. Renders the real image-quality section from the real buildVideoDestination
//    through the real MaterialSettingsRenderer, so visibleCopy gating +
//    SettingsCustomItem dispatch invoke the real _buildWindowsBlackFlashNotice
//    builder, asserting the two real i18n strings mount (real render, not scan).
// 2. Asserts the gating direction: visibleCopy keeps the item only on Windows
//    hosts and filters it out elsewhere (Windows shows / non-Windows hides).
HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

SettingsDestination _noticeOnlyDestination() {
  final SettingsDestination video = buildVideoDestination();
  final List<SettingsItem> noticeItems = video.sections
      .expand((SettingsSection section) => section.items)
      .where((SettingsItem item) =>
          item.id == 'video.quality.windows_black_flash_notice')
      .toList(growable: false);
  expect(noticeItems, hasLength(1),
      reason:
          'image-quality group must own exactly one Windows black-flash row');
  return SettingsDestination(
    id: video.id,
    title: video.title,
    icon: video.icon,
    sections: <SettingsSection>[
      SettingsSection(items: noticeItems),
    ],
  );
}

Widget _harness({
  required Widget Function(SettingsContext) builder,
}) {
  final HibikiDatabase db = _testDb();
  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode('material'),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('system'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
    });
  final AppModel appModel = _NoticeTestAppModel()
    ..themeNotifier = themeNotifier;
  addTearDown(() async {
    themeNotifier.dispose();
    await db.close();
  });

  return ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((Ref ref) => appModel),
    ],
    child: MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        platform: TargetPlatform.windows,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
        extensions: <ThemeExtension<dynamic>>[
          HibikiDesignSystemTheme(themeNotifier.designSystemTheme),
        ],
      ),
      home: Consumer(
        builder: (BuildContext context, WidgetRef ref, _) {
          return builder(
            SettingsContext(
              context: context,
              appModel: ref.read(appProvider),
              ref: ref,
              readerSource: ReaderHibikiSource.instance,
              refresh: () {},
            ),
          );
        },
      ),
    ),
  );
}

void main() {
  testWidgets(
      'TODO-1116/1119: black-flicker notice renders its real i18n title+body '
      'on Windows host through the real renderer', (WidgetTester tester) async {
    if (!Platform.isWindows) {
      return;
    }

    await tester.pumpWidget(
      _harness(
        builder: (SettingsContext settingsContext) {
          return MaterialSettingsRenderer().buildDetailPage(
            settingsContext: settingsContext,
            destination: _noticeOnlyDestination(),
          );
        },
      ),
    );
    await tester.pump();

    expect(find.text(t.video_windows_black_flash_notice_title), findsOneWidget,
        reason: 'notice title must render on a Windows host');
    expect(find.text(t.video_windows_black_flash_notice_body), findsOneWidget,
        reason: 'notice body must render on a Windows host');

    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is AdaptiveSettingsRow &&
            widget.title == t.video_windows_black_flash_notice_title &&
            widget.subtitle == t.video_windows_black_flash_notice_body &&
            widget.icon == Icons.info_outline,
      ),
      findsOneWidget,
      reason:
          'notice must be an info_outline row (no toggle, no default change)',
    );
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
  });

  test('TODO-1116/1119: notice item is gated Windows-only via visibleCopy', () {
    final SettingsDestination video = buildVideoDestination();
    final SettingsSection qualitySection = video.sections.firstWhere(
      (SettingsSection section) => section.items.any(
        (SettingsItem item) =>
            item.id == 'video.quality.windows_black_flash_notice',
      ),
      orElse: () => throw StateError('image-quality group missing notice row'),
    );
    final SettingsItem notice = qualitySection.items.firstWhere(
      (SettingsItem item) =>
          item.id == 'video.quality.windows_black_flash_notice',
    );

    expect(notice.visible, isNotNull,
        reason: 'notice must carry a platform visible predicate');

    final SettingsContext ctx = _StubSettingsContext();
    expect(notice.isVisible(ctx), Platform.isWindows,
        reason:
            'gate truth must equal Platform.isWindows (Windows show / else hide)');

    final SettingsSection filtered = qualitySection.visibleCopy(ctx);
    final bool noticeSurvives = filtered.items.any(
      (SettingsItem item) =>
          item.id == 'video.quality.windows_black_flash_notice',
    );
    expect(noticeSurvives, Platform.isWindows,
        reason:
            'visibleCopy must keep the notice only on Windows hosts, filter elsewhere');
  });

  testWidgets(
      'TODO-1116/1119: renderer honors the visible gate -- when the notice gate '
      'is off (non-Windows behavior) the row does not render', (
    WidgetTester tester,
  ) async {
    // Render-level proof of the HIDE direction. Platform.isWindows cannot be
    // flipped in-process, so this rebuilds the exact notice item with its
    // visible predicate forced off (what a non-Windows host resolves to) and
    // asserts the real MaterialSettingsRenderer omits the row entirely.
    final SettingsDestination video = buildVideoDestination();
    final SettingsItem realNotice = video.sections
        .expand((SettingsSection section) => section.items)
        .firstWhere((SettingsItem item) =>
            item.id == 'video.quality.windows_black_flash_notice');
    final SettingsCustomItem custom = realNotice as SettingsCustomItem;
    final SettingsDestination hiddenDestination = SettingsDestination(
      id: video.id,
      title: video.title,
      icon: video.icon,
      sections: <SettingsSection>[
        SettingsSection(
          items: <SettingsItem>[
            SettingsCustomItem(
              id: custom.id,
              builder: custom.builder,
              visible: (SettingsContext _) => false,
            ),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      _harness(
        builder: (SettingsContext settingsContext) {
          return MaterialSettingsRenderer().buildDetailPage(
            settingsContext: settingsContext,
            destination: hiddenDestination,
          );
        },
      ),
    );
    await tester.pump();

    expect(find.text(t.video_windows_black_flash_notice_title), findsNothing,
        reason: 'gate off -> notice title must not render (non-Windows hides)');
    expect(find.text(t.video_windows_black_flash_notice_body), findsNothing,
        reason: 'gate off -> notice body must not render (non-Windows hides)');
    expect(find.byIcon(Icons.info_outline), findsNothing);
  });
}

class _NoticeTestAppModel extends AppModel {
  _NoticeTestAppModel() : super(testPlatformServices());

  @override
  bool get reverseReaderBottomBar => false;

  @override
  bool get gamepadAutoImmersive => false;
}

class _StubSettingsContext implements SettingsContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
