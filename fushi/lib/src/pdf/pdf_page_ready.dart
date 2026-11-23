import 'dart:async';

import 'dart:ui' show Offset, Rect;
import 'package:pdfrx/pdfrx.dart';

/// PDF 逐步加载下「页真正就绪」的唯一入口（HBK-AUDIT-210）。
///
/// pdfrx 的 `PdfViewer` 默认 `useProgressiveLoading: true`：控制器 `isReady` 时只
/// 有首批页加载好，其余页是占位实例（`isLoaded == false`），后台按序逐批替换。
/// 占位页上 `loadText()` 直接返回 null，`loadStructuredText()` 因而给出**空文本**
/// ——与「这页没有文本层」无从区分。阅读页的搜索 / 查词 / 有声书高亮若直接读占位页，
/// 会把未加载的页当成空白页：搜索漏掉后半本、同一查询的漏搜结果被沿用，查词与高亮
/// 把空文本写进缓存后这一页永远读不出字。
///
/// 所以读文本层前一律先经 [pdfLoadedPage] 拿到该页**加载好的那个实例**。

/// 等第 [pageIndex] 页（0 起）真正加载好，返回其最新实例。
///
/// 已加载直接返回；否则订阅 [PdfDocument.events]，每来一个事件重新取
/// `document.pages[pageIndex]` 看它是否已加载（加载好的页是换进来的新实例，旧占位
/// 实例的 `isLoaded` 永远是 false）。返回 null 的情形：页码越界；文档已销毁
/// （pdfrx 销毁时关闭事件流）；[cancel] 先完成（调用方生命周期结束，例如阅读页
/// dispose——viewer 卸载后逐步加载会停，页可能永远不来，不能干等）。
Future<PdfPage?> pdfLoadedPage(
  PdfDocument document,
  int pageIndex, {
  Future<void>? cancel,
}) async {
  PdfPage? current() {
    final List<PdfPage> pages = document.pages;
    return pageIndex >= 0 && pageIndex < pages.length ? pages[pageIndex] : null;
  }

  final PdfPage? now = current();
  if (now == null || now.isLoaded) return now;

  final Completer<PdfPage?> done = Completer<PdfPage?>();
  void finish(PdfPage? page) {
    if (!done.isCompleted) done.complete(page);
  }

  void recheck() {
    final PdfPage? page = current();
    if (page == null || page.isLoaded) finish(page);
  }

  final StreamSubscription<PdfDocumentEvent> sub = document.events.listen(
    (_) => recheck(),
    onDone: () => finish(null),
    onError: (Object _) => recheck(),
  );
  if (cancel != null) unawaited(cancel.then((_) => finish(null)));
  // 取实例与订阅之间可能刚好换进了加载好的页：订阅后再核一次。
  recheck();
  try {
    return await done.future;
  } finally {
    await sub.cancel();
  }
}

/// 读第 [pageIndex] 页（0 起）的结构化文本层：先等该页真正加载（[pdfLoadedPage]），
/// 再 `loadStructuredText`。页等不到（越界 / 文档销毁 / [cancel]）返回 null；
/// 返回空 `fullText` 才真的表示这页没有文本层。
Future<PdfPageText?> pdfLoadPageText(
  PdfDocument document,
  int pageIndex, {
  Future<void>? cancel,
}) async {
  final PdfPage? page = await pdfLoadedPage(
    document,
    pageIndex,
    cancel: cancel,
  );
  if (page == null) return null;
  return page.loadStructuredText();
}

/// 把按旧页框 [from] 给出的文档坐标 [position] 按页内相对位置搬到新页框 [to]。
///
/// 等页加载期间 pdfrx 会用真实尺寸重排布局（占位页的尺寸是猜的，整册宽度也可能
/// 变），点下时的文档坐标在新布局里已不指向原来那一点；按比例换算才落回用户点的
/// 那处内容。页框没变时原样返回。
Offset pdfRemapToPageRect(
  Offset position, {
  required Rect from,
  required Rect to,
}) {
  if (from == to || from.width <= 0 || from.height <= 0) return position;
  return Offset(
    to.left + (position.dx - from.left) / from.width * to.width,
    to.top + (position.dy - from.top) / from.height * to.height,
  );
}
