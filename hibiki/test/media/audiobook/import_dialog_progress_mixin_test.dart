import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/import_dialog_progress_mixin.dart';
import 'package:hibiki/utils.dart';

/// 最小宿主：把 [ImportDialogProgressMixin] 接进来，按 `importing` 渲染进度块，
/// 用以验证 mixin 的写入器 + 渲染契约（书/有声书两对话框共享的真行为）。
class _ProbeHost extends StatefulWidget {
  const _ProbeHost();

  @override
  State<_ProbeHost> createState() => _ProbeHostState();
}

class _ProbeHostState extends State<_ProbeHost>
    with ImportDialogProgressMixin<_ProbeHost> {
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
}
