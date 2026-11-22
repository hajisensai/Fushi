import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pdf/pdf_page_ready.dart';
import 'package:fushi/src/pdf/pdf_text_search.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:pdfrx/pdfrx.dart';

/// 逐步加载的替身文档：与 pdfium 实现同口径——占位页 `isLoaded == false` 且
/// `loadText()` 返回 null；加载好时换进新实例并发 [PdfDocumentPageStatusChangedEvent]；
/// 销毁时关闭事件流。
class _FakeDocument implements PdfDocument {
  final StreamController<PdfDocumentEvent> _events =
      StreamController<PdfDocumentEvent>.broadcast();

  List<PdfPage> _pages = <PdfPage>[];

  @override
  List<PdfPage> get pages => _pages;

  @override
  set pages(List<PdfPage> value) => _pages = value;

  @override
  Stream<PdfDocumentEvent> get events => _events.stream;

  /// 第 [pageIndex] 页（0 起）加载完成：换成带 [text] 的真实例并发事件。
  void loadPage(int pageIndex, String text) {
    final _FakePage page = _FakePage(this, pageIndex + 1, text: text);
    _pages = <PdfPage>[..._pages]..[pageIndex] = page;
    _events.add(
      PdfDocumentPageStatusChangedEvent(
        this,
        changes: <int, PdfPageStatusChange>{
          pageIndex + 1: PdfPageStatusChange.modified(page: page),
        },
      ),
    );
  }

  @override
  Future<void> dispose() => _events.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePage implements PdfPage {
  _FakePage(this.document, this.pageNumber, {this.text});

  @override
  final PdfDocument document;

  @override
  final int pageNumber;

  /// null = 逐步加载的占位页。
  final String? text;

  @override
  bool get isLoaded => text != null;

  @override
  Future<PdfPageRawText?> loadText() async {
    final String? t = text;
    if (t == null) return null;
    return PdfPageRawText(t, <PdfRect>[
      for (int i = 0; i < t.length; i++)
        PdfRect(i * 10.0, 100, i * 10.0 + 10, 90),
    ]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 首页已加载、其余是占位页的文档（`PdfViewer` 刚 ready 时的样子）。
_FakeDocument _progressiveDoc(int pageCount, {required String firstPage}) {
  final _FakeDocument doc = _FakeDocument();
  doc.pages = <PdfPage>[
    _FakePage(doc, 1, text: firstPage),
    for (int i = 2; i <= pageCount; i++) _FakePage(doc, i),
  ];
  return doc;
}

void main() {
  group('HBK-AUDIT-210 逐步加载的页先等就绪再读文本层', () {
    test('前提：占位页直接 loadStructuredText 得到空文本（旧实现的漏读来源）', () async {
      final _FakeDocument doc = _progressiveDoc(3, firstPage: 'はじめ');
      final PdfPageText raw = await doc.pages[2].loadStructuredText();
      expect(raw.fullText, isEmpty);
    });

    test('占位页：等到它加载好再读，读到真实文本', () async {
      final _FakeDocument doc = _progressiveDoc(3, firstPage: 'はじめ');
      final Future<PdfPageText?> pending = pdfLoadPageText(doc, 2);
      bool settled = false;
      unawaited(pending.then((_) => settled = true));
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse, reason: '页还没加载，不能拿空文本交差');

      doc.loadPage(1, 'なか'); // 别的页加载不影响
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);

      doc.loadPage(2, '末尾の唯一語');
      final PdfPageText? text = await pending;
      expect(text?.fullText, '末尾の唯一語');
    });

    test('已加载的页直接返回', () async {
      final _FakeDocument doc = _progressiveDoc(2, firstPage: 'はじめ');
      expect((await pdfLoadPageText(doc, 0))?.fullText, 'はじめ');
    });

    test('页码越界返回 null', () async {
      final _FakeDocument doc = _progressiveDoc(2, firstPage: 'はじめ');
      expect(await pdfLoadedPage(doc, 5), isNull);
      expect(await pdfLoadedPage(doc, -1), isNull);
    });

    test('等待中文档销毁（事件流关闭）返回 null，不挂死', () async {
      final _FakeDocument doc = _progressiveDoc(3, firstPage: 'はじめ');
      final Future<PdfPage?> pending = pdfLoadedPage(doc, 2);
      await doc.dispose();
      expect(await pending, isNull);
    });

    test('等待中调用方生命周期结束（cancel）返回 null，不挂死', () async {
      final _FakeDocument doc = _progressiveDoc(3, firstPage: 'はじめ');
      final Completer<void> disposed = Completer<void>();
      final Future<PdfPage?> pending = pdfLoadedPage(
        doc,
        2,
        cancel: disposed.future,
      );
      disposed.complete();
      expect(await pending, isNull);
    });

    test('开页立即搜索末页唯一词：结果等末页加载后仍命中', () async {
      final _FakeDocument doc = _progressiveDoc(4, firstPage: 'はじめ');
      final PdfTextSearchController search = PdfTextSearchController(
        loadPage: (int pageIndex) async {
          final PdfPageText? text = await pdfLoadPageText(doc, pageIndex);
          if (text == null) return null;
          return (
            fullText: text.fullText,
            rectsFor: (int start, int end) => const <PdfRect>[],
          );
        },
        normalize: (String text) => NormalizedTextWithOffsets(
          text,
          <int>[for (int i = 0; i < text.length; i++) i],
          <int>[for (int i = 0; i < text.length; i++) i + 1],
        ),
      );
      addTearDown(search.dispose);

      final Future<void> running = search.search('唯一語', pageCount: 4);
      // 逐步加载在后台按序把后几页换进来。
      await Future<void>.delayed(Duration.zero);
      doc.loadPage(1, 'なか');
      await Future<void>.delayed(Duration.zero);
      doc.loadPage(2, 'つづき');
      await Future<void>.delayed(Duration.zero);
      doc.loadPage(3, '末尾の唯一語');
      await running;

      expect(search.status, PdfTextSearchStatus.done);
      expect(search.hits.map((PdfTextSearchHit h) => h.pageIndex), <int>[3]);
    });
  });
}
