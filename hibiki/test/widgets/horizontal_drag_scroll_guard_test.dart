import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
    expect(libDir.existsSync(), isTrue, reason: '测试须从 hibiki/ 下运行');

    final List<String> offenders = <String>[];
    for (final FileSystemEntity entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String source = entity.readAsStringSync();
      final int horizontals =
          'scrollDirection: Axis.horizontal'.allMatches(source).length;
      if (horizontals == 0) continue;

      final String relative = entity.path.replaceAll(r'\', '/');
      final int wrapped = 'HorizontalDragScrollable('.allMatches(source).length;
      final int exempt = exemptions.keys.any(relative.endsWith) ? 1 : 0;

      if (wrapped + exempt < horizontals) {
        offenders.add(
          '$relative: 横向滚动区 $horizontals 处，'
          'HorizontalDragScrollable 包裹 $wrapped 处，豁免 $exempt 处',
        );
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '这些横向滚动区在桌面端鼠标拖不动（默认 dragDevices 不含 mouse）。'
          '用 HorizontalDragScrollable 包住滚动件；'
          '若区内已有依赖横拖的手势，加进本测试的 exemptions 并写明理由：\n'
          '${offenders.join('\n')}',
    );
  });

  test('共享件本体存在且放开了 mouse/trackpad/stylus', () {
    final File file = File('lib/src/utils/misc/platform_utils.dart');
    expect(file.existsSync(), isTrue);
    final String source = file.readAsStringSync();
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
      main.readAsStringSync(),
      isNot(contains('scrollBehavior:')),
      reason: '全局放开鼠标拖动滚动会让垂直网格与 MediaCardDraggable 的 Draggable '
          '抢手势，把「拖卡进合集」变成「拖动网格滚动」。只包横向区。',
    );
  });
}
