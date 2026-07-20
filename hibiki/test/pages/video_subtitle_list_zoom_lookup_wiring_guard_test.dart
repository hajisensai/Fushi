import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// 视频字幕列表「缩放 / 字号持久化 / Shift 查词」页面级接线的 source guard
/// （BUG-877 / BUG-878 / BUG-879 / BUG-880 / BUG-881）。这些接线活在 5500 行的
/// [VideoHibikiPage]（主壳 + part 文件），无法在无头 libmpv 下驱动，故按源扫描守卫；
/// 面板本体行为由 `video_subtitle_jump_panel_test.dart` 的 widget 测试覆盖。
void main() {
  final String src = readVideoHibikiSource();

  group('BUG-877 面板宽度可自定义 + 持久化', () {
    test('面板宽度从 Drift preferences 读（未自定义按屏宽自适应）', () {
      expect(
        src.contains('appModel.videoSubtitleListWidth'),
        isTrue,
        reason: '面板宽度必须读持久化值（0=跟随自适应）',
      );
    });

    test('存在左边缘拖拽把手并把宽度落盘', () {
      expect(
        src.contains('_subtitleListResizeHandle('),
        isTrue,
        reason: '必须有左边缘拖拽把手改宽度（撤 BUG-877 → 无把手）',
      );
      expect(
        src.contains('appModel.setVideoSubtitleListWidth('),
        isTrue,
        reason: '拖拽 / 双击复位必须经 appModel setter 落 Drift preferences',
      );
    });
  });

  group('BUG-878 行字号档位持久化', () {
    test('面板字号档位初值从 Drift preferences 读', () {
      expect(
        RegExp(r'initialFontScaleIndex:\s*'
                r'appModel\.videoSubtitleListFontScaleIndex')
            .hasMatch(src),
        isTrue,
        reason: '字号档位初值必须来自持久化（不再每次重开重置成默认档）',
      );
    });

    test('调节字号经 appModel setter 落盘', () {
      expect(
        RegExp(r'onFontScaleIndexChanged:\s*\(int value\) => unawaited\(\s*'
                r'appModel\s*\.setVideoSubtitleListFontScaleIndex\(value\)')
            .hasMatch(src),
        isTrue,
        reason: '字号档位变化必须经 appModel setter 持久化（BUG-878）',
      );
    });
  });

  group('BUG-879 列表行文本 Shift-悬停查词门控传入', () {
    test('面板收到 hoverAutoLookupEnabled（与画面字幕同源）', () {
      expect(
        RegExp(r'VideoSubtitleJumpPanel\([\s\S]*?hoverAutoLookupEnabled:\s*'
                r'ReaderHibikiSource\.instance\.hoverAutoLookup')
            .hasMatch(src),
        isTrue,
        reason: '列表 Shift-悬停查词门控必须与画面字幕共用同一 hoverAutoLookup',
      );
    });
  });

  group('BUG-880 Shift 静止光标查词（keydown 反查最后指针位置）', () {
    test('页面根持续记录全局指针位置', () {
      expect(
        RegExp(r'onPointerHover:\s*\(PointerHoverEvent event\) =>\s*'
                r'_lastGlobalPointerPos = event\.position')
            .hasMatch(src),
        isTrue,
        reason: 'Shift 按下时要用最后指针位置反查，必须先在页面根记录它',
      );
    });

    test('Shift 按下触发 keydown 反查查词', () {
      expect(
        RegExp(r'event is KeyDownEvent[\s\S]*?'
                r'LogicalKeyboardKey\.shiftLeft[\s\S]*?'
                r'_triggerShiftLookupAtLastPointer\(\)')
            .hasMatch(src),
        isTrue,
        reason: 'Shift keydown 必须触发在最后指针位置的反查查词（根治「按了不出」）',
      );
    });

    test('反查同时覆盖画面字幕与字幕列表两个命中句柄', () {
      final RegExp method = RegExp(
        r'void _triggerShiftLookupAtLastPointer\(\)[\s\S]*?\n  \}',
      );
      final Match? match = method.firstMatch(src);
      expect(match, isNotNull,
          reason: '必须存在 _triggerShiftLookupAtLastPointer 方法');
      final String body = match!.group(0)!;
      expect(body.contains('_subtitleHitTester.hitTest'), isTrue,
          reason: 'Shift 按下要能反查画面字幕字符');
      expect(body.contains('_subtitleListHitTester.hitTest'), isTrue,
          reason: 'Shift 按下也要能反查字幕列表侧栏字符');
    });
  });

  group('BUG-881 浮层开着时 barrier 悬停反查列表兜底', () {
    test('_onDismissBarrierHover 在画面字幕 miss 后反查字幕列表', () {
      final RegExp method = RegExp(
        r'void _onDismissBarrierHover\(PointerHoverEvent event\)'
        r'[\s\S]*?\n  \}',
      );
      final Match? match = method.firstMatch(src);
      expect(match, isNotNull, reason: '必须存在 _onDismissBarrierHover 方法');
      final String body = match!.group(0)!;
      expect(body.contains('_subtitleListHitTester.hitTest'), isTrue,
          reason: '浮层开着时 Shift 悬停列表下一个词必须经 barrier 反查列表句柄换词'
              '（与 barrier tap 的列表兜底对称，BUG-881）');
      expect(body.contains('_lastGlobalPointerPos = event.position'), isTrue,
          reason: '浮层盖住页面根 Listener 时，barrier hover 要接力更新最后指针位置'
              '（供 Shift keydown 在浮层态也能反查）');
    });
  });
}
