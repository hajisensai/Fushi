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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    MouseBindingDispatch.resetForTest();
  });

  for (final bool list in <bool>[false, true]) {
    testWidgets('合集${list ? '列表' : '非拖排网格'}菜单遵循默认、让位和改绑', (
      WidgetTester tester,
    ) async {
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
      if (list) {
        await tester.tap(
          find.byKey(const ValueKey<String>('collection_detail_view_list')),
        );
        await tester.pumpAndSettle();
      }
      // 未写手动排序偏好：必须命中新增的普通网格，而非已正确接线的拖排网格。
      final Finder member = find.byKey(
        ValueKey<String>('member-${list ? 'row' : 'tile'}-epub|k1'),
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
