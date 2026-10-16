import 'package:material_ui/material_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/settings/nav_module_order_list.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/utils.dart';

import '../../integration_test/helpers/focus_driver.dart';
import '../helpers/test_platform_services.dart';

/// 导航模块排序列表的非指针路径：拖拽只吃鼠标 / 触屏，键盘、手柄与读屏只能靠
/// 每行的「上移 / 下移」按钮和同名无障碍自定义动作。外加落库失败时乐观顺序
/// 必须撤掉（否则列表永远显示一个没存上的顺序）。
void main() {
  const List<ModuleId> shown = <ModuleId>[
    ModuleId.home,
    ModuleId.books,
    ModuleId.video,
  ];

  late _OrderAppModel appModel;

  Future<void> pumpList(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) {
                final SettingsContext sctx = SettingsContext(
                  context: context,
                  appModel: appModel,
                  ref: ref,
                  readerSource: ReaderFushiSource.instance,
                  refresh: () {},
                );
                return SingleChildScrollView(
                  child: StatefulBuilder(
                    builder: (BuildContext context, StateSetter setState) {
                      appModel.rebuild = () => setState(() {});
                      return NavModuleOrderList(
                        settingsContext: sctx,
                        modules: <ModuleId>[
                          for (final ModuleId m in appModel.moduleOrder)
                            if (shown.contains(m)) m,
                        ],
                        identityOf: (ModuleId m) =>
                            (label: m.name, icon: Icons.circle),
                        onEnabledChanged: (ModuleId m, bool v) async {},
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  List<String> visibleTitles(WidgetTester tester) {
    final List<String> titles = <String>[];
    for (final ModuleId m in shown) {
      final Finder row = find.byKey(
        ValueKey<String>('nav-module-row-${m.name}'),
      );
      titles.add('${tester.getTopLeft(row).dy.round()}:${m.name}');
    }
    titles.sort(
      (String a, String b) => int.parse(
        a.split(':').first,
      ).compareTo(int.parse(b.split(':').first)),
    );
    return <String>[for (final String s in titles) s.split(':').last];
  }

  /// Tab 遍历直到主焦点**落在 [button] 子树里**。不用 FocusDriver.focusWidget：
  /// 它在「目标在焦点子树里」时也算到达，而按钮就在可聚焦的整行里面——焦点停在
  /// 整行上它也返回 true，Enter 翻的却是整行的开关。
  Future<bool> focusButton(FocusDriver driver, Finder button) {
    bool inside() {
      final BuildContext? ctx = FocusManager.instance.primaryFocus?.context;
      if (ctx == null) return false;
      final Set<Element> targets = button.evaluate().toSet();
      if (targets.contains(ctx)) return true;
      bool found = false;
      ctx.visitAncestorElements((Element e) {
        if (targets.contains(e)) {
          found = true;
          return false;
        }
        return true;
      });
      return found;
    }

    return driver.focusUntil(inside);
  }

  setUp(() {
    appModel = _OrderAppModel(<ModuleId>[...shown]);
  });

  testWidgets('首行上移 / 末行下移禁用，其余可用', (WidgetTester tester) async {
    await pumpList(tester);
    bool enabledOf(String key) => tester
        .widget<FushiIconButton>(find.byKey(ValueKey<String>(key)))
        .enabled;
    expect(enabledOf('nav-module-up-home'), isFalse);
    expect(enabledOf('nav-module-down-home'), isTrue);
    expect(enabledOf('nav-module-up-books'), isTrue);
    expect(enabledOf('nav-module-down-books'), isTrue);
    expect(enabledOf('nav-module-up-video'), isTrue);
    expect(enabledOf('nav-module-down-video'), isFalse);
  });

  testWidgets('上移 / 下移按钮命中区不小于 48dp', (WidgetTester tester) async {
    await pumpList(tester);
    for (final String key in <String>[
      'nav-module-up-books',
      'nav-module-down-books',
    ]) {
      final Size size = tester.getSize(find.byKey(ValueKey<String>(key)));
      expect(
        size.width,
        greaterThanOrEqualTo(kMinInteractiveDimension),
        reason: key,
      );
      expect(
        size.height,
        greaterThanOrEqualTo(kMinInteractiveDimension),
        reason: key,
      );
    }
  });

  testWidgets('焦点移到「下移」按 Enter：该行与下一行对调并落库', (WidgetTester tester) async {
    await pumpList(tester);
    final FocusDriver driver = FocusDriver(tester);
    expect(
      await focusButton(
        driver,
        find.byKey(const ValueKey<String>('nav-module-down-home')),
      ),
      isTrue,
      reason: '「下移」按钮必须可经焦点遍历到达',
    );
    await driver.activate();
    await tester.pump();
    expect(appModel.saved, hasLength(1));
    expect(appModel.saved.single.where(shown.contains).toList(), <ModuleId>[
      ModuleId.books,
      ModuleId.home,
      ModuleId.video,
    ]);
    expect(visibleTitles(tester), <String>['books', 'home', 'video']);
  });

  testWidgets('焦点移到「上移」按 Enter：该行与上一行对调', (WidgetTester tester) async {
    await pumpList(tester);
    final FocusDriver driver = FocusDriver(tester);
    expect(
      await focusButton(
        driver,
        find.byKey(const ValueKey<String>('nav-module-up-video')),
      ),
      isTrue,
    );
    await driver.activate();
    await tester.pump();
    expect(appModel.saved.single.where(shown.contains).toList(), <ModuleId>[
      ModuleId.home,
      ModuleId.video,
      ModuleId.books,
    ]);
  });

  testWidgets('读屏自定义动作：中间行有上移 / 下移，首末行各只有一个方向', (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await pumpList(tester);
    Set<String> actionsOf(ModuleId m) {
      final SemanticsNode node = tester.getSemantics(
        find.byKey(ValueKey<String>('nav-module-semantics-${m.name}')),
      );
      final SemanticsData data = node.getSemanticsData();
      return <String>{
        for (final int id in data.customSemanticsActionIds ?? <int>[])
          CustomSemanticsAction.getAction(id)!.label!,
      };
    }

    expect(actionsOf(ModuleId.home), <String>{t.move_down});
    expect(actionsOf(ModuleId.books), <String>{t.move_up, t.move_down});
    expect(actionsOf(ModuleId.video), <String>{t.move_up});

    // 真触发「上移」：books 与 home 对调。
    final SemanticsNode books = tester.getSemantics(
      find.byKey(const ValueKey<String>('nav-module-semantics-books')),
    );
    final int upId = books
        .getSemanticsData()
        .customSemanticsActionIds!
        .firstWhere(
          (int id) => CustomSemanticsAction.getAction(id)!.label == t.move_up,
        );
    tester.binding.pipelineOwner.semanticsOwner!.performAction(
      books.id,
      SemanticsAction.customAction,
      upId,
    );
    await tester.pump();
    expect(appModel.saved.single.where(shown.contains).toList(), <ModuleId>[
      ModuleId.books,
      ModuleId.home,
      ModuleId.video,
    ]);
    handle.dispose();
  });

  testWidgets('落库抛异常：乐观顺序撤回，列表回到存储真值', (WidgetTester tester) async {
    appModel.failNextSave = true;
    await pumpList(tester);
    final FocusDriver driver = FocusDriver(tester);
    expect(
      await focusButton(
        driver,
        find.byKey(const ValueKey<String>('nav-module-down-home')),
      ),
      isTrue,
    );
    await driver.activate();
    await tester.pump();
    expect(tester.takeException(), isA<StateError>());
    await tester.pump();
    expect(appModel.saved, isEmpty);
    expect(visibleTitles(tester), <String>[
      'home',
      'books',
      'video',
    ], reason: '没存上的顺序不能继续挂在列表上');
  });
}

class _OrderAppModel extends AppModel {
  _OrderAppModel(this._order) : super(testPlatformServices());

  List<ModuleId> _order;
  final List<List<ModuleId>> saved = <List<ModuleId>>[];
  bool failNextSave = false;
  VoidCallback rebuild = () {};

  @override
  List<ModuleId> get moduleOrder => orderModules(_order);

  @override
  ModuleVisibility get moduleVisibility =>
      ModuleVisibility(ModuleId.values.toSet(), order: _order);

  @override
  bool moduleEnabled(ModuleId module) => true;

  @override
  Future<void> setModuleOrder(List<ModuleId> order) async {
    if (failNextSave) {
      failNextSave = false;
      throw StateError('disk full');
    }
    saved.add(order);
    _order = order;
    rebuild();
  }
}
