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
    });

    // 所有者 2026-09-27 拍板：只留查词 / 书 / 漫画 / 视频四条，两端一致。曾经发布
    // 过的游戏库 / 设置 URL 不再解析（Android 固定的那两条由原生侧置灰）。
    test('only lookup, books, manga and video exist', () {
      expect(AppShortcut.values, [
        AppShortcut.lookup,
        AppShortcut.books,
        AppShortcut.manga,
        AppShortcut.video,
      ]);
      expect(AppShortcut.tryParse('fushi://shortcut/games'), isNull);
      expect(AppShortcut.tryParse('fushi://shortcut/settings'), isNull);
    });
  });

  group('AppShortcut.available', () {
    test('same four in the same order on iOS and Android', () {
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
      ]);
    });

    test('modules the user turned off are not offered', () {
      final List<AppShortcut> shortcuts = AppShortcut.available(
        const ModuleVisibility(<ModuleId>{ModuleId.books}),
      );
      expect(shortcuts, [AppShortcut.books]);
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
      AppShortcutsPublisher(platformSupported: true).sync(
        <AppShortcut>[AppShortcut.lookup, AppShortcut.video],
        labelOf: label,
        disabledMessage: 'off',
      );
      await pumpEventQueue();
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setShortcuts');
      expect(calls.single.arguments, <String, Object>{
        'items': <Map<String, String>>[
          <String, String>{
            'id': 'lookup',
            'title': 'L-lookup',
            'url': 'fushi://shortcut/lookup',
          },
          <String, String>{
            'id': 'video',
            'title': 'L-video',
            'url': 'fushi://shortcut/video',
          },
        ],
        'disabledMessage': 'off',
        // 没发布的 = 模块被关掉的：这两条的固定快捷方式置灰时才说「模块已关闭」。
        'moduleDisabledIds': <String>['books', 'manga'],
      });
    });

    test(
      'repeated rebuilds do not re-send; label or list changes do',
      () async {
        final AppShortcutsPublisher publisher = AppShortcutsPublisher(
          platformSupported: true,
        );
        publisher.sync(
          <AppShortcut>[AppShortcut.books],
          labelOf: label,
          disabledMessage: 'off',
        );
        publisher.sync(
          <AppShortcut>[AppShortcut.books],
          labelOf: label,
          disabledMessage: 'off',
        );
        await pumpEventQueue();
        expect(calls, hasLength(1));

        publisher.sync(
          <AppShortcut>[AppShortcut.books],
          labelOf: (AppShortcut s) => 'Books (ja)',
          disabledMessage: 'off',
        );
        publisher.sync(
          <AppShortcut>[AppShortcut.books, AppShortcut.video],
          labelOf: label,
          disabledMessage: 'off',
        );
        await pumpEventQueue();
        expect(calls, hasLength(3));

        // 界面语言变了、列表没变：置灰提示文案也要跟着重发。
        publisher.sync(
          <AppShortcut>[AppShortcut.books, AppShortcut.video],
          labelOf: label,
          disabledMessage: 'aus',
        );
        await pumpEventQueue();
        expect(calls, hasLength(4));
      },
    );

    test('a failed publish is retried on the next rebuild', () async {
      final AppShortcutsPublisher publisher = AppShortcutsPublisher(
        platformSupported: true,
      );
      failWith = PlatformException(code: 'rate_limited');
      publisher.sync(
        <AppShortcut>[AppShortcut.books],
        labelOf: label,
        disabledMessage: 'off',
      );
      await pumpEventQueue();
      failWith = null;
      publisher.sync(
        <AppShortcut>[AppShortcut.books],
        labelOf: label,
        disabledMessage: 'off',
      );
      await pumpEventQueue();
      expect(calls, hasLength(2));
    });

    test('unsupported platforms never touch the channel', () async {
      AppShortcutsPublisher(
        platformSupported: false,
      ).sync(AppShortcut.values, labelOf: label, disabledMessage: 'off');
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

  // 通道载荷是 {items, disabledMessage, moduleDisabledIds}：两端都得按这个形状取，
  // Android 还要把不再提供的固定快捷方式置灰（setDynamicShortcuts 删不掉它们）。
  // 只有模块关闭的那些用「模块已关闭」文案；已下线的旧 id（游戏库 / 设置）给
  // null，走启动器默认文案。
  test('native sides read the shortcut payload', () {
    final String activity = File(
      'android/app/src/main/java/app/fushi/reader/MainActivity.java',
    ).readAsStringSync();
    expect(activity, contains('call.argument("items")'));
    expect(activity, contains('call.argument("disabledMessage")'));
    expect(activity, contains('call.argument("moduleDisabledIds")'));
    final String helper = File(
      'android/app/src/main/java/app/fushi/reader/AppShortcutsHelper.java',
    ).readAsStringSync();
    expect(helper, contains('ShortcutManagerCompat.disableShortcuts('));
    expect(helper, contains('ShortcutManagerCompat.enableShortcuts('));
    expect(helper, contains('FLAG_MATCH_PINNED'));
    expect(
      helper,
      contains(
        'ShortcutManagerCompat.disableShortcuts(context, retired, null)',
      ),
    );
    final String swift = File(
      'ios/Runner/AppDelegate.swift',
    ).readAsStringSync();
    expect(swift, contains('args?["items"]'));
  });

  // 页内退出（PopScope）与外部导航收页（ExternalMediaNavigation.closeActive →
  // _closeForSourceReturn）必须共用一把单飞门：漫画页返回回调里 await 退出全屏
  // 期间外部收页可能已经开始，不设门会让落盘 / closeMedia / 自动同步各跑两遍。
  // 外部收页也不得 await 落库（BUG-2119）：挂住就卡死共享导航队列。
  test('source pages share one exit gate with external close', () {
    final String base = File(
      'lib/src/pages/base_source_page.dart',
    ).readAsStringSync();
    final int closeAt = base.indexOf('Future<bool> _closeForSourceReturn()');
    expect(closeAt, greaterThan(0));
    final String close = base.substring(closeAt, closeAt + 1400);
    expect(close, contains('claimSourceExit()'));
    expect(close, contains('exitAfterPersist('));
    expect(close, isNot(contains('await onWillPop()')));
    expect(base, contains('ownsRoute:'));
    for (final String page in <String>[
      'lib/src/media/manga/reader/manga_fushi_page.dart',
      'lib/src/pages/implementations/reader_pdf_page.dart',
    ]) {
      final String src = File(page).readAsStringSync();
      final int popAt = src.indexOf('onPopInvokedWithResult:');
      final int exitAt = src.indexOf('exitAfterPersist(', popAt);
      final String handler = src.substring(popAt, exitAt);
      expect(
        handler,
        contains('if (!claimSourceExit()) return;'),
        reason: page,
      );
    }
    final String reader = File(
      'lib/src/pages/implementations/reader_fushi_page.dart',
    ).readAsStringSync();
    expect(reader, contains('bool claimSourceExit() {'));
    expect(
      File(
        'lib/src/pages/implementations/video_fushi_page.dart',
      ).readAsStringSync(),
      contains('ownsRoute: _ownsRouteForExternalNavigation'),
    );
  });
}
