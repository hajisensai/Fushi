import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/media_collection_grid_detail_page.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/mouse_binding_dispatch.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi_core/fushi_core.dart';

/// 成员区三种承载：列表行、无筛选时的拖排网格（任何排序下都可拖）、有筛选时
/// 退回的普通网格（[SliverGrid] + 成员格）。三条路径各自接了一份菜单触发，都要
/// 遵循鼠标绑定表。
enum _MemberView { list, reorderGrid, filteredGrid }

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    MouseBindingDispatch.resetForTest();
  });

  for (final _MemberView view in _MemberView.values) {
    final String label = switch (view) {
      _MemberView.list => '列表',
      _MemberView.reorderGrid => '拖排网格',
      _MemberView.filteredGrid => '筛选后普通网格',
    };
    testWidgets('合集$label菜单遵循默认、让位和改绑', (WidgetTester tester) async {
      // 展示 hero、工具条和成员；本例验证鼠标绑定，矮窗删除动作另有行为测试。
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final int id = await db.createMediaCollection('C');
      await db.addToCollection(id, MediaKind.epub, 'k1');
      final MediaCollectionRow collection = (await db.getMediaCollectionById(
        id,
      ))!;
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);
      final List<String> menus = <String>[];
      final List<String> opened = <String>[];
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: ShortcutBindingScope(
              registry: registry,
              child: MediaCollectionGridDetailPage(
                database: db,
                collection: collection,
                memberCardBuilder:
                    (
                      String mediaType,
                      String entryKey, {
                      VoidCallback? onRemoveFromCollection,
                    }) => const ColoredBox(color: Colors.blue),
                onChanged: () {},
                onOpenMember: (String mediaType, String entryKey) =>
                    opened.add('$mediaType|$entryKey'),
                onShowMemberMenu:
                    (
                      String mediaType,
                      String entryKey, {
                      required VoidCallback onRemoveFromCollection,
                    }) async {
                      menus.add('$mediaType|$entryKey');
                    },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      switch (view) {
        case _MemberView.list:
          await tester.tap(
            find.byKey(const ValueKey<String>('collection_detail_view_list')),
          );
          await tester.pumpAndSettle();
        case _MemberView.reorderGrid:
          break;
        case _MemberView.filteredGrid:
          // 拖排网格不接筛选结果（下标要回写全表）：搜索命中后退回普通网格。
          await tester.enterText(
            find.byKey(const ValueKey<String>('collection_detail_search')),
            'k1',
          );
          await tester.pumpAndSettle();
      }
      // 未写手动排序偏好时无筛选网格也是拖排网格（拖一次即存为手动序）；普通网格
      // 只在筛选 / 多选下出现，所以三条路径都要单独钉住。
      final Finder member = find.byKey(
        ValueKey<String>(switch (view) {
          _MemberView.list => 'member-row-epub|k1',
          _MemberView.reorderGrid => 'epub|k1',
          _MemberView.filteredGrid => 'member-tile-epub|k1',
        }),
      );
      expect(member, findsOneWidget);
      expect(member.hitTestable(), findsOneWidget);

      Future<void> mousePress(int buttons) async {
        final TestGesture gesture = await tester.startGesture(
          tester.getCenter(member),
          kind: PointerDeviceKind.mouse,
          buttons: buttons,
        );
        await gesture.up();
        await tester.pumpAndSettle();
      }

      await mousePress(kSecondaryMouseButton);
      expect(menus, <String>['epub|k1'], reason: '默认右键恰好开一次成员菜单');
      registry.updateBinding(
        ShortcutAction.homeFocusSearch,
        const ShortcutBindingSet(
          mouseBindings: <MouseBinding>[MouseBinding(2)],
        ),
      );
      await mousePress(kSecondaryMouseButton);
      expect(menus, <String>['epub|k1'], reason: '页面动作占用右键时成员菜单让位');
      registry.updateBinding(
        ShortcutAction.homeFocusSearch,
        const ShortcutBindingSet(),
      );
      registry.updateBinding(
        ShortcutAction.globalContextMenu,
        const ShortcutBindingSet(
          mouseBindings: <MouseBinding>[MouseBinding(1)],
        ),
      );
      await mousePress(kSecondaryMouseButton);
      expect(menus, <String>['epub|k1'], reason: '改绑后原右键不再开菜单');
      await mousePress(kMiddleMouseButton);
      expect(menus, <String>['epub|k1', 'epub|k1'], reason: '菜单跟随新的中键绑定');
      expect(opened, isEmpty, reason: '非主键不应误打开成员');
      await tester.tap(member);
      await tester.pumpAndSettle();
      expect(opened, <String>['epub|k1'], reason: '主键打开行为保留');
      expect(tester.takeException(), isNull);
    });
  }
}
