import 'dart:convert';

import 'package:fushi_engine/media/manga/panel_detection.dart';

class MangaPanelEntry {
  const MangaPanelEntry({required this.pageIndex, required this.panel});

  final int pageIndex;
  final PanelRect panel;
}

/// 当前页的分镜游标。游标只属于一次阅读会话，不写入章节进度。
class MangaPanelNavigationCursor {
  int _index = -1;

  int get index => _index;

  void reset() => _index = -1;

  PanelRect? move(List<PanelRect> panels, {required bool forward}) {
    if (panels.isEmpty) return null;
    final int next = _index < 0 && !forward
        ? panels.length - 1
        : _index + (forward ? 1 : -1);
    if (next < 0 || next >= panels.length) {
      return null;
    }
    _index = next;
    return panels[_index];
  }

  MangaPanelEntry? moveEntries(
    List<MangaPanelEntry> entries, {
    required bool forward,
  }) {
    if (entries.isEmpty) return null;
    final int next = _index < 0 && !forward
        ? entries.length - 1
        : _index + (forward ? 1 : -1);
    if (next < 0 || next >= entries.length) return null;
    _index = next;
    return entries[_index];
  }
}

/// 生成注入 WebView 的聚焦调用。坐标使用页面归一化值，JS 负责将它换算到当前
/// spread 的实际图片矩形，并在视口边界内完成缩放/平移。
String mangaFocusPanelJavascript(int pageIndex, PanelRect panel) {
  return 'window.__mangaFocusPanel && '
      'window.__mangaFocusPanel($pageIndex, ${jsonEncode(<String, double>{'left': panel.left, 'top': panel.top, 'right': panel.right, 'bottom': panel.bottom})});';
}

/// 将一个 spread 的多页结果合并为阅读顺序，页面顺序由调用方提供。
List<PanelRect> mergeSpreadPanels(
  Iterable<List<PanelRect>> pages, {
  required PanelReadingDirection direction,
}) {
  final List<PanelRect> merged = <PanelRect>[];
  for (final List<PanelRect> page in pages) {
    merged.addAll(page);
  }
  return orderPanelRects(merged, direction: direction);
}

/// 保留页身份的双页阅读顺序。分镜坐标是页内坐标，合并后不能再次把不同页面
/// 的归一化矩形混在一起排序，否则左右页会被错误地按页内 y 坐标交叉。
List<MangaPanelEntry> mergeSpreadPanelEntries(
  Iterable<({int pageIndex, List<PanelRect> panels})> pages, {
  required PanelReadingDirection direction,
}) {
  final List<MangaPanelEntry> entries = <MangaPanelEntry>[];
  for (final ({int pageIndex, List<PanelRect> panels}) page in pages) {
    for (final PanelRect panel in orderPanelRects(
      page.panels,
      direction: direction,
    )) {
      entries.add(MangaPanelEntry(pageIndex: page.pageIndex, panel: panel));
    }
  }
  return List<MangaPanelEntry>.unmodifiable(entries);
}
