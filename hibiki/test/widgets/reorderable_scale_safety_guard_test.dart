import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import '../helpers/scan_scale.dart';

/// BUG-778 同根因的全仓收口守卫。
///
/// 整棵 widget 树活在 `FushiAppUiScale` 的 `Transform.scale` 之下（main.dart 在
/// 应用根部套的浏览器式整体缩放），而 Flutter SDK 的重排拖拽代理
/// （`reorderable_list.dart` 的 `_DragItemProxy`）用「全局坐标 − overlay 原点」
/// 的纯平移把代理放进 Overlay 本地坐标系、**不认祖先缩放变换**：用户把「界面
/// 大小」调成非 100% 后，拖拽浮层就按 `(1−s)×(指针到 overlay 原点距离)` 漂移，
/// 缩小时一拖即飞出屏幕。这是 SDK 的坐标缺陷，app 内改不了那段数学。
///
/// BUG-778 当时只把合集与词典两条链路换成了自实现的 FushiReorderable*，
/// `custom_fonts_page` 与互联设备排序两处漏网，且 `md3_design_system_static_test`
/// 还**正向断言**字体页必须含 `ReorderableListView.builder(`——一条守卫把缺陷焊
/// 在了原地。这里改为反向钉死：全仓不得再实际使用 SDK 的重排组件。
void main() {
  test('lib/ 下不得实际使用 SDK ReorderableListView / ReorderableGridView', () {
    final Directory libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue, reason: '测试须从 hibiki/ 下运行');

    // 只查真实构造调用，不查注释里提到的名字（多处注释正当地解释「为什么不用
    // 它」，那些恰恰是应当保留的设计记录）。
    //
    // 判据本身已是 identifierCall 那套纪律：负向后顾 `(?<![\w.])` 挡掉
    // `FushiReorderableListView(` 这类更长标识符与 `x.ReorderableListView(` 这类
    // 成员访问，`(\.\s*\w+\s*)?` 覆盖 `.builder(` 命名构造——两个方向都堵住了，
    // 故不改判据，只换注释剥离。
    final RegExp constructorCall = RegExp(
      r'(?<![\w.])Reorderable(ListView|GridView)\s*(\.\s*\w+\s*)?\(',
    );

    final List<String> offenders = <String>[];
    int scanned = 0;
    for (final FileSystemEntity entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      scanned++;
      final String relative = entity.path.replaceAll(r'\', '/');
      final String content = entity.readAsStringSync();
      // 注释换成**等长空白**（共享原语）。旧写法是「整行 `//` 或 `*` 开头就跳过」：
      // - doc 续行的 `*` 分支不再需要——`/** ... */` / `/* ... */` 整块（含续行）
      //   已被词法掩码吃掉，而「行首是 `*`」本来就是个凭形状猜词法状态的近似规则；
      // - 反过来它漏掉块注释与行尾注释：`foo(); // 原本是 ReorderableListView(`
      //   会被误判成违规。
      // 掩码不改行数，两个列表下标一一对应，`i + 1` 仍是原文真实行号；报错文案要
      // 给人看的是**原文**行（掩码行里注释段已成空白）。
      final List<String> lines =
          maskCommentsAndScriptLines(content).split('\n');
      final List<String> rawLines = content.split('\n');
      for (int i = 0; i < lines.length; i++) {
        if (constructorCall.hasMatch(lines[i])) {
          offenders.add('$relative:${i + 1}: ${rawLines[i].trim()}');
        }
      }
    }

    expectScanScale(scanned,
        what: 'lib/ 下的 .dart', atLeast: 750, measured: 939);

    expect(
      offenders,
      isEmpty,
      reason: 'SDK 重排组件的 Overlay 拖拽代理不认祖先 Transform.scale，'
          '「界面大小」非 100% 时拖拽浮层漂移（BUG-778）。'
          '改用 FushiReorderableColumn / FushiReorderableGrid'
          '（浮层渲染在列表自身 Stack、指针经 globalToLocal 消掉祖先缩放）：\n'
          '${offenders.join('\n')}',
    );
  });

  test('自实现重排件仍在（消缩放的替代实现不得被误删）', () {
    expect(
      File('lib/src/utils/components/hibiki_reorderable_column.dart')
          .existsSync(),
      isTrue,
    );
    expect(
      File('lib/src/utils/components/hibiki_reorderable_grid.dart')
          .existsSync(),
      isTrue,
    );
  });
}
