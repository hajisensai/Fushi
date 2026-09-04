import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/desktop_oauth.dart';
import 'package:fushi/src/sync/desktop_oauth_wait_dialog.dart';

/// BUG-2120：桌面 loopback 等待对话框的三个动作必须各自真的落到句柄上，
/// 且对话框的生命周期钉在 `done` 上——流程没结束前它不消失，流程一结束它必消失。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final Uri authUrl = Uri.parse(
    'https://accounts.example.test/o/oauth2/auth?client_id=x&scope=a+b',
  );
  final List<MethodCall> platformCalls = <MethodCall>[];

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    platformCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
      MethodCall call,
    ) async {
      platformCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpDialog(
    WidgetTester tester, {
    required DesktopOAuthLaunch launch,
    required Future<void> done,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext ctx) => Scaffold(
              body: TextButton(
                onPressed: () => showDesktopOAuthWaitDialog(
                  context: ctx,
                  launch: launch,
                  done: done,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('展示链接；「复制登录链接」把 authUrl 原样写进剪贴板', (WidgetTester tester) async {
    final Completer<void> done = Completer<void>();
    await pumpDialog(
      tester,
      launch: DesktopOAuthLaunch(
        authUrl: authUrl,
        reopenBrowser: () async => true,
        cancel: () {},
      ),
      done: done.future,
    );

    expect(find.byType(DesktopOAuthWaitDialog), findsOneWidget);
    expect(find.text(t.sync_desktop_oauth_waiting_title), findsOneWidget);
    expect(find.textContaining(authUrl.toString()), findsOneWidget);

    await tester.tap(find.text(t.sync_desktop_oauth_link_copy));
    await tester.pump();

    final MethodCall setData = platformCalls.firstWhere(
      (MethodCall c) => c.method == 'Clipboard.setData',
    );
    expect((setData.arguments as Map)['text'], authUrl.toString());
    // 复制不结束流程：对话框留在原地继续等。
    expect(find.byType(DesktopOAuthWaitDialog), findsOneWidget);

    done.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('「重新打开浏览器」落到 reopenBrowser', (WidgetTester tester) async {
    final Completer<void> done = Completer<void>();
    int reopened = 0;
    await pumpDialog(
      tester,
      launch: DesktopOAuthLaunch(
        authUrl: authUrl,
        reopenBrowser: () async {
          reopened++;
          return true;
        },
        cancel: () {},
      ),
      done: done.future,
    );

    await tester.tap(find.text(t.sync_desktop_oauth_browser_reopen));
    await tester.pump();
    expect(reopened, 1);
    expect(find.byType(DesktopOAuthWaitDialog), findsOneWidget);

    done.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('「取消」只调 cancel，对话框直到 done 完成才关闭', (WidgetTester tester) async {
    final Completer<void> done = Completer<void>();
    int cancelled = 0;
    await pumpDialog(
      tester,
      launch: DesktopOAuthLaunch(
        authUrl: authUrl,
        reopenBrowser: () async => true,
        cancel: () => cancelled++,
      ),
      done: done.future,
    );

    await tester.tap(find.text(t.cancel));
    await tester.pump();
    expect(cancelled, 1);
    // 关闭由流程收场驱动，不由按钮驱动：流程还没完成，对话框就还在。
    expect(find.byType(DesktopOAuthWaitDialog), findsOneWidget);

    done.complete();
    await tester.pumpAndSettle();
    expect(find.byType(DesktopOAuthWaitDialog), findsNothing);
  });

  testWidgets('系统返回 / 遮罩不能悄悄关掉它：返回等价于取消', (WidgetTester tester) async {
    final Completer<void> done = Completer<void>();
    int cancelled = 0;
    await pumpDialog(
      tester,
      launch: DesktopOAuthLaunch(
        authUrl: authUrl,
        reopenBrowser: () async => true,
        cancel: () => cancelled++,
      ),
      done: done.future,
    );

    // 点遮罩：barrierDismissible=false，对话框纹丝不动。
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopOAuthWaitDialog), findsOneWidget);
    expect(cancelled, 0);

    // 系统返回：PopScope 拦下并转成取消。
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(cancelled, 1);
    expect(find.byType(DesktopOAuthWaitDialog), findsOneWidget);

    done.complete();
    await tester.pumpAndSettle();
    expect(find.byType(DesktopOAuthWaitDialog), findsNothing);
  });

  testWidgets('done 完成即关闭，即使用户什么都没点', (WidgetTester tester) async {
    final Completer<void> done = Completer<void>();
    await pumpDialog(
      tester,
      launch: DesktopOAuthLaunch(
        authUrl: authUrl,
        reopenBrowser: () async => true,
        cancel: () {},
      ),
      done: done.future,
    );
    expect(find.byType(DesktopOAuthWaitDialog), findsOneWidget);

    done.complete();
    await tester.pumpAndSettle();
    expect(find.byType(DesktopOAuthWaitDialog), findsNothing);
  });
}
