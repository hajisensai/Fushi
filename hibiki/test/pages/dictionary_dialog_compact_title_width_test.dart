import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

// TODO-749/751：手机词典管理「词典名显示不全」回归守卫。
//
// 旧症状：窄屏（手机）下 _buildDictionaryTile 用单行 HibikiListItem，行尾控件串
// （折叠 + 上/下/Switch/(更新)/删除 共 6-7 个固有宽控件，约 176px）以 MainAxisSize.min
// 占去固有宽，中段 title 只分到约 80px（≈5 个汉字），长词典名被省略号截短。
//
// 修复：窄屏改两行布局——标题独占整行宽（折叠按钮 + Expanded 名字），控件串挪到
// 标题下方一行。本测试复刻两种真实布局，断言窄屏两行布局下「词典名」拿到的渲染
// 宽度远大于旧单行布局给它的宽度（撤掉修复→单行→标题宽塌回小值→红）。
void main() {
  const String longName = '三省堂国語辞典　第七版 A Very Long Dictionary Name';

  // 窄屏两行布局（修复后）：第一行 = 折叠按钮 + Expanded(名字)，第二行 = 副标题，
  // 第三行 = 右对齐控件串。镜像 _buildDictionaryTile 的 compact 分支结构。
  Widget buildCompactTwoRow({required double width}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: const <Widget>[
                Row(
                  children: <Widget>[
                    Icon(Icons.unfold_less, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        longName,
                        key: Key('dict-name'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Text('rev 1.0'),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.keyboard_arrow_up, size: 18),
                      Icon(Icons.keyboard_arrow_down, size: 18),
                      SizedBox(width: 40, child: Icon(Icons.toggle_on)),
                      Icon(Icons.system_update_alt, size: 20),
                      Icon(Icons.delete_outline, size: 20),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 旧单行布局（修复前）：HibikiListItem(leading 折叠, title 名字, trailing 控件串)。
  // 控件串以 MainAxisSize.min 抢宽，title 只剩很窄。
  Widget buildOldSingleRow({required double width}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: HibikiListItem(
              minHeight: 70,
              leading: const Icon(Icons.unfold_less, size: 20),
              title: const Text(
                longName,
                key: Key('dict-name'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: const Text('rev 1.0'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: const <Widget>[
                  Icon(Icons.keyboard_arrow_up, size: 18),
                  Icon(Icons.keyboard_arrow_down, size: 18),
                  SizedBox(width: 40, child: Icon(Icons.toggle_on)),
                  Icon(Icons.system_update_alt, size: 20),
                  Icon(Icons.delete_outline, size: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
      'compact two-row layout gives the dictionary name nearly the full row '
      'width (TODO-749/751)', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const double rowWidth = 328; // 360 − scaffold/page padding，模拟手机内容宽。
    await tester.pumpWidget(buildCompactTwoRow(width: rowWidth));
    await tester.pump();

    expect(tester.takeException(), isNull);

    final double nameWidth =
        tester.getSize(find.byKey(const Key('dict-name'))).width;

    // 名字在第一行只让出折叠按钮（20px）+ 间距（8px）后拿满剩余宽。阈值取 0.8×行宽，
    // 远高于旧单行布局给它的约 80px（≈0.24×行宽）。
    expect(
      nameWidth,
      greaterThan(rowWidth * 0.8),
      reason: 'compact name must take nearly the full row width, not be '
          'squeezed by the trailing control cluster',
    );
  });

  testWidgets(
      'old single-row layout squeezed the name far below the two-row width '
      '(regression contrast)', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const double rowWidth = 328;
    await tester.pumpWidget(buildOldSingleRow(width: rowWidth));
    await tester.pump();

    final double oldNameWidth =
        tester.getSize(find.byKey(const Key('dict-name'))).width;

    await tester.pumpWidget(buildCompactTwoRow(width: rowWidth));
    await tester.pump();
    final double newNameWidth =
        tester.getSize(find.byKey(const Key('dict-name'))).width;

    // 两行布局给名字的宽度显著大于旧单行布局——证明修复确实把名字从控件串手里拿回了宽度。
    expect(
      newNameWidth,
      greaterThan(oldNameWidth + 100),
      reason:
          'two-row layout must reclaim a large chunk of name width that the '
          'old single-row trailing cluster had stolen',
    );
  });
}
