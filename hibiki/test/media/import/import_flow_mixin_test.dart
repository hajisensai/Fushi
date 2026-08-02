import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/import/import_flow_mixin.dart';
import 'package:hibiki/utils.dart';

import '../../helpers/source_guard.dart';

/// 最小宿主：把 [ImportFlowMixin] 接进来，按 `importing` 渲染进度块，
/// 用以验证 mixin 的写入器 + 渲染契约（书/有声书/视频导入对话框共享的真行为），
/// 以及 [ImportFlowMixin.runImport] 模板的错误处理契约（审计 §1-K / BUG-1117：
/// 失败必有日志 + 提示、importing 必复位、异常绝不逃逸 async zone）。
class _ProbeHost extends StatefulWidget {
  const _ProbeHost();

  @override
  State<_ProbeHost> createState() => _ProbeHostState();
}

class _ProbeHostState extends State<_ProbeHost>
    with ImportFlowMixin<_ProbeHost> {
  /// 测试夹具：在不触碰 protected `setState` 的前提下切换 importing 并重建。
  void setImporting(bool value) => setState(() => importing = value);

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (importing) ...buildProgressSection(context, tokens),
      ],
    );
  }
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  testWidgets('reportProgress writes through to the progress notifiers',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildApp(const _ProbeHost()));
    final _ProbeHostState state =
        tester.state<_ProbeHostState>(find.byType(_ProbeHost));

    expect(state.progress.value, 0);
    expect(state.progressMsg.value, '');

    state.reportProgress(0.42, 'copying file');
    expect(state.progress.value, 0.42);
    expect(state.progressMsg.value, 'copying file');
  });

  testWidgets(
      'buildProgressSection renders LinearProgressIndicator + message '
      'only while importing', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp(const _ProbeHost()));
    final _ProbeHostState state =
        tester.state<_ProbeHostState>(find.byType(_ProbeHost));

    // importing=false（默认）：进度块不渲染。
    expect(find.byType(LinearProgressIndicator), findsNothing);

    // 进入 importing 并写进度文案 → 进度条 + 文案出现。
    state.reportProgress(0.5, 'half way');
    state.setImporting(true);
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('half way'), findsOneWidget);
  });

  testWidgets(
      'buildProgressSection returns a spreadable list (no extra '
      'Column layer)', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp(const _ProbeHost()));
    final _ProbeHostState state =
        tester.state<_ProbeHostState>(find.byType(_ProbeHost));

    final List<Widget> section = state.buildProgressSection(
      state.context,
      HibikiDesignTokens.of(state.context),
    );
    // 间距 + 进度条 + 间距 + 文案 = 4 个 widget，直接 spread 进父 Column，
    // 不包额外布局层（保持抽取前的渲染树等价）。
    expect(section, hasLength(4));
    expect(section[1], isA<ValueListenableBuilder<double>>());
    expect(section[3], isA<ValueListenableBuilder<String>>());
  });

  group('runImport template (BUG-1117 pattern, structured)', () {
    testWidgets('success path: importing flips on then off, no log entry',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp(const _ProbeHost()));
      final _ProbeHostState state =
          tester.state<_ProbeHostState>(find.byType(_ProbeHost));
      final int entriesBefore = ErrorLogService.instance.entries.length;

      bool sawImportingDuringAction = false;
      await state.runImport(
        logTag: 'ImportFlowMixinTest.success',
        action: () async {
          sawImportingDuringAction = state.importing;
        },
      );
      await tester.pump();

      expect(sawImportingDuringAction, isTrue,
          reason: 'action 执行期间 importing 必须已置位（禁用按钮/亮 spinner）');
      expect(state.importing, isFalse, reason: 'finally 必须复位 importing');
      expect(
        ErrorLogService.instance.entries.length,
        entriesBefore,
        reason: '成功路径不落错误日志',
      );
    });

    testWidgets(
        'failure path: exception is caught (never escapes the zone), '
        'logged with the tag, and importing is reset',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp(const _ProbeHost()));
      final _ProbeHostState state =
          tester.state<_ProbeHostState>(find.byType(_ProbeHost));
      final int entriesBefore = ErrorLogService.instance.entries.length;

      await state.runImport(
        logTag: 'ImportFlowMixinTest.failure',
        action: () async => throw StateError('boom'),
      );
      await tester.pump();

      // 模板核心：异常绝不逃逸 async zone（BUG-1117 的病灶）。
      expect(tester.takeException(), isNull);
      // 失败必有日志（用户可在错误日志页看到，而非完全静默）。
      expect(
        ErrorLogService.instance.entries.skip(entriesBefore).any(
            (ErrorLogEntry e) => e.source == 'ImportFlowMixinTest.failure'),
        isTrue,
      );
      // finally 复位 importing：按钮恢复可用、spinner 消失（不再卡住）。
      expect(state.importing, isFalse);
    });

    testWidgets(
        'cancellation path: isCancelled routes to onCancelled without '
        'logging an error', (WidgetTester tester) async {
      await tester.pumpWidget(buildApp(const _ProbeHost()));
      final _ProbeHostState state =
          tester.state<_ProbeHostState>(find.byType(_ProbeHost));
      final int entriesBefore = ErrorLogService.instance.entries.length;

      bool cancelled = false;
      await state.runImport(
        logTag: 'ImportFlowMixinTest.cancel',
        isCancelled: (Object e) => e is StateError,
        onCancelled: () => cancelled = true,
        action: () async => throw StateError('user cancelled'),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(cancelled, isTrue);
      expect(
        ErrorLogService.instance.entries.length,
        entriesBefore,
        reason: '用户主动取消不算错误，不落日志',
      );
      expect(state.importing, isFalse);
    });

    test('failure path shows a toast (source scan)', () {
      // HibikiToast 桌面实现挂在真实 app 的 navigator overlay 上，widget 测试
      // 环境不可达——「失败必有提示」这半边契约用源码扫描锁住（「失败必有日志」
      // 半边在上面的 widget 测试已验真行为）。测试 cwd 是 hibiki/，相对路径稳定。
      final String source = File('lib/src/media/import/import_flow_mixin.dart')
          .readAsStringSync();
      expect(
        RegExp(r'ErrorLogService\.instance\.log\(logTag').hasMatch(source),
        isTrue,
        reason: 'runImport 的 catch 必须以 logTag 落 ErrorLogService',
      );
      expect(
        compactCode(source).contains(
          compactCode(r"HibikiToast.show(msg: '${t.srt_import_error}: $e',"),
        ),
        isTrue,
        reason: 'runImport 的 catch 必须给用户失败提示（toast）',
      );
    });
  });
}
