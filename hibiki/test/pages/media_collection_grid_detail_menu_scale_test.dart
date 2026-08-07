import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/media_collection_grid_detail_page.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-781（与 BUG-129/261/381 同族）回归守卫：合集详情页
/// （[MediaCollectionGridDetailPage]）成员卡右键上下文菜单在界面大小≠100% 时的定位。
///
/// 生产拓扑：全局 [HibikiAppUiScale]（FittedBox 整体缩放）挂在 MaterialApp.builder，
/// 根 Navigator 的 Overlay 落在其缩放画布坐标系内；而网格右键回调报的是真实视口坐标。
/// 修复前 `_showMemberMenu` 把真实视口坐标直接当 Overlay 本地坐标喂给 showMenu 的
/// RelativeRect → 菜单渲染位置约落在「点击坐标 ×scale」（scale=0.5 时约点击坐标的一半，
/// 偏移随点击点离屏幕原点越远越大，屏幕中部点可达数百逻辑像素）。修复后经
/// `overlay.globalToLocal` 沿真实渲染变换链换算，菜单贴住点击点。
///
/// 本测试在 scale=0.5 的缩放画布下真右键点**靠近屏幕中心**的成员卡（放大偏移量，
/// 修复前会偏离数百像素），断言弹出菜单第一项的渲染位置（真实屏幕坐标）贴近点击点
/// （< 48 逻辑像素）——阈值能明确区分修复前后。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  /// 播种 [count] 个 epub 成员（keys k1..k{count}），返回 db + 合集行。多成员填满
  /// 网格多行，便于挑一张靠近屏幕中心的卡片放大缩放偏移。
  Future<({HibikiDatabase db, MediaCollectionRow col})> seed(int count) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int cid = await db.createMediaCollection('C');
    for (int i = 1; i <= count; i++) {
      await db.addToCollection(cid, MediaKind.epub, 'k$i');
    }
    final MediaCollectionRow col = (await db.getMediaCollectionById(cid))!;
    return (db: db, col: col);
  }

  /// 成员卡：纯视觉带 Key 的方块（详情页会把它包进 IgnorePointer，手势由网格接管）。
  Widget? cardBuilder(String mediaType, String entryKey,
          {VoidCallback? onRemoveFromCollection}) =>
      Container(
        key: ValueKey<String>('member-$entryKey'),
        color: Colors.blue,
        alignment: Alignment.center,
        child: Text(entryKey),
      );

  /// 复刻生产拓扑：MaterialApp.builder 注入 [HibikiAppUiScale]（整体缩放），页面
  /// 与根 Navigator/Overlay 都落在缩放画布坐标系内。onOpenMember 不注入 → 菜单只含
  /// 「移出合集」一项，第一项即该项（定位确定）。
  Widget wrapPage(MediaCollectionRow col, HibikiDatabase db,
          {required double scale}) =>
      TranslationProvider(
        child: MaterialApp(
          builder: (BuildContext context, Widget? child) =>
              HibikiAppUiScale(scale: scale, child: child!),
          home: MediaCollectionGridDetailPage(
            database: db,
            collection: col,
            memberCardBuilder: cardBuilder,
            onChanged: () {},
          ),
        ),
      );

  testWidgets('界面缩放 0.5 下成员卡右键菜单贴住点击点（BUG-781）', (WidgetTester tester) async {
    // 固定视口，几何可复现；缩放 0.5 时缩放画布为视口 2 倍。
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);

    const int count = 40;
    final ({HibikiDatabase db, MediaCollectionRow col}) s = await seed(count);
    await tester.pumpWidget(wrapPage(s.col, s.db, scale: 0.5));
    await tester.pumpAndSettle();

    // 挑一张中心最接近屏幕中心的成员卡：离屏幕原点越远，缩放偏移越大，越能拉开
    // 修复前后差距（真实屏幕坐标经 getCenter 的 localToGlobal 取得，已吸收缩放变换）。
    final Size view = tester.view.physicalSize / tester.view.devicePixelRatio;
    final Offset screenCenter = Offset(view.width / 2, view.height / 2);
    Offset? clickGlobal;
    for (int i = 1; i <= count; i++) {
      final Finder f = find.byKey(ValueKey<String>('member-k$i'));
      if (f.evaluate().isEmpty) continue;
      final Offset c = tester.getCenter(f);
      if (clickGlobal == null ||
          (c - screenCenter).distance < (clickGlobal - screenCenter).distance) {
        clickGlobal = c;
      }
    }
    expect(clickGlobal, isNotNull, reason: '应有成员卡渲染');
    // 该卡确实离屏幕原点足够远：修复前偏移≈clickGlobal.distance/2，需 >48 才能被阈值
    // 抓住回归（这里数百像素量级）。
    expect(clickGlobal!.distance, greaterThan(200.0),
        reason: '目标卡应靠近屏幕中心，放大缩放偏移量');

    // 真鼠标右键：secondary button 按下→原地松手（未移动）→ 网格 onContextMenu。
    final TestGesture gesture = await tester.startGesture(
      clickGlobal,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();

    // 菜单已弹出（「移出合集」项存在）。
    expect(find.text(t.collection_remove_member), findsOneWidget,
        reason: '右键应弹出成员上下文菜单（含「移出合集」）');

    // 菜单第一项（唯一项）容器的渲染左上角（真实屏幕坐标）应贴近点击点。
    final Finder menuItem =
        find.byWidgetPredicate((Widget w) => w is PopupMenuItem);
    expect(menuItem, findsOneWidget);
    final Offset menuTopLeft = tester.getTopLeft(menuItem.first);

    final double dist = (menuTopLeft - clickGlobal).distance;
    expect(dist, lessThan(48.0),
        reason: '缩放 0.5 下菜单应贴住点击点（globalToLocal 修复）；'
            '修复前会偏离约点击坐标的一半（数百像素），实测偏移=$dist');
  });
}
