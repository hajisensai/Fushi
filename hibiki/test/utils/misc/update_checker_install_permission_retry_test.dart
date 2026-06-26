import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

/// BUG-427/TODO-852: Android 安装权限授予后无法续接/重试安装。
///
/// 修复后 Dart 侧契约（UpdateChecker.applyWithInstallRetryForTest 暴露内部
/// _applyWithInstallRetry）：
///   * apply 抛 PlatformException(INSTALL_PERMISSION_REQUIRED) → 隐藏遮罩、
///     弹重试对话框、点重试用「同一个 apkFile」重调 apply（绝不重下）。
///   * 取消重试 → apply 只调一次、不 rethrow（apk 留缓存）。
///   * 非该 code 的 PlatformException → rethrow，走原「下载失败」路径。
/// 关键回归：续接重试期间不得弹 update_download_failed（旧实现把权限码当下载失败吞）。
class _FakeUpdater extends PlatformUpdater {
  _FakeUpdater({required this.failuresBeforeSuccess, this.errorCode});

  /// 前 N 次 apply 抛错（errorCode），第 N+1 次成功。
  int failuresBeforeSuccess;
  final String? errorCode;

  final List<String> appliedPaths = <String>[];

  @override
  bool get supportsUpdateCheck => true;

  @override
  bool get supportsInAppInstall => true;

  @override
  Future<UpdateAsset?> selectAsset(
    List<Map<String, dynamic>> assets, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async =>
      null;

  @override
  Future<void> apply(File file, String version) async {
    appliedPaths.add(file.path);
    if (failuresBeforeSuccess > 0) {
      failuresBeforeSuccess -= 1;
      throw PlatformException(
        code: errorCode ?? 'INSTALL_PERMISSION_REQUIRED',
        message: 'permission required',
      );
    }
  }
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Future<BuildContext> pumpContext(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(builder: (BuildContext context) {
              ctx = context;
              return const SizedBox.shrink();
            }),
          ),
        ),
      ),
    );
    return ctx;
  }

  testWidgets('首次权限被拒、重试后成功：apply 调 2 次且 apk 路径一致（不重下）',
      (WidgetTester tester) async {
    final _FakeUpdater updater = _FakeUpdater(failuresBeforeSuccess: 1);
    final ValueNotifier<bool> overlayVisible = ValueNotifier<bool>(true);
    final ValueNotifier<String> status =
        ValueNotifier<String>(t.update_installing);
    addTearDown(overlayVisible.dispose);
    addTearDown(status.dispose);

    final BuildContext ctx = await pumpContext(tester);
    final Future<void> fut = UpdateChecker.applyWithInstallRetryForTest(
      context: ctx,
      updater: updater,
      apkFile: File('/tmp/hibiki-9.9.9-arm64-v8a.apk'),
      version: '9.9.9',
      overlayVisible: overlayVisible,
      status: status,
    );
    await tester.pumpAndSettle();
    expect(find.text(t.update_install_permission_retry), findsOneWidget);
    await tester.tap(find.text(t.update_install_permission_retry));
    await tester.pumpAndSettle();
    await fut;

    expect(updater.appliedPaths.length, 2, reason: 'apply 应被调两次（首拒+重试成功）。');
    expect(updater.appliedPaths[0], updater.appliedPaths[1],
        reason: '两次 apply 必须用同一个 apk 路径，绝不重下。');
    expect(find.textContaining(t.update_download_failed), findsNothing,
        reason:
            'INSTALL_PERMISSION_REQUIRED 不是下载失败，禁止弹 update_download_failed。');
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消重试：apply 只调 1 次、不 rethrow（apk 留缓存）',
      (WidgetTester tester) async {
    final _FakeUpdater updater = _FakeUpdater(failuresBeforeSuccess: 99);
    final ValueNotifier<bool> overlayVisible = ValueNotifier<bool>(true);
    final ValueNotifier<String> status =
        ValueNotifier<String>(t.update_installing);
    addTearDown(overlayVisible.dispose);
    addTearDown(status.dispose);

    final BuildContext ctx = await pumpContext(tester);
    final Future<void> fut = UpdateChecker.applyWithInstallRetryForTest(
      context: ctx,
      updater: updater,
      apkFile: File('/tmp/hibiki-9.9.9-arm64-v8a.apk'),
      version: '9.9.9',
      overlayVisible: overlayVisible,
      status: status,
    );
    await tester.pumpAndSettle();
    expect(find.text(t.update_install_permission_cancel), findsOneWidget);
    await tester.tap(find.text(t.update_install_permission_cancel));
    await tester.pumpAndSettle();
    await fut;

    expect(updater.appliedPaths.length, 1, reason: '取消后不再重试，apply 只一次。');
    expect(overlayVisible.value, isFalse, reason: '权限被拒后遮罩应隐藏（让对话框无遮挡）。');
    expect(tester.takeException(), isNull, reason: '取消是正常退出，不应 rethrow 抛错。');
  });

  testWidgets('非目标 code 的 PlatformException 应 rethrow（走原下载失败路径）',
      (WidgetTester tester) async {
    final _FakeUpdater updater =
        _FakeUpdater(failuresBeforeSuccess: 1, errorCode: 'INSTALL_ERROR');
    final ValueNotifier<bool> overlayVisible = ValueNotifier<bool>(true);
    final ValueNotifier<String> status =
        ValueNotifier<String>(t.update_installing);
    addTearDown(overlayVisible.dispose);
    addTearDown(status.dispose);

    final BuildContext ctx = await pumpContext(tester);
    Object? thrown;
    try {
      await UpdateChecker.applyWithInstallRetryForTest(
        context: ctx,
        updater: updater,
        apkFile: File('/tmp/hibiki-9.9.9-arm64-v8a.apk'),
        version: '9.9.9',
        overlayVisible: overlayVisible,
        status: status,
      );
    } catch (e) {
      thrown = e;
    }

    expect(thrown, isA<PlatformException>(),
        reason: '非 INSTALL_PERMISSION_REQUIRED 必须 rethrow。');
    expect((thrown! as PlatformException).code, 'INSTALL_ERROR');
    expect(updater.appliedPaths.length, 1, reason: '只 apply 一次即抛出，不重试。');
    expect(find.text(t.update_install_permission_retry), findsNothing,
        reason: '非权限码不应弹权限重试对话框。');
  });

  testWidgets('重试对话框弹出后标题/重试/取消三按钮俱在（未被遮罩吞掉）', (WidgetTester tester) async {
    final _FakeUpdater updater = _FakeUpdater(failuresBeforeSuccess: 1);
    final ValueNotifier<bool> overlayVisible = ValueNotifier<bool>(true);
    final ValueNotifier<String> status =
        ValueNotifier<String>(t.update_installing);
    addTearDown(overlayVisible.dispose);
    addTearDown(status.dispose);

    final BuildContext ctx = await pumpContext(tester);
    final Future<void> fut = UpdateChecker.applyWithInstallRetryForTest(
      context: ctx,
      updater: updater,
      apkFile: File('/tmp/hibiki-9.9.9-arm64-v8a.apk'),
      version: '9.9.9',
      overlayVisible: overlayVisible,
      status: status,
    );
    await tester.pumpAndSettle();

    expect(find.text(t.update_install_permission_title), findsOneWidget);
    expect(find.text(t.update_install_permission_retry), findsOneWidget);
    expect(find.text(t.update_install_permission_cancel), findsOneWidget);

    await tester.tap(find.text(t.update_install_permission_retry));
    await tester.pumpAndSettle();
    await fut;
  });
}
