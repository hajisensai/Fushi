import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/settings/material_settings_renderer.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/settings/settings_search.dart';

import '../helpers/test_platform_services.dart';

/// 设置页重建范围守卫（设置页掉帧根因修复的回归门）。
///
/// 实测（test/settings/settings_frame_perf_probe_test.dart）的掉帧来源都是「一个
/// 局部变化把整页设置行重建一遍」：
/// 1. 进详情页：跳转条尺寸动画 + 页头高度逐帧回报 → 壳逐帧 setState → 正文
///    bodyBuilder 逐帧重建全部行（视频页 ~20 帧 × 43 行）；
/// 2. 滚动跨过分组边界：scroll spy 通知 → 壳 setState → 全部行重建；
/// 3. 日志 / hook 准入 / 下载阶段等外部事件：宿主页整页 setState；
/// 4. 切开关 / 拖滑条：refresh = 宿主整页 setState → 全部行重新派发。
///
/// 这里钉住修复后的重建范围：上面四种变化都只重建真正变化的那一小块。行重建
/// 按每行外层的 [SettingsSearchTarget] 计数。
void main() {
  late Map<String, bool> values;
  late ValueNotifier<bool> live;
  late int hostBuilds;
  late int rowBuilds;
  late VoidCallback refreshHost;

  SettingsSection section(String name, {bool withLive = false}) =>
      SettingsSection(
        id: 'perf.$name',
        title: 'Section $name',
        liveListenable: withLive ? (_) => live : null,
        items: <SettingsItem>[
          for (int i = 0; i < 8; i++)
            SettingsSwitchItem(
              id: 'perf.$name.$i',
              title: 'Toggle $name$i',
              value: (_) => values['$name$i'] ?? false,
              onChanged: (SettingsContext ctx, bool value) {
                values['$name$i'] = value;
              },
            ),
          if (withLive)
            SettingsSwitchItem(
              id: 'perf.$name.live',
              title: 'Live row',
              visible: (_) => live.value,
              value: (_) => false,
              onChanged: (SettingsContext ctx, bool value) {},
            ),
        ],
      );

  final SettingsDestination destination = SettingsDestination(
    id: SettingsDestinationId.appearance,
    title: 'Perf',
    icon: Icons.tune,
    sections: <SettingsSection>[
      section('A'),
      section('B', withLive: true),
      section('C'),
      section('D'),
    ],
  );

  Widget harness(AppModel appModel) {
    return ProviderScope(
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Consumer(
          builder: (BuildContext context, WidgetRef ref, _) => StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              hostBuilds++;
              refreshHost = () => setState(() {});
              final SettingsContext settingsContext = SettingsContext(
                context: context,
                appModel: appModel,
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () => setState(() {}),
              );
              return const MaterialSettingsRenderer().buildDetailPage(
                settingsContext: settingsContext,
                destination: destination,
              );
            },
          ),
        ),
      ),
    );
  }

  setUp(() {
    values = <String, bool>{};
    live = ValueNotifier<bool>(false);
    hostBuilds = 0;
    rowBuilds = 0;
    debugOnRebuildDirtyWidget = (Element element, bool builtOnce) {
      if (element.widget is SettingsSearchTarget) rowBuilds++;
    };
  });

  tearDown(() {
    debugOnRebuildDirtyWidget = null;
    live.dispose();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 800);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    await tester.pumpWidget(harness(AppModel(testPlatformServices())));
  }

  testWidgets('进详情页：跳转条 / 页头尺寸动画期间不重建设置行', (WidgetTester tester) async {
    await pumpPage(tester);
    final int firstFrameRows = rowBuilds;
    expect(firstFrameRows, greaterThanOrEqualTo(32), reason: '首帧建出全部行');
    rowBuilds = 0;
    // 逐帧推进整段进场：跳转条出现（尺寸过渡）+ 页头 / 跳转条高度逐帧回报。
    for (int i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      find.byWidgetPredicate(
        (Widget w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('settings-jump.'),
      ),
      findsWidgets,
      reason: '≥ 2 个带标题分组时跳转条应已出现（前提成立，下面的 0 才有意义）',
    );
    expect(
      rowBuilds,
      0,
      reason:
          '让位高度逐帧变化只该重建 MediaQuery 让位层与读让位的滚动视图，'
          '不该把整页设置行逐帧重建（修复前每帧重建全部行）',
    );
    expect(hostBuilds, 1);
  });

  testWidgets('滚动跨过分组边界：只刷新页头副标题与跳转条，不重建设置行', (WidgetTester tester) async {
    await pumpPage(tester);
    await tester.pumpAndSettle();
    rowBuilds = 0;
    final TestGesture gesture = await tester.startGesture(
      const Offset(210, 600),
    );
    for (int i = 0; i < 40; i++) {
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(SettingsFloatingHeader),
        matching: find.textContaining('Section'),
      ),
      findsOneWidget,
      reason: '滚过分组后页头应粘着当前分组名（spy 确实触发过）',
    );
    expect(
      find.descendant(
        of: find.byType(SettingsFloatingHeader),
        matching: find.text('Section A'),
      ),
      findsNothing,
      reason: '已滚离第一个分组',
    );
    expect(rowBuilds, 0, reason: 'scroll spy 变化不该把整页设置行重建一遍');
  });

  testWidgets('切一个开关：宿主 refresh 只重建这一行', (WidgetTester tester) async {
    await pumpPage(tester);
    await tester.pumpAndSettle();
    final Finder row = find.byKey(const ValueKey<String>('perf.A.2'));
    await Scrollable.ensureVisible(tester.element(row), alignment: 0.5);
    await tester.pumpAndSettle();
    rowBuilds = 0;
    final int hostBefore = hostBuilds;
    await tester.tap(find.text('Toggle A2'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(values['A2'], isTrue, reason: '开关确实切了');
    expect(hostBuilds, greaterThan(hostBefore), reason: 'refresh 确实重建了宿主');
    expect(rowBuilds, 1, reason: '其余行的渲染输入没变，应命中记忆化、不重建（修复前整页每行都重建）');
  });

  testWidgets('外部事件源（liveListenable）只重建所在分组并重算可见性', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('perf.B.live')), findsNothing);
    final int hostBefore = hostBuilds;
    rowBuilds = 0;
    live.value = true;
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('perf.B.live'), skipOffstage: false),
      findsOneWidget,
      reason: '事件后被过滤掉的行要能重新出现',
    );
    expect(hostBuilds, hostBefore, reason: '外部事件不再整页 setState 宿主');
    expect(
      rowBuilds,
      lessThanOrEqualTo(1),
      reason: '只有新出现的那一行真建；同组其余行命中记忆化，别组不受影响',
    );
    // 未刷新宿主时也能收回去。
    live.value = false;
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('perf.B.live'), skipOffstage: false),
      findsNothing,
    );
    // 宿主重建后订阅仍在（ListenableBuilder 跟着新 section 实例重新订阅）。
    refreshHost();
    await tester.pumpAndSettle();
    live.value = true;
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('perf.B.live'), skipOffstage: false),
      findsOneWidget,
    );
  });
}
