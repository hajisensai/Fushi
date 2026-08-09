import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

/// 横向滚动区的判据。
///
/// TODO-2715：旧判据是精确字面量 `'scrollDirection: Axis.horizontal'`，
/// `dart format` 只要把它折成 `scrollDirection:\n    Axis.horizontal`（长实参表里
/// 常见）就一个也匹配不到——分母归零、守卫全绿。改成允许任意空白/换行。
final RegExp kHorizontalAxis = RegExp(r'scrollDirection:\s*Axis\.horizontal');

/// 包裹件。用 [identifierCall] 定左边界，`MyHorizontalDragScrollable(` 不算数。
final RegExp kDragScrollableWrap = identifierCall(
  'HorizontalDragScrollable',
  allowNamedConstructor: false,
);

/// 一个文件里的「横向滚动区数 / 包裹数」。判据先剥注释：注释里的示例代码既不该
/// 被算成违规（假红），也不该被算成包裹（假绿）。
({int horizontals, int wrapped}) countHorizontalScrollAreas(String source) {
  final String code = maskComments(source);
  return (
    horizontals: kHorizontalAxis.allMatches(code).length,
    wrapped: kDragScrollableWrap.allMatches(code).length,
  );
}

/// 桌面端 Flutter 的默认 `MaterialScrollBehavior.dragDevices` **不含鼠标**：横向
/// 滚动区用鼠标左键按住左右拖会毫无反应（用户实报）。仓库早在
/// `collection_shelf_row.dart` 就写下了这条根因注释并修了合集行 + 首页继续行，
/// 但没有推广——全仓 16 处 `Axis.horizontal` 里当时只有那 2 处放开了鼠标拖动。
///
/// 这条守卫钉死「新增横向滚动区必须包 [HorizontalDragScrollable]」，防止再次漂移。
/// 按文件粒度计数（一个文件里的横向区数 ≤ 包裹数 + 豁免数），因为静态扫描无法可靠
/// 判断 widget 树的父子关系。
///
/// **注意「滚轮」不是退路**（BUG-1214 更正）：横向 `Scrollable` 只取
/// `scrollDelta.dx`，物理滚轮发的是 `(0, dy)`，裸滚轮同样毫无反应——除非该区显式包了
/// `WheelToHorizontalScroll` 把纵向 delta 投到横轴。所以豁免本件的区必须自己交代
/// 用户还能怎么平移。
void main() {
  /// 明确豁免：区内已有依赖横拖的手势，放开滚动拖动会与之抢手势竞技场。
  ///
  /// 每条豁免都必须写清理由——豁免不是「先跳过以后再说」，而是有对抗性证据的决定。
  const Map<String, String> exemptions = <String, String>{
    // cue strip 自带 onHorizontalDrag「拖字幕块调延迟」。GestureDetector 的横拖
    // 不受 ScrollBehavior.dragDevices 约束，故现状是「鼠标拖字幕块有效、拖空白
    // 无反应」；放开滚动拖动会让两个 HorizontalDragGestureRecognizer 进同一个
    // 竞技场，赌内层胜出去换一点便利不值得。平移退路：常驻滚动条 + 显式包了
    // WheelToHorizontalScroll 的鼠标滚轮（BUG-1214）。
    'lib/src/media/video/subtitle_waveform_align_panel.dart':
        'cue strip 自带 onHorizontalDrag 调延迟，放开滚动拖动会抢手势；'
            '滚轮平移由 WheelToHorizontalScroll 提供',
  };

  test('每个横向滚动区都放开了鼠标拖动（或在豁免清单里说明了原因）', () {
    final Directory libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue, reason: '测试须从 fushi/ 下运行');

    final List<String> offenders = <String>[];
    int scanned = 0;
    int withHorizontal = 0;
    for (final FileSystemEntity entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      scanned++;
      final counts = countHorizontalScrollAreas(entity.readAsStringSync());
      final int horizontals = counts.horizontals;
      if (horizontals == 0) continue;
      withHorizontal++;

      final String relative = entity.path.replaceAll(r'\', '/');
      final int wrapped = counts.wrapped;
      final int exempt = exemptions.keys.any(relative.endsWith) ? 1 : 0;

      if (wrapped + exempt < horizontals) {
        offenders.add(
          '$relative: 横向滚动区 $horizontals 处，'
          'HorizontalDragScrollable 包裹 $wrapped 处，豁免 $exempt 处',
        );
      }
    }

    expectScanScale(scanned,
        what: 'lib/ 下的 .dart', atLeast: 750, measured: 939);
    // `withHorizontal` 才是判据的真分母：扫描面还在、但「横向滚动区」的匹配写法
    // 一旦失配（`dart format` 折行、参数换序），这条守卫就对着 0 个候选跑全绿。
    expectScanScale(withHorizontal,
        what: '含横向滚动区的文件', atLeast: 12, measured: 17);

    expect(
      offenders,
      isEmpty,
      reason: '这些横向滚动区在桌面端鼠标拖不动（默认 dragDevices 不含 mouse）。'
          '用 HorizontalDragScrollable 包住滚动件；'
          '若区内已有依赖横拖的手势，加进本测试的 exemptions 并写明理由：\n'
          '${offenders.join('\n')}',
    );
  });

  // TODO-2715：判据自校验。上面那条是禁止型断言（offenders isEmpty），真实仓库里
  // 长期零命中，所以「分子/分母还认不认得代码」在扫盘那条路上得不到检验；这里用
  // 手写语料独立喂进同一个 [countHorizontalScrollAreas]，正负两向都钉住。
  group('判据自校验（手写语料，与磁盘扫描互不依赖）', () {
    test('单行写法数得到', () {
      final c = countHorizontalScrollAreas(
        'ListView(scrollDirection: Axis.horizontal, children: []);',
      );
      expect(c.horizontals, 1);
      expect(c.wrapped, 0);
    });

    test('dart format 折行后仍数得到（旧字面量判据在这里归零）', () {
      final c = countHorizontalScrollAreas('''
ListView.builder(
  scrollDirection:
      Axis.horizontal,
  itemBuilder: (_, __) => const SizedBox(),
);
''');
      expect(c.horizontals, 1, reason: '折行是 dart format 的常规产物，分母不得依赖「同一行」');
    });

    test('包裹件计数认左边界，不被同后缀标识符顶包', () {
      final c = countHorizontalScrollAreas('''
HorizontalDragScrollable(child: ListView(scrollDirection: Axis.horizontal));
MyHorizontalDragScrollable(child: SizedBox());
''');
      expect(c.horizontals, 1);
      expect(c.wrapped, 1, reason: 'MyHorizontalDragScrollable( 不是这个共享件');
    });

    test('注释里的示例既不算横向区也不算包裹', () {
      final c = countHorizontalScrollAreas('''
// 示例：ListView(scrollDirection: Axis.horizontal) 要包 HorizontalDragScrollable(
/* scrollDirection: Axis.horizontal */
void f() {}
''');
      expect(c.horizontals, 0);
      expect(c.wrapped, 0);
    });
  });

  test('共享件本体存在且放开了 mouse/trackpad/stylus', () {
    final File file = File('lib/src/utils/misc/platform_utils.dart');
    expect(file.existsSync(), isTrue);
    // 全是要求型断言：注释里写着这些名字不算实现（TODO-2715）。
    final String source = maskComments(file.readAsStringSync());
    expect(source, contains('class HorizontalDragScrollable'));
    expect(source, contains('PointerDeviceKind.mouse'));
    expect(source, contains('PointerDeviceKind.trackpad'));
    expect(source, contains('PointerDeviceKind.stylus'));
    // 触屏行为不得被改掉。
    expect(source, contains('PointerDeviceKind.touch'));
  });

  test('刻意不做成全局 scrollBehavior（否则垂直网格会与卡片拖拽抢手势）', () {
    final File main = File('lib/main.dart');
    expect(main.existsSync(), isTrue);
    expect(
      maskComments(main.readAsStringSync()),
      isNot(contains('scrollBehavior:')),
      reason: '全局放开鼠标拖动滚动会让垂直网格与 MediaCardDraggable 的 Draggable '
          '抢手势，把「拖卡进合集」变成「拖动网格滚动」。只包横向区。',
    );
  });
}
