import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/desktop_oauth.dart';
import 'package:fushi/src/sync/desktop_oauth_wait_dialog.dart';

/// BUG-2120：桌面 loopback 等待对话框的三个动作必须各自真的落到句柄上；关闭由
/// `launch.finished` / `done` 两个信号驱动且按**自己的路由身份**移除（不弹栈顶）；
/// Esc 必须真的取消（`barrierDismissible: false` 会让框架的 DismissIntent 处理器失效，
/// 靠 PopScope 是接不到的）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final Uri authUrl = Uri.parse(
      'https://accounts.example.test/o/oauth2/auth?client_id=x&scope=a+b');
  final List<MethodCall> platformCalls = <MethodCall>[];
  bool clipboardThrows = false;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    platformCalls.clear();
    clipboardThrows = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform,
            (MethodCall call) async {
      platformCalls.add(call);
      if (clipboardThrows && call.method == 'Clipboard.setData') {
        throw PlatformException(
            code: 'Clipboard error', message: 'Unable to open clipboard');
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  /// 造一个假句柄；默认浏览器已打开、回环未结束。
  DesktopOAuthLaunch fakeLaunch({
    Future<bool>? browserOpened,
    Future<void>? finished,
    Future<bool> Function()? reopen,
    void Function()? cancel,
  }) =>
      DesktopOAuthLaunch(
        authUrl: authUrl,
        browserOpened: browserOpened ?? Future<bool>.value(true),
        finished: finished ?? Completer<void>().future,
        reopenBrowser: reopen ?? () async => true,
        cancel: cancel ?? () {},
      );

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

  Finder dialog() => find.byType(DesktopOAuthWaitDialog);

  testWidgets('展示完整链接；「复制登录链接」把 authUrl 原样写进剪贴板', (WidgetTester tester) async {
    final Completer<void> done = Completer<void>();
    await pumpDialog(tester, launch: fakeLaunch(), done: done.future);

    expect(dialog(), findsOneWidget);
    expect(find.text(t.sync_desktop_oauth_waiting_title), findsOneWidget);
    // 全文露出：截断的 URL 贴进浏览器得到的正是 400 页。
    final SelectableText urlText = tester.widget<SelectableText>(
        find.widgetWithText(SelectableText, authUrl.toString()));
    expect(urlText.maxLines, isNull);
    expect(find.text(t.sync_desktop_oauth_browser_open_failed), findsNothing);

    await tester.tap(find.text(t.sync_desktop_oauth_link_copy));
    await tester.pump();

    final MethodCall setData = platformCalls
        .firstWhere((MethodCall c) => c.method == 'Clipboard.setData');
    expect((setData.arguments as Map)['text'], authUrl.toString());
    expect(dialog(), findsOneWidget, reason: '复制不结束流程');

    done.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('剪贴板抛 PlatformException：不崩、对话框留着让用户手动选中',
      (WidgetTester tester) async {
    clipboardThrows = true;
    final Completer<void> done = Completer<void>();
    await pumpDialog(tester, launch: fakeLaunch(), done: done.future);

    await tester.tap(find.text(t.sync_desktop_oauth_link_copy));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(dialog(), findsOneWidget);

    done.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('「重新打开浏览器」落到 reopenBrowser；拉不起来时露出提示',
      (WidgetTester tester) async {
    final Completer<void> done = Completer<void>();
    int reopened = 0;
    bool reopenResult = true;
    await pumpDialog(
      tester,
      launch: fakeLaunch(reopen: () async {
        reopened++;
        return reopenResult;
      }),
      done: done.future,
    );

    await tester.tap(find.text(t.sync_desktop_oauth_browser_reopen));
    await tester.pump();
    expect(reopened, 1);
    expect(find.text(t.sync_desktop_oauth_browser_open_failed), findsNothing);

    reopenResult = false;
    await tester.tap(find.text(t.sync_desktop_oauth_browser_reopen));
    await tester.pump();
    expect(reopened, 2);
    expect(tester.takeException(), isNull);
    expect(find.text(t.sync_desktop_oauth_browser_open_failed), findsOneWidget);
    expect(dialog(), findsOneWidget);

    done.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('首次拉起浏览器失败（browserOpened=false）：对话框照常出现并提示复制链接',
      (WidgetTester tester) async {
    final Completer<void> done = Completer<void>();
    final Completer<bool> opened = Completer<bool>();
    await pumpDialog(
      tester,
      launch: fakeLaunch(browserOpened: opened.future),
      done: done.future,
    );
    expect(find.text(t.sync_desktop_oauth_browser_open_failed), findsNothing);

    opened.complete(false);
    await tester.pumpAndSettle();
    expect(find.text(t.sync_desktop_oauth_browser_open_failed), findsOneWidget);
    expect(find.text(t.sync_desktop_oauth_link_copy), findsOneWidget);

    done.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('「取消」只调 cancel，对话框直到信号到来才关闭', (WidgetTester tester) async {
    final Completer<void> done = Completer<void>();
    int cancelled = 0;
    await pumpDialog(
      tester,
      launch: fakeLaunch(cancel: () => cancelled++),
      done: done.future,
    );

    await tester.tap(find.text(t.cancel));
    await tester.pump();
    expect(cancelled, 1);
    expect(dialog(), findsOneWidget, reason: '关闭由流程收场驱动，不由按钮驱动');

    done.complete();
    await tester.pumpAndSettle();
    expect(dialog(), findsNothing);
  });

  testWidgets('Esc 真的取消（barrierDismissible=false 下框架的 DismissIntent 不会替我们做）',
      (WidgetTester tester) async {
    final Completer<void> done = Completer<void>();
    int cancelled = 0;
    await pumpDialog(
      tester,
      launch: fakeLaunch(cancel: () => cancelled++),
      done: done.future,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(cancelled, 1, reason: '桌面用户按 Esc 必须等价于点「取消」');
    expect(dialog(), findsOneWidget, reason: '流程没收场前不关');

    done.complete();
    await tester.pumpAndSettle();
    expect(dialog(), findsNothing);
  });

  testWidgets('遮罩点不掉；系统返回等价于取消', (WidgetTester tester) async {
    final Completer<void> done = Completer<void>();
    int cancelled = 0;
    await pumpDialog(
      tester,
      launch: fakeLaunch(cancel: () => cancelled++),
      done: done.future,
    );

    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(dialog(), findsOneWidget);
    expect(cancelled, 0);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(cancelled, 1);
    expect(dialog(), findsOneWidget);

    done.complete();
    await tester.pumpAndSettle();
    expect(dialog(), findsNothing);
  });

  testWidgets('回环等待一结束（finished）就关闭，不等整个登录流程 done',
      (WidgetTester tester) async {
    final Completer<void> done = Completer<void>();
    final Completer<void> finished = Completer<void>();
    await pumpDialog(
      tester,
      launch: fakeLaunch(finished: finished.future),
      done: done.future,
    );
    expect(dialog(), findsOneWidget);

    finished.complete();
    await tester.pumpAndSettle();
    expect(dialog(), findsNothing,
        reason: '授权码已到，之后是 token 交换；「等浏览器」已经过去，重开/取消都没意义');

    // done 之后到来不会二次 pop 掉别的东西。
    done.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('关闭按自己的路由身份移除：上面叠了别的弹窗时不误弹那个弹窗', (WidgetTester tester) async {
    final Completer<void> done = Completer<void>();
    await pumpDialog(tester, launch: fakeLaunch(), done: done.future);

    // 模拟等待期间后台压上来的弹窗（互联配对审批 / 同步冲突都是 barrierDismissible=false）。
    final BuildContext ctx = tester.element(dialog());
    unawaited(showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (BuildContext _) => const AlertDialog(
        key: Key('overlay-dialog'),
        title: Text('pairing approval'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('overlay-dialog')), findsOneWidget);

    done.complete();
    await tester.pumpAndSettle();
    expect(dialog(), findsNothing, reason: '等待框自己必须走');
    expect(find.byKey(const Key('overlay-dialog')), findsOneWidget,
        reason: '后台弹窗不能被吞掉');
  });

  testWidgets('done 完成即关闭，即使用户什么都没点', (WidgetTester tester) async {
    final Completer<void> done = Completer<void>();
    await pumpDialog(tester, launch: fakeLaunch(), done: done.future);
    expect(dialog(), findsOneWidget);

    done.complete();
    await tester.pumpAndSettle();
    expect(dialog(), findsNothing);
  });
}
