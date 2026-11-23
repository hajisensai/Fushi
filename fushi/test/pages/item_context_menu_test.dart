import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/media_item_dialog_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiGlassMaterial;
import 'package:fushi/src/utils/components/batch_action_bar.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:material_ui/material_ui.dart';

/// 2026-11-20 #4b：书 / 漫画、小说、视频合集、游戏四种媒体的右键菜单统一骨架
/// （设计稿 fushi/build/feedback_1120_design #i4b）。四种媒体各按自己菜单的
/// 落点约定（与生产调用点同一份 [ItemMenuSlot] 分配）填数据，本文件钉住：
/// * 从上到下的分段：头部 → 主操作行 → 工作台 → 整理 → 开关 → 更多 › → 危险；
/// * 键盘：↓ 走到「更多」、→ 进二级菜单、Esc 返回且焦点回到「更多」、再 Esc 关菜单；
/// * 1280×720 下菜单不出滚动；
/// * 手机长按同一份数据渲染成底部面板，二级菜单面板内下钻；
/// * 开关行显示当前开关、就地拨动；被继承锁定时改走说明对话框；
/// * 多选态的批量菜单只列可用动作、删除进危险段。
///
/// `--dart-define=FUSHI_ITEM_MENU_SHOTS=<目录>` 时额外把 MD3 / Apple 两套主题的
/// 菜单截图写进该目录（像素证据，不入库）。
const String _shotsDir = String.fromEnvironment('FUSHI_ITEM_MENU_SHOTS');

enum _Media { manga, novel, videoCollection, game }

void main() {
  late List<String> fired;

  DialogListAction row(
    String label, {
    ItemMenuSlot? slot,
    DialogActionGroup group = DialogActionGroup.organize,
    bool selected = false,
    IconData icon = Icons.label_outline,
  }) => DialogListAction(
    label: label,
    icon: icon,
    group: group,
    slot: slot,
    selected: selected,
    onPressed: () => fired.add(label),
  );

  DialogToggleAction toggle(
    String label, {
    required bool value,
    bool locked = false,
  }) => DialogToggleAction(
    label: label,
    icon: Icons.lock_outline,
    onPressed: () => fired.add('$label:dialog'),
    loadState: () async => (value: value, locked: locked),
    onChanged: (bool v) async => fired.add('$label:$v'),
  );

  MediaItemDialogFrame frameFor(_Media media) {
    final List<DialogToggleAction> toggles = <DialogToggleAction>[
      toggle('私密', value: true),
      if (media != _Media.game) toggle('NSFW', value: false),
    ];
    final DialogDangerAction delete = DialogDangerAction(
      label: media == _Media.game ? '从库中移除' : '删除',
      onPressed: () => fired.add('delete'),
    );
    switch (media) {
      case _Media.manga:
        return MediaItemDialogFrame(
          title: "It's MyGO!!!!! 2",
          progressLabel: '12%',
          launchLabel: '继续阅读',
          onLaunch: () => fired.add('launch'),
          listActions: <DialogListAction>[
            row('详情', slot: ItemMenuSlot.primary),
            row('作品页', slot: ItemMenuSlot.primary),
            row('读完', slot: ItemMenuSlot.primary, selected: true),
            // 拍板 Ew0AxAgycu：「导入漫画有声」直达入口在上，与工作台同级。
            DialogWorkbenchAction(
              label: '导入漫画有声',
              icon: Icons.file_open_outlined,
              onPressed: () => fired.add('workbench'),
            ),
            DialogWorkbenchAction(
              label: '有声漫画工作台',
              icon: Icons.headphones_outlined,
              subtitle: '把漫画做成有声版',
              loadStatus: () async => '已识别 128 句 · 配音 3/12 话',
              emphasized: false,
              onPressed: () => fired.add('有声漫画工作台'),
            ),
            row('重命名', slot: ItemMenuSlot.edit),
            row('在线刮削封面', slot: ItemMenuSlot.edit),
            row('关联作品', slot: ItemMenuSlot.edit),
            row('编辑信息', slot: ItemMenuSlot.edit),
            row('标签'),
            row('移出合集'),
            ...toggles,
            row('查看插画', group: DialogActionGroup.content),
            row('打开文件位置', slot: ItemMenuSlot.more),
            row('转换回书', group: DialogActionGroup.content),
            row('查看统计', group: DialogActionGroup.progress),
            row('追踪', group: DialogActionGroup.progress),
            row('重置阅读状态', group: DialogActionGroup.progress),
            row('内容语言', group: DialogActionGroup.settings),
            row('书籍 CSS', group: DialogActionGroup.settings),
            row('排序', slot: ItemMenuSlot.sort),
          ],
          dangerActions: <DialogDangerAction>[delete],
        );
      case _Media.novel:
        return MediaItemDialogFrame(
          title: '本好きの下剋上 1',
          progressLabel: '香月美夜 · 41%',
          launchLabel: '继续阅读',
          onLaunch: () => fired.add('launch'),
          listActions: <DialogListAction>[
            row('详情', slot: ItemMenuSlot.primary),
            row('读完', slot: ItemMenuSlot.primary),
            // 拍板 Ew0AxAgycu 方案 a：导入在上（主色）、制作紧随（同级、中性色）。
            DialogWorkbenchAction(
              label: '导入有声书',
              icon: Icons.headphones_outlined,
              onPressed: () => fired.add('workbench'),
            ),
            DialogWorkbenchAction(
              label: '制作有声书',
              icon: Icons.record_voice_over_outlined,
              emphasized: false,
              onPressed: () => fired.add('制作有声书'),
            ),
            row('重命名', slot: ItemMenuSlot.edit),
            row('编辑信息', slot: ItemMenuSlot.edit),
            row('标签'),
            row('加入合集'),
            ...toggles,
            row('查看插画', group: DialogActionGroup.content),
            row('查看统计', group: DialogActionGroup.progress),
            row('内容语言', group: DialogActionGroup.settings),
          ],
          dangerActions: <DialogDangerAction>[delete],
        );
      case _Media.videoCollection:
        return MediaItemDialogFrame(
          title: '悪女（わる）',
          progressLabel: '继续看 第3集 · 11 集',
          launchLabel: '继续播放',
          onLaunch: () => fired.add('launch'),
          listActions: <DialogListAction>[
            row('全部集', slot: ItemMenuSlot.primary),
            row('看完', slot: ItemMenuSlot.primary),
            row('选择', slot: ItemMenuSlot.primary),
            DialogWorkbenchAction(
              label: '字幕与刮削',
              icon: Icons.subtitles_outlined,
              onPressed: () {},
              children: <DialogListAction>[
                row('为合集获取字幕', group: DialogActionGroup.content),
                row('重新刮削资料与封面'),
              ],
            ),
            row('重命名合集', slot: ItemMenuSlot.edit),
            row('设置封面', slot: ItemMenuSlot.edit),
            row('整理文件名', slot: ItemMenuSlot.edit),
            row('标签'),
            row('按名称排序', slot: ItemMenuSlot.sort),
            row('按导入时间排序', slot: ItemMenuSlot.sort),
            ...toggles,
            row('全部标记为未看', group: DialogActionGroup.progress),
            row('下载远端集', group: DialogActionGroup.content),
            row('查看统计', group: DialogActionGroup.progress),
          ],
          dangerActions: <DialogDangerAction>[
            DialogDangerAction(
              label: '删除合集',
              onPressed: () => fired.add('delete'),
            ),
          ],
        );
      case _Media.game:
        return MediaItemDialogFrame(
          title: 'CLANNAD',
          progressLabel: '在玩',
          launchLabel: '启动游戏',
          onLaunch: () => fired.add('launch'),
          quickActions: <DialogQuickAction>[
            DialogQuickAction(
              label: '详情',
              icon: Icons.info_outline,
              slot: ItemMenuSlot.primary,
              onPressed: () => fired.add('详情'),
            ),
            DialogQuickAction(
              label: '游玩状态',
              icon: Icons.flag_outlined,
              slot: ItemMenuSlot.primary,
              onPressed: () => fired.add('游玩状态'),
            ),
            DialogQuickAction(
              label: '通关',
              icon: Icons.check,
              slot: ItemMenuSlot.primary,
              onPressed: () => fired.add('通关'),
            ),
            DialogQuickAction(
              label: '重命名',
              icon: Icons.edit,
              group: DialogActionGroup.organize,
              slot: ItemMenuSlot.edit,
              onPressed: () => fired.add('重命名'),
            ),
            DialogQuickAction(
              label: '设置封面',
              icon: Icons.image_outlined,
              group: DialogActionGroup.organize,
              slot: ItemMenuSlot.edit,
              onPressed: () => fired.add('设置封面'),
            ),
            DialogQuickAction(
              label: '加入合集',
              icon: Icons.collections_bookmark_outlined,
              group: DialogActionGroup.organize,
              onPressed: () => fired.add('加入合集'),
            ),
            DialogQuickAction(
              label: '标签',
              icon: Icons.sell_outlined,
              group: DialogActionGroup.organize,
              onPressed: () => fired.add('标签'),
            ),
            DialogQuickAction(
              label: '查看统计',
              icon: Icons.insights_outlined,
              group: DialogActionGroup.progress,
              onPressed: () => fired.add('查看统计'),
            ),
            DialogQuickAction(
              label: '内容语言',
              icon: Icons.translate,
              group: DialogActionGroup.settings,
              onPressed: () => fired.add('内容语言'),
            ),
          ],
          listActions: <DialogListAction>[
            ...toggles,
            DialogWorkbenchAction(
              label: '文本 Hook 与制卡',
              icon: Icons.phishing_outlined,
              subtitle: '文本处理 · 制卡覆盖',
              onPressed: () => fired.add('workbench'),
            ),
          ],
          dangerActions: <DialogDangerAction>[delete],
        );
    }
  }

  Future<void> pumpHost(
    WidgetTester tester, {
    required Size screen,
    required WidgetBuilder builder,
    Offset? anchor,
    bool apple = false,
  }) async {
    fired = <String>[];
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey<String>('shot_root'),
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
            textTheme: Typography.material2021().black,
            glass: apple ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
            glassDesign: apple,
          ),
          home: FushiGlassScope(
            child: Scaffold(
              body: Builder(
                builder: (BuildContext context) => Align(
                  alignment: Alignment.topLeft,
                  child: TextButton(
                    onPressed: () => showMediaItemActions<void>(
                      context: context,
                      anchor: anchor,
                      builder: builder,
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder menuScrollable() => find.descendant(
    of: find.byType(MediaItemDialogFrame),
    matching: find.byType(Scrollable),
  );

  for (final _Media media in _Media.values) {
    testWidgets('${media.name}: right-click shows the unified sections, '
        'walks primary → 更多 → submenu → Esc back', (WidgetTester tester) async {
      await pumpHost(
        tester,
        screen: const Size(1280, 720),
        anchor: const Offset(400, 120),
        builder: (_) => frameFor(media),
      );

      // 头部 + 主操作行（带文字的常用操作）+ 工作台 + 整理 + 开关 + 更多 + 危险。
      expect(find.byKey(const ValueKey<String>('item_menu_title')), findsOne);
      expect(
        find.byKey(const ValueKey<String>('item_menu_progress')),
        findsOne,
      );
      final Rect launch = tester.getRect(
        find.byKey(const ValueKey<String>('item_menu_launch')),
      );
      final Rect workbench = tester.getRect(
        find.byKey(const ValueKey<String>('item_menu_workbench')).first,
      );
      final Rect organize = tester.getRect(
        find.text(t.item_actions_group_organize),
      );
      final Rect more = tester.getRect(
        find.byKey(const ValueKey<String>('item_menu_more')),
      );
      final Rect danger = tester.getRect(
        find.text(switch (media) {
          _Media.game => '从库中移除',
          _Media.videoCollection => '删除合集',
          _ => '删除',
        }),
      );
      expect(launch.bottom, lessThanOrEqualTo(workbench.top));
      expect(workbench.bottom, lessThanOrEqualTo(organize.top));
      expect(organize.bottom, lessThan(more.top));
      expect(more.bottom, lessThan(danger.top));
      // 开关行看得出当前状态（私密开、NSFW 关）。
      final Switch privacy = tester.widget<Switch>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('item_menu_toggle_私密')),
          matching: find.byType(Switch),
        ),
      );
      expect(privacy.value, isTrue);
      // 低频项不在第一层（收进「更多」），1280×720 下菜单不滚动。
      expect(find.text('内容语言'), findsNothing);
      for (final Element e in menuScrollable().evaluate()) {
        final ScrollableState s =
            (e as StatefulElement).state as ScrollableState;
        expect(
          s.position.maxScrollExtent,
          0,
          reason: '${media.name} 菜单在 1280×720 下出现了滚动',
        );
      }

      // 键盘：从头一路 ↓ 走到「更多」，→ 进二级菜单。
      final FocusNode moreFocus = Focus.of(
        tester.element(find.text(t.item_menu_more)),
      );
      for (int i = 0; i < 40 && !moreFocus.hasPrimaryFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      expect(moreFocus.hasPrimaryFocus, isTrue, reason: '↓ 能走到「更多」');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey<String>('item_menu_submenu_${t.item_menu_more}')),
        findsOne,
      );
      expect(find.text('查看统计'), findsOne);
      // 二级菜单在主菜单旁边、不出屏。
      final Rect sub = tester.getRect(
        find.byKey(ValueKey<String>('item_menu_submenu_${t.item_menu_more}')),
      );
      expect(sub.left, greaterThanOrEqualTo(more.right));
      expect(sub.bottom, lessThanOrEqualTo(720));
      // Esc：收起二级菜单，焦点回到「更多」，主菜单还在。
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey<String>('item_menu_submenu_${t.item_menu_more}')),
        findsNothing,
      );
      expect(moreFocus.hasPrimaryFocus, isTrue);
      expect(find.byType(MediaItemDialogFrame), findsOne);
      // ← 同样返回：再进一次，用 ← 退出。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.text('查看统计'), findsNothing);
      // 再 Esc 关掉整个菜单。
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(MediaItemDialogFrame), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('primary row: launch and labelled actions fire; workbench shows '
      'the loaded status', (WidgetTester tester) async {
    await pumpHost(
      tester,
      screen: const Size(1280, 720),
      anchor: const Offset(400, 120),
      builder: (_) => frameFor(_Media.manga),
    );
    expect(find.text('已识别 128 句 · 配音 3/12 话'), findsOne);
    expect(find.text('作品页'), findsOne);
    await tester.tap(find.text('作品页'));
    expect(fired, <String>['作品页']);
  });

  testWidgets('编辑信息 / 排序 clusters list their children and open as '
      'submenus', (WidgetTester tester) async {
    await pumpHost(
      tester,
      screen: const Size(1280, 720),
      anchor: const Offset(400, 120),
      builder: (_) => frameFor(_Media.videoCollection),
    );
    expect(find.textContaining('重命名合集 · 设置封面'), findsOne);
    expect(find.textContaining('按名称排序 · 按导入时间排序'), findsOne);
    await tester.tap(
      find.byKey(const ValueKey<String>('item_menu_sort_group')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('按名称排序').last);
    await tester.pumpAndSettle();
    expect(fired, <String>['按名称排序']);
  });

  testWidgets('a toggle flips in place; a locked toggle opens its dialog', (
    WidgetTester tester,
  ) async {
    await pumpHost(
      tester,
      screen: const Size(1280, 720),
      anchor: const Offset(400, 120),
      builder: (_) => MediaItemDialogFrame(
        title: 'x',
        showLaunchAction: false,
        listActions: <DialogListAction>[
          toggle('NSFW', value: false),
          toggle('私密', value: true, locked: true),
        ],
      ),
    );
    Switch sw(String label) => tester.widget<Switch>(
      find.descendant(
        of: find.byKey(ValueKey<String>('item_menu_toggle_$label')),
        matching: find.byType(Switch),
      ),
    );
    expect(sw('NSFW').value, isFalse);
    await tester.tap(find.text('NSFW'));
    await tester.pumpAndSettle();
    expect(sw('NSFW').value, isTrue);
    expect(fired, <String>['NSFW:true']);
    expect(find.byType(MediaItemDialogFrame), findsOne, reason: '菜单不关');
    await tester.tap(find.text('私密'));
    await tester.pumpAndSettle();
    expect(fired.last, '私密:dialog');
  });

  testWidgets('phone long-press: same data as a bottom panel, 更多 drills in '
      'and ← returns', (WidgetTester tester) async {
    await pumpHost(
      tester,
      screen: const Size(390, 844),
      builder: (_) => frameFor(_Media.manga),
    );
    expect(find.byType(BottomSheet), findsOne);
    expect(find.byKey(const ValueKey<String>('item_menu_launch')), findsOne);
    expect(find.text('内容语言'), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('item_menu_more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('item_menu_back')), findsOne);
    expect(find.text('内容语言'), findsOne);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('item_menu_back')), findsNothing);
    expect(find.byKey(const ValueKey<String>('item_menu_launch')), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the wide dialog still lists workbench children (nothing lost)', (
    WidgetTester tester,
  ) async {
    fired = <String>[];
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: frameFor(_Media.videoCollection))),
      ),
    );
    expect(find.text('为合集获取字幕'), findsOne);
    expect(find.text('重新刮削资料与封面'), findsOne);
    expect(find.text('全部标记为未看'), findsOne);
  });

  testWidgets('batch menu: 已选 N, only enabled actions, delete in danger', (
    WidgetTester tester,
  ) async {
    fired = <String>[];
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showBatchItemActions(
                context: context,
                selectedCount: 5,
                anchor: const Offset(300, 100),
                actions: <BatchAction>[
                  BatchAction(
                    key: 'dl',
                    label: 'Download',
                    icon: Icons.download,
                    enabled: false,
                    onPressed: () => fired.add('dl'),
                  ),
                  BatchAction(
                    key: 'tag',
                    label: 'Tags',
                    icon: Icons.sell_outlined,
                    onPressed: () => fired.add('tag'),
                  ),
                  BatchAction(
                    key: 'del',
                    label: 'Delete',
                    icon: Icons.delete_outline,
                    destructive: true,
                    onPressed: () => fired.add('del'),
                  ),
                ],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(t.batch_selected_count(n: 5)), findsOne);
    expect(find.text('Download'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Delete')).dy,
      greaterThan(tester.getTopLeft(find.text('Tags')).dy),
    );
    await tester.tap(find.text('Tags'));
    await tester.pumpAndSettle();
    expect(fired, <String>['tag']);
    expect(find.byType(MediaItemDialogFrame), findsNothing);
  });

  if (_shotsDir.isNotEmpty) {
    for (final bool apple in <bool>[false, true]) {
      testWidgets('shots: ${apple ? 'apple' : 'md3'}', (
        WidgetTester tester,
      ) async {
        await tester.runAsync(() async {
          final FontLoader loader = FontLoader('Roboto')
            ..addFont(
              File(r'C:\Windows\Fonts\Deng.ttf').readAsBytes().then(
                (List<int> b) => ByteData.sublistView(Uint8List.fromList(b)),
              ),
            );
          await loader.load();
          final FontLoader sf = FontLoader('.SF UI Text')
            ..addFont(
              File(r'C:\Windows\Fonts\Deng.ttf').readAsBytes().then(
                (List<int> b) => ByteData.sublistView(Uint8List.fromList(b)),
              ),
            );
          await sf.load();
        });
        LocaleSettings.setLocaleRaw('zh-CN');
        addTearDown(() => LocaleSettings.setLocaleRaw('en'));
        for (final _Media media in _Media.values) {
          await pumpHost(
            tester,
            screen: const Size(1280, 720),
            anchor: const Offset(400, 60),
            apple: apple,
            builder: (_) => frameFor(media),
          );
          await tester.runAsync(() async {
            final RenderRepaintBoundary boundary = tester
                .renderObject<RenderRepaintBoundary>(
                  find.byKey(const ValueKey<String>('shot_root')),
                );
            final ui.Image image = await boundary.toImage();
            final ByteData? png = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final File out = File(
              '$_shotsDir/item_menu_${media.name}_${apple ? 'apple' : 'md3'}.png',
            );
            await out.parent.create(recursive: true);
            await out.writeAsBytes(png!.buffer.asUint8List());
          });
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
        }
      });
    }
  }
}
