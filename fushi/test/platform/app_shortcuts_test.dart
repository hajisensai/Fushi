import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/platform/app_shortcuts.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppShortcut URL', () {
    test('every shortcut round-trips through its URL', () {
      for (final AppShortcut shortcut in AppShortcut.values) {
        expect(shortcut.url, 'fushi://shortcut/${shortcut.id}');
        expect(AppShortcut.tryParse(shortcut.url), shortcut);
      }
    });

    test('scheme and host match case-insensitively', () {
      expect(AppShortcut.tryParse('FUSHI://Shortcut/books'), AppShortcut.books);
    });

    test('rejects other fushi URLs and unknown ids', () {
      expect(AppShortcut.tryParse(null), isNull);
      expect(AppShortcut.tryParse('fushi://lookup?word=x'), isNull);
      expect(AppShortcut.tryParse('fushi://auth/google'), isNull);
      expect(AppShortcut.tryParse('fushi://shortcut/'), isNull);
      expect(AppShortcut.tryParse('fushi://shortcut/unknown'), isNull);
      expect(AppShortcut.tryParse('https://shortcut/books'), isNull);
    });

    test('each shortcut lands on the matching home tab', () {
      expect(AppShortcut.lookup.homeTab, HomeTab.dictionaries);
      expect(AppShortcut.books.homeTab, HomeTab.books);
      expect(AppShortcut.manga.homeTab, HomeTab.manga);
      expect(AppShortcut.video.homeTab, HomeTab.video);
      expect(AppShortcut.games.homeTab, HomeTab.games);
      expect(AppShortcut.settings.homeTab, HomeTab.settings);
    });
  });

  group('AppShortcut.available', () {
    test('lookup first, settings last, games only where the module exists', () {
      final List<AppShortcut> ios = AppShortcut.available(
        ModuleVisibility.all(
          isWindows: false,
          isDesktop: false,
          isIOS: true,
          isAndroid: false,
        ),
      );
      expect(ios, [
        AppShortcut.lookup,
        AppShortcut.books,
        AppShortcut.manga,
        AppShortcut.video,
        AppShortcut.settings,
      ]);

      final List<AppShortcut> android = AppShortcut.available(
        ModuleVisibility.all(
          isWindows: false,
          isDesktop: false,
          isIOS: false,
          isAndroid: true,
        ),
      );
      expect(android, [
        AppShortcut.lookup,
        AppShortcut.books,
        AppShortcut.manga,
        AppShortcut.video,
        AppShortcut.games,
        AppShortcut.settings,
      ]);
    });

    test('modules the user turned off are not offered; settings always is', () {
      final List<AppShortcut> shortcuts = AppShortcut.available(
        const ModuleVisibility(<ModuleId>{ModuleId.books}),
      );
      expect(shortcuts, [AppShortcut.books, AppShortcut.settings]);
    });
  });

  group('AppShortcutsPublisher', () {
    final List<MethodCall> calls = <MethodCall>[];
    PlatformException? failWith;

    setUp(() {
      calls.clear();
      failWith = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FushiChannels.appShortcuts, (
            MethodCall call,
          ) async {
            calls.add(call);
            if (failWith != null) throw failWith!;
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FushiChannels.appShortcuts, null);
    });

    String label(AppShortcut shortcut) => 'L-${shortcut.id}';

    test('sends id, title and url in order', () async {
      AppShortcutsPublisher(platformSupported: true).sync(<AppShortcut>[
        AppShortcut.lookup,
        AppShortcut.settings,
      ], labelOf: label);
      await pumpEventQueue();
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setShortcuts');
      expect(calls.single.arguments, <Map<String, String>>[
        <String, String>{
          'id': 'lookup',
          'title': 'L-lookup',
          'url': 'fushi://shortcut/lookup',
        },
        <String, String>{
          'id': 'settings',
          'title': 'L-settings',
          'url': 'fushi://shortcut/settings',
        },
      ]);
    });

    test(
      'repeated rebuilds do not re-send; label or list changes do',
      () async {
        final AppShortcutsPublisher publisher = AppShortcutsPublisher(
          platformSupported: true,
        );
        publisher.sync(<AppShortcut>[AppShortcut.books], labelOf: label);
        publisher.sync(<AppShortcut>[AppShortcut.books], labelOf: label);
        await pumpEventQueue();
        expect(calls, hasLength(1));

        publisher.sync(<AppShortcut>[
          AppShortcut.books,
        ], labelOf: (AppShortcut s) => 'Books (ja)');
        publisher.sync(<AppShortcut>[
          AppShortcut.books,
          AppShortcut.video,
        ], labelOf: label);
        await pumpEventQueue();
        expect(calls, hasLength(3));
      },
    );

    test('a failed publish is retried on the next rebuild', () async {
      final AppShortcutsPublisher publisher = AppShortcutsPublisher(
        platformSupported: true,
      );
      failWith = PlatformException(code: 'rate_limited');
      publisher.sync(<AppShortcut>[AppShortcut.books], labelOf: label);
      await pumpEventQueue();
      failWith = null;
      publisher.sync(<AppShortcut>[AppShortcut.books], labelOf: label);
      await pumpEventQueue();
      expect(calls, hasLength(2));
    });

    test('unsupported platforms never touch the channel', () async {
      AppShortcutsPublisher(
        platformSupported: false,
      ).sync(AppShortcut.values, labelOf: label);
      await pumpEventQueue();
      expect(calls, isEmpty);
    });
  });

  // 原生侧按 id 选图标：新增一条 AppShortcut 却忘了给两端补图标时，Android 会
  // 静默落到设置齿轮、iOS 同理——这里把两份 switch 与枚举钉在一起。
  test('both native sides map an icon for every shortcut id', () {
    final String java = File(
      'android/app/src/main/java/app/fushi/reader/AppShortcutsHelper.java',
    ).readAsStringSync();
    final String swift = File(
      'ios/Runner/AppDelegate.swift',
    ).readAsStringSync();
    for (final AppShortcut shortcut in AppShortcut.values) {
      expect(java, contains('case "${shortcut.id}":'), reason: shortcut.id);
      expect(swift, contains('case "${shortcut.id}":'), reason: shortcut.id);
      expect(
        File(
          'android/app/src/main/res/drawable/ic_shortcut_${shortcut.id}.xml',
        ).existsSync(),
        isTrue,
        reason: shortcut.id,
      );
    }
    expect(
      File(
        'android/app/src/main/java/app/fushi/reader/constants/ChannelNames.java',
      ).readAsStringSync(),
      contains('"/app_shortcuts"'),
    );
    expect(FushiChannels.appShortcuts.name, 'app.fushi.reader/app_shortcuts');
  });
}
