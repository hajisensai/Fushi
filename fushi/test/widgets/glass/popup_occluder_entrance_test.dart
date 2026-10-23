import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:material_ui/material_ui.dart';

// 反馈 iZupbhhdNV「视频查词框内出现播放画面（很短的一下，次级查词才有）」。
//
// 嵌套查词时下层卡被上层卡盖住的部分会被 [PopupOccluderClip] 整块裁掉（玻璃叠玻璃
// 修正，Windows / Linux）。曾按上层 `visible` 判：上层一翻可见，下层同一帧就挖洞，
// 而上层正从透明度 0 淡入（[parkedPopupLayer] 的入场淡入）——那段时间洞口什么都不挡，
// 底下的视频画面直接透出来。修法：只有入场淡入走完的上层
// （[DictionaryPopupEntry.entranceSettled]，由 parkedPopupLayer 的 onEntranceSettled
// 回报）才进下层的 occluders。

const Size _screen = Size(800, 600);
const Rect _lowerRect = Rect.fromLTWH(100, 100, 400, 400);
const Rect _upperRect = Rect.fromLTWH(200, 300, 400, 250);

/// 与 `dictionary_page_mixin` / `base_source_page` 两个宿主同一套写法的最小宿主：
/// 占位条目 + parkedPopupLayer + 按 `visible && entranceSettled` 筛 occluders。
class _Host extends StatefulWidget {
  const _Host({required this.entries, super.key});

  final List<DictionaryPopupEntry> entries;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  void rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final List<DictionaryPopupEntry> entries = widget.entries;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        const Positioned.fill(
          child: ColoredBox(key: ValueKey<String>('video'), color: Colors.red),
        ),
        for (int index = 0; index < entries.length; index++)
          parkedPopupLayer(
            key: ObjectKey(entries[index]),
            pos: entries[index].selectionRect,
            visible: entries[index].visible,
            screen: _screen,
            occluders: <Rect>[
              for (int j = index + 1; j < entries.length; j++)
                if (entries[j].visible && entries[j].entranceSettled)
                  entries[j].selectionRect,
            ],
            onEntranceSettled: (bool settled) {
              if (!mounted || entries[index].entranceSettled == settled) {
                return;
              }
              setState(() => entries[index].entranceSettled = settled);
            },
            child: ColoredBox(
              key: ValueKey<String>('layer$index'),
              color: Colors.black,
            ),
          ),
      ],
    );
  }
}

Finder _lowerClip() => find.descendant(
  of: find.byKey(ObjectKey(_lower)),
  matching: find.byType(ClipPath),
);

late DictionaryPopupEntry _lower;

void main() {
  testWidgets(
    'lower layer is not cut open while the upper layer is still fading in '
    '(iZupbhhdNV)',
    (WidgetTester tester) async {
      _lower = DictionaryPopupEntry(searchTerm: 'a', selectionRect: _lowerRect);
      final DictionaryPopupEntry upper = DictionaryPopupEntry(
        searchTerm: 'b',
        selectionRect: _upperRect,
        visible: false,
      );
      final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: _Host(
            key: hostKey,
            entries: <DictionaryPopupEntry>[_lower, upper],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_lower.entranceSettled, isTrue);
      expect(upper.entranceSettled, isFalse);
      expect(_lowerClip(), findsNothing);

      // 嵌套查词：上层翻可见，开始从 0 淡入。
      upper.visible = true;
      hostKey.currentState!.rebuild();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      final FadeTransition upperFade = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.byKey(const ValueKey<String>('layer1')),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      expect(
        upperFade.opacity.value,
        lessThan(1.0),
        reason: 'precondition: upper layer is mid-fade',
      );
      // 关键断言：上层还半透明时，下层不得被挖洞（否则洞口直接露出视频）。
      expect(_lowerClip(), findsNothing);

      // 淡入走完 → 回报 settled → 下层才裁掉被盖住的部分（玻璃叠玻璃修正照常生效）。
      await tester.pumpAndSettle();
      expect(upper.entranceSettled, isTrue);
      expect(_lowerClip(), findsOneWidget);

      // 上层收起（热槽隐藏）：洞口立刻撤掉，settled 复位，下次再淡入时重新等。
      upper.visible = false;
      hostKey.currentState!.rebuild();
      await tester.pump();
      expect(_lowerClip(), findsNothing);
      await tester.pumpAndSettle();
      expect(upper.entranceSettled, isFalse);
    },
  );

  test('both popup hosts gate occluders on entranceSettled and report it', () {
    for (final String path in <String>[
      'lib/src/pages/base_source_page.dart',
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
    ]) {
      final String src = File(path).readAsStringSync();
      expect(src, contains('.entranceSettled)'), reason: path);
      expect(src, contains('onEntranceSettled: (bool settled)'), reason: path);
    }
  });
}
