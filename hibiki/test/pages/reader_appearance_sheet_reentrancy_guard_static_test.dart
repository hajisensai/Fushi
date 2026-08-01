import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';
import '../helpers/source_guard.dart';

void main() {
  // BUG-026: 快速连点底栏「调整」会弹出两个面板。
  //
  // 根因：_showAppearanceSheet 在按钮按下到真正 show 之间还有 await（查收藏
  // favRepo.getAll）。该 await 期间事件循环让出，
  // 快速第二次点击会再次进入 _showAppearanceSheet，越过入口的 null 守卫、也走到
  // showModalBottomSheet/showAppDialog → 两个面板叠加。
  //
  // 修复：加重入标志 _appearanceSheetOpen——入口若已 true 直接 return；置 true 必须
  // 在第一个 await 之前（否则窗口仍在），并用 try/finally 在面板关闭后复位（异常也
  // 复位，避免标志卡死导致面板再也打不开）。本守卫锁定该结构。reader 页含真实
  // InAppWebView 平台视图无法 widget 挂载，源码扫描守卫为最强可落地层。
  final String source = readReaderPageSource();
  final String stripped = _stripLineComments(source);
  final String sheet = _functionSource(
    stripped,
    '  Future<void> _showAppearanceSheet(',
    '  String _currentChapterLabel() {',
  );

  test('_showAppearanceSheet bails on re-entry (no double sheet on fast taps)',
      () {
    expect(
      sheet.contains('if (_appearanceSheetOpen) return;'),
      isTrue,
      reason: '入口必须在已打开时直接 return，挡住快速连点的二次进入',
    );
    expect(
      // BUG-969：置位改经 _rebuild(() => ...)，让顶部进度 pill 在抽屉打开期间摘掉
      // BackdropFilter blur（见 topProgressPillShowsBlur）；仍是同步置位，重入窗口不变。
      sheet.contains('_rebuild(() => _appearanceSheetOpen = true)'),
      isTrue,
      reason: '必须置重入标志（经 _rebuild 同步置位以联动 pill blur，BUG-969）',
    );
  });

  test('the re-entry guard is set before the first await', () {
    final int guardIndex = sheet.indexOf('_appearanceSheetOpen = true');
    final int firstAwaitIndex = sheet.indexOf('await ');
    expect(guardIndex, isNonNegative);
    expect(firstAwaitIndex, isNonNegative);
    expect(
      guardIndex,
      lessThan(firstAwaitIndex),
      reason: '标志必须在第一个 await 之前置位，否则 await 期间仍有重入窗口',
    );
  });

  test('the re-entry guard is reset in a finally block', () {
    final int finallyIndex = sheet.indexOf('finally');
    final int resetIndex = sheet.indexOf('_appearanceSheetOpen = false;');
    expect(finallyIndex, isNonNegative,
        reason: '必须用 finally 复位，确保异常路径也复位、标志不卡死');
    expect(resetIndex, isNonNegative, reason: '必须复位重入标志');
    expect(
      finallyIndex,
      lessThan(resetIndex),
      reason: '复位必须在 finally 块内（而非仅正常路径）',
    );
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  if (startIndex < 0) throw StateError('Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  if (endIndex < 0) throw StateError('Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}

String _stripLineComments(String source) => maskCommentsAndScriptLines(source);
