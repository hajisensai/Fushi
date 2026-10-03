import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/manga_ocr_pipeline.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:image/image.dart' as img;

/// 用页面图像高度编码页号（height = 1000 + pageIndex），fake 组件借此计数。
img.Image pageImage(int pageIndex) =>
    img.Image(width: 500, height: 1000 + pageIndex);

int pageOf(img.Image image) => image.height - 1000;

class FakeDetector implements OcrDetector {
  final Map<int, int> callsByPage = <int, int>{};

  /// 每页返回两个文字块：右上（竖排瘦高）+ 左侧（横排扁宽），外加一个气泡。
  @override
  Future<PageDetections> detect(img.Image page) async {
    callsByPage.update(pageOf(page), (int c) => c + 1, ifAbsent: () => 1);
    const OcrRect rightTall = OcrRect(
      left: 400,
      top: 10,
      right: 440,
      bottom: 130,
    );
    const OcrRect leftWide = OcrRect(left: 20, top: 40, right: 200, bottom: 80);
    return const PageDetections(
      textRegions: <DetectedTextRegion>[
        DetectedTextRegion(
          rect: leftWide,
          score: 0.8,
          classId: 2,
          insideBubble: false,
        ),
        DetectedTextRegion(
          rect: rightTall,
          score: 0.9,
          classId: 1,
          insideBubble: true,
        ),
      ],
      bubbles: <OcrRect>[OcrRect(left: 390, top: 0, right: 450, bottom: 140)],
    );
  }
}

class FakeRecognizer implements OcrRecognizer {
  int calls = 0;

  /// 返回 "p<页号>@<left>"，方便断言识别与块的对应关系。
  @override
  Future<String> recognize(img.Image page, OcrRect box) async {
    calls++;
    return 'p${pageOf(page)}@${box.left.toInt()}';
  }
}

class MemoryCache implements OcrPageCache {
  final Map<String, OcrPageResult> store = <String, OcrPageResult>{};
  final List<int> writes = <int>[];

  @override
  Future<OcrPageResult?> read(String bookId, int pageIndex) async =>
      store['$bookId/$pageIndex'];

  @override
  Future<void> write(String bookId, OcrPageResult result) async {
    writes.add(result.pageIndex);
    store['$bookId/${result.pageIndex}'] = result;
  }
}

class _BatchRecognizer implements BatchOcrRecognizer {
  final List<List<OcrRect>> batches = <List<OcrRect>>[];
  final List<img.Image> pages = <img.Image>[];
  double? emptyLeft;
  int? returnedCount;
  void Function()? onBatch;
  int active = 0;
  int maxActive = 0;

  @override
  Future<String> recognize(img.Image page, OcrRect box) =>
      throw StateError('Batch-capable pipeline must not fall back to singles');

  @override
  Future<List<String>> recognizeBatch(
    img.Image page,
    List<OcrRect> boxes,
  ) async {
    pages.add(page);
    batches.add(List<OcrRect>.of(boxes));
    active++;
    if (active > maxActive) maxActive = active;
    await Future<void>.value();
    onBatch?.call();
    active--;
    if (returnedCount != null) {
      return List<String>.filled(returnedCount!, 'wrong shape');
    }
    return <String>[
      for (final OcrRect box in boxes)
        box.left == emptyLeft ? '' : 'p${pageOf(page)}@${box.left.toInt()}',
    ];
  }
}

class _FixedDetector implements OcrDetector {
  _FixedDetector(this.regions);

  final List<DetectedTextRegion> regions;
  int calls = 0;
  void Function()? onDetect;

  @override
  Future<PageDetections> detect(img.Image page) async {
    calls++;
    onDetect?.call();
    return PageDetections(textRegions: regions, bubbles: const <OcrRect>[]);
  }
}

List<DetectedTextRegion> _columns(int count) => <DetectedTextRegion>[
      for (int index = 0; index < count; index++)
        DetectedTextRegion(
          rect: OcrRect(
            left: (index * 20).toDouble(),
            top: 0,
            right: (index * 20 + 10).toDouble(),
            bottom: 100,
          ),
          score: index / count,
          classId: index.isEven ? 1 : 2,
          insideBubble: index.isEven,
        ),
    ];

class _TextRecognizer implements OcrRecognizer {
  _TextRecognizer(this.texts);

  final Map<OcrRect, String> texts;
  final List<OcrRect> calls = <OcrRect>[];

  @override
  Future<String> recognize(img.Image page, OcrRect box) async {
    calls.add(box);
    return texts[box]!;
  }
}

class _BatchTextRecognizer extends _TextRecognizer
    implements BatchOcrRecognizer {
  _BatchTextRecognizer(super.texts);

  final List<List<OcrRect>> batches = <List<OcrRect>>[];

  @override
  Future<List<String>> recognizeBatch(
    img.Image page,
    List<OcrRect> boxes,
  ) async {
    batches.add(List<OcrRect>.of(boxes));
    return <String>[for (final OcrRect box in boxes) texts[box]!];
  }
}

DetectedTextRegion _region(OcrRect rect, double score) => DetectedTextRegion(
      rect: rect,
      score: score,
      classId: 2,
      insideBubble: false,
    );

void main() {
  group('补检（检测器弱候选）', () {
    test('弱候选与已有块交给补检器，补回的块按阅读序并入', () async {
      final _SweepDetector detector = _SweepDetector();
      final _RecordingSweeper sweeper = _RecordingSweeper(<OcrBlock>[
        const OcrBlock(
          box: OcrRect(left: 30, top: 300, right: 300, bottom: 360),
          vertical: false,
          lines: <String>['モテる女子の', 'オキテ'],
          lineBoxes: <OcrRect>[
            OcrRect(left: 30, top: 300, right: 300, bottom: 330),
            OcrRect(left: 60, top: 335, right: 200, bottom: 360),
          ],
          score: 0.97,
        ),
      ]);
      final OcrPageResult result = await MangaOcrPipeline(
        detector: detector,
        recognizer: FakeRecognizer(),
        sweeper: sweeper,
      ).processPage(pageIndex: 0, image: pageImage(0));

      expect(sweeper.calls, 1);
      expect(sweeper.candidates, detector.weak);
      expect(sweeper.covered, <OcrRect>[_SweepDetector.top]);
      // 上面的正式块在前，下面补回的标题在后；补回块的行几何原样保留。
      expect(result.blocks.map((OcrBlock b) => b.text), <String>[
        'p0@400',
        'モテる女子のオキテ',
      ]);
      expect(result.blocks.last.lineBoxes, hasLength(2));
    });

    test('没有弱候选时不调补检器', () async {
      final _RecordingSweeper sweeper = _RecordingSweeper(const <OcrBlock>[]);
      final OcrPageResult result = await MangaOcrPipeline(
        detector: _SweepDetector(weak: const <DetectedTextRegion>[]),
        recognizer: FakeRecognizer(),
        sweeper: sweeper,
      ).processPage(pageIndex: 0, image: pageImage(0));
      expect(sweeper.calls, 0);
      expect(result.blocks, hasLength(1));
    });

    test('没有补检器时弱候选被忽略，结果与原来一致', () async {
      final OcrPageResult result = await MangaOcrPipeline(
        detector: _SweepDetector(),
        recognizer: FakeRecognizer(),
      ).processPage(pageIndex: 0, image: pageImage(0));
      expect(result.blocks.map((OcrBlock b) => b.text), <String>['p0@400']);
    });
  });

  group('识别后包含去重', () {
    const OcrRect parent = OcrRect(left: 0, top: 0, right: 400, bottom: 200);
    const OcrRect child = OcrRect(left: 20, top: 120, right: 220, bottom: 130);
    final List<
        ({
          String name,
          OcrRect outer,
          OcrRect inner,
          double score,
          String parentText,
          String childText,
          List<String> expected,
        })> cases = [
      (
        name: '父框漏正文时保留小字内框',
        outer: parent,
        inner: child,
        score: 0.9,
        parentText: 'TITLE',
        childText: 'BODY',
        expected: ['TITLE', 'BODY'],
      ),
      (
        name: '完整包含子文本才去重',
        outer: parent,
        inner: child,
        score: 0.9,
        parentText: 'TITLEBODYEND',
        childText: 'BODY',
        expected: ['TITLEBODYEND'],
      ),
      (
        name: '完全相同文本只留高分父框',
        outer: parent,
        inner: child,
        score: 0.9,
        parentText: 'BODY',
        childText: 'BODY',
        expected: ['BODY'],
      ),
      (
        name: '仅文本部分重叠不去重',
        outer: parent,
        inner: child,
        score: 0.9,
        parentText: 'TITLEBOD',
        childText: 'BODY',
        expected: ['TITLEBOD', 'BODY'],
      ),
      (
        name: '同分保留两框',
        outer: parent,
        inner: child,
        score: 0.8,
        parentText: 'TITLEBODY',
        childText: 'BODY',
        expected: ['TITLEBODY', 'BODY'],
      ),
      (
        name: '低分父框不能删除高分子框',
        outer: parent,
        inner: child,
        score: 0.7,
        parentText: 'TITLEBODY',
        childText: 'BODY',
        expected: ['TITLEBODY', 'BODY'],
      ),
      (
        name: '父框为空保留子框',
        outer: parent,
        inner: child,
        score: 0.9,
        parentText: '',
        childText: 'BODY',
        expected: ['BODY'],
      ),
      (
        name: '空子结果不影响父框',
        outer: parent,
        inner: child,
        score: 0.9,
        parentText: 'TITLE',
        childText: '',
        expected: ['TITLE'],
      ),
      (
        name: '不归一化空白后猜测文本重复',
        outer: parent,
        inner: child,
        score: 0.9,
        parentText: 'TITLEBODY',
        childText: 'BO DY',
        expected: ['TITLEBODY', 'BO DY'],
      ),
      (
        name: '部分相交不去重',
        outer: parent,
        inner: const OcrRect(left: 20, top: 195, right: 220, bottom: 210),
        score: 0.9,
        parentText: 'TITLEBODY',
        childText: 'BODY',
        expected: ['TITLEBODY', 'BODY'],
      ),
      (
        name: '竖排父框不去重',
        outer: const OcrRect(left: 0, top: 0, right: 250, bottom: 400),
        inner: child,
        score: 0.9,
        parentText: 'TITLEBODY',
        childText: 'BODY',
        expected: ['TITLEBODY', 'BODY'],
      ),
      (
        name: '近方竖框仍非横排，不能用展示用1.25阈值',
        outer: const OcrRect(left: 0, top: 0, right: 250, bottom: 275),
        inner: child,
        score: 0.9,
        parentText: 'TITLEBODY',
        childText: 'BODY',
        expected: ['TITLEBODY', 'BODY'],
      ),
      (
        name: '竖排子框不去重',
        outer: parent,
        inner: const OcrRect(left: 20, top: 120, right: 30, bottom: 190),
        score: 0.9,
        parentText: 'TITLEBODY',
        childText: 'BODY',
        expected: ['TITLEBODY', 'BODY'],
      ),
    ];
    for (final c in cases) {
      for (final bool batch in <bool>[false, true]) {
        test('${c.name} (${batch ? 'batch' : 'single'})', () async {
          final Map<OcrRect, String> texts = <OcrRect, String>{
            c.outer: c.parentText,
            c.inner: c.childText,
          };
          final _TextRecognizer recognizer =
              batch ? _BatchTextRecognizer(texts) : _TextRecognizer(texts);
          final OcrPageResult result = await MangaOcrPipeline(
            detector: _FixedDetector(<DetectedTextRegion>[
              _region(c.inner, 0.8),
              _region(c.outer, c.score),
            ]),
            recognizer: recognizer,
          ).processPage(pageIndex: 0, image: pageImage(0));
          expect(result.blocks.map((OcrBlock b) => b.lines.single), c.expected);
          final List<OcrRect> recognized = recognizer is _BatchTextRecognizer
              ? recognizer.batches.expand((List<OcrRect> b) => b).toList()
              : recognizer.calls;
          expect(
              recognized,
              <OcrRect>[
                c.outer,
                c.inner,
              ],
              reason: '包含框必须实际识别，不能预先删除');
          if (c.parentText.isNotEmpty) {
            expect(result.blocks.first.box, same(c.outer));
            expect(result.blocks.first.score, c.score);
          }
        });
      }
    }

    test('子框先识别时也能被后来父结果去重，不按分数重排输出', () async {
      const OcrRect firstChild = OcrRect(
        left: 20,
        top: 0,
        right: 220,
        bottom: 10,
      );
      final _TextRecognizer recognizer = _TextRecognizer(<OcrRect, String>{
        firstChild: 'BODY',
        parent: 'TITLEBODY',
      });
      final OcrPageResult result = await MangaOcrPipeline(
        detector: _FixedDetector(<DetectedTextRegion>[
          _region(firstChild, 0.8),
          _region(parent, 0.9),
        ]),
        recognizer: recognizer,
      ).processPage(pageIndex: 0, image: pageImage(0));
      expect(recognizer.calls, <OcrRect>[firstChild, parent]);
      expect(result.blocks.map((OcrBlock b) => b.lines.single), ['TITLEBODY']);
    });

    test('跨批次去重，保持全部识别顺序与剩余结果元数据并缓存最终结果', () async {
      const OcrRect lastChild = OcrRect(
        left: 20,
        top: 180,
        right: 220,
        bottom: 190,
      );
      final List<OcrRect> fillers = <OcrRect>[
        for (int i = 0; i < 7; i++)
          OcrRect(
            left: 20,
            top: 20.0 + i * 20,
            right: 60,
            bottom: 30.0 + i * 20,
          ),
      ];
      final List<OcrRect> order = <OcrRect>[parent, ...fillers, lastChild];
      final _BatchTextRecognizer recognizer =
          _BatchTextRecognizer(<OcrRect, String>{
        parent: 'TITLEBODY',
        lastChild: 'BODY',
        for (int i = 0; i < fillers.length; i++) fillers[i]: 'extra$i',
      });
      final MemoryCache cache = MemoryCache();
      final List<OcrPageResult> results = await MangaOcrPipeline(
        detector: _FixedDetector(<DetectedTextRegion>[
          for (final OcrRect box in order.reversed)
            _region(box, identical(box, parent) ? 0.9 : 0.8),
        ]),
        recognizer: recognizer,
        cache: cache,
      ).processBook(
        bookId: 'nested',
        pageCount: 1,
        loadPage: (int _) async => pageImage(0),
      );
      expect(recognizer.calls, isEmpty);
      expect(recognizer.batches.map((List<OcrRect> b) => b.length), [8, 1]);
      expect(recognizer.batches.expand((List<OcrRect> b) => b), order);
      expect(results.single.blocks.map((OcrBlock b) => b.box), [
        parent,
        ...fillers,
      ]);
      expect(results.single.blocks.map((OcrBlock b) => b.lines.single), [
        'TITLEBODY',
        for (int i = 0; i < 7; i++) 'extra$i',
      ]);
      expect(cache.store['nested/0'], same(results.single));
    });
  });

  group('MangaOcrPipeline', () {
    test('批识别按阅读顺序提交，空结果不让后续框、分数和气泡标记错位', () async {
      final List<DetectedTextRegion> regions = _columns(3);
      final _BatchRecognizer recognizer = _BatchRecognizer()..emptyLeft = 20;
      final img.Image image = pageImage(0);
      final OcrPageResult result = await MangaOcrPipeline(
        detector: _FixedDetector(regions),
        recognizer: recognizer,
      ).processPage(pageIndex: 0, image: image);
      expect(recognizer.batches.single.map((OcrRect box) => box.left), <double>[
        40,
        20,
        0,
      ]);
      expect(recognizer.pages.single, same(image));
      expect(result.blocks, hasLength(2));
      for (final (int output, int source) in <(int, int)>[(0, 2), (1, 0)]) {
        expect(result.blocks[output].box, same(regions[source].rect));
        expect(result.blocks[output].lines.single, 'p0@${source * 20}');
        expect(result.blocks[output].score, regions[source].score);
        expect(
          result.blocks[output].insideBubble,
          regions[source].insideBubble,
        );
        expect(result.blocks[output].vertical, isTrue);
      }
    });

    test('密集页分为最多 8 框的有界批次，批次和页面都不并发', () async {
      final _BatchRecognizer recognizer = _BatchRecognizer();
      final List<OcrPageResult> results = await MangaOcrPipeline(
        detector: _FixedDetector(_columns(19)),
        recognizer: recognizer,
      ).processBook(
        bookId: 'batch',
        pageCount: 2,
        loadPage: (int index) async => pageImage(index),
      );
      expect(
        recognizer.batches.map((List<OcrRect> boxes) => boxes.length),
        <int>[8, 8, 3, 8, 8, 3],
      );
      expect(recognizer.maxActive, 1);
      expect(recognizer.pages.map(pageOf), <int>[0, 0, 0, 1, 1, 1]);
      for (int page = 0; page < 2; page++) {
        expect(
          results[page].blocks.map((OcrBlock block) => block.lines.single),
          <String>[
            for (int column = 18; column >= 0; column--)
              'p$page@${column * 20}',
          ],
        );
      }
    });

    test('批识别也服从 LTR 阅读顺序，空页不启动识别后端', () async {
      final _BatchRecognizer recognizer = _BatchRecognizer();
      await MangaOcrPipeline(
        detector: _FixedDetector(_columns(3)),
        recognizer: recognizer,
        rightToLeft: false,
      ).processPage(pageIndex: 0, image: pageImage(0));
      expect(recognizer.batches.single.map((OcrRect box) => box.left), <double>[
        0,
        20,
        40,
      ]);
      final OcrPageResult empty = await MangaOcrPipeline(
        detector: _FixedDetector(<DetectedTextRegion>[]),
        recognizer: recognizer,
      ).processPage(pageIndex: 1, image: pageImage(1));
      expect(empty.blocks, isEmpty);
      expect(recognizer.batches, hasLength(1));
    });

    test('批结果个数错误必须报错，不能静默截断或写入页缓存', () async {
      for (final int count in <int>[1, 3]) {
        final MemoryCache cache = MemoryCache();
        final _BatchRecognizer recognizer = _BatchRecognizer()
          ..returnedCount = count;
        await expectLater(
          MangaOcrPipeline(
            detector: FakeDetector(),
            recognizer: recognizer,
            cache: cache,
          ).processBook(
            bookId: 'bad',
            pageCount: 1,
            loadPage: (int index) async => pageImage(index),
          ),
          throwsA(isA<StateError>()),
        );
        expect(cache.writes, isEmpty);
      }
    });

    test('首批结束时取消：不启动第二批，不缓存未完成页', () async {
      final OcrCancelToken token = OcrCancelToken();
      final MemoryCache cache = MemoryCache();
      final _BatchRecognizer recognizer = _BatchRecognizer()
        ..onBatch = token.cancel;
      await expectLater(
        MangaOcrPipeline(
          detector: _FixedDetector(_columns(9)),
          recognizer: recognizer,
          cache: cache,
        ).processBook(
          bookId: 'cancel',
          pageCount: 1,
          loadPage: (int index) async => pageImage(index),
          cancelToken: token,
        ),
        throwsA(isA<OcrCancelledException>()),
      );
      expect(recognizer.batches, hasLength(1));
      expect(cache.writes, isEmpty);
    });

    test('检测之前或检测期间取消，都不启动批识别', () async {
      for (final bool beforeDetection in <bool>[true, false]) {
        final OcrCancelToken token = OcrCancelToken();
        final _FixedDetector detector = _FixedDetector(_columns(2));
        final _BatchRecognizer recognizer = _BatchRecognizer();
        if (beforeDetection) {
          token.cancel();
        } else {
          detector.onDetect = token.cancel;
        }
        await expectLater(
          MangaOcrPipeline(
            detector: detector,
            recognizer: recognizer,
          ).processPage(pageIndex: 0, image: pageImage(0), cancelToken: token),
          throwsA(isA<OcrCancelledException>()),
        );
        expect(detector.calls, beforeDetection ? 0 : 1);
        expect(recognizer.batches, isEmpty);
      }
    });

    test('整卷处理：阅读顺序（RTL 右块在前）、竖排判定、进度回调', () async {
      final FakeDetector detector = FakeDetector();
      final FakeRecognizer recognizer = FakeRecognizer();
      final MemoryCache cache = MemoryCache();
      final MangaOcrPipeline pipeline = MangaOcrPipeline(
        detector: detector,
        recognizer: recognizer,
        cache: cache,
      );
      final List<List<int>> progress = <List<int>>[];
      final List<OcrPageResult> results = await pipeline.processBook(
        bookId: 'book',
        pageCount: 3,
        loadPage: (int page) async => pageImage(page),
        onProgress: (int done, int total, int pageIndex) =>
            progress.add(<int>[done, total]),
      );

      expect(results, hasLength(3));
      expect(progress, <List<int>>[
        <int>[1, 3],
        <int>[2, 3],
        <int>[3, 3],
      ]);
      final OcrPageResult page0 = results[0];
      expect(page0.pageIndex, 0);
      expect(page0.blocks, hasLength(2));
      // RTL：右侧块（left=400）先读。
      expect(page0.blocks[0].lines.single, 'p0@400');
      expect(page0.blocks[1].lines.single, 'p0@20');
      // 竖排启发式：40x120 竖排、180x40 横排。
      expect(page0.blocks[0].vertical, isTrue);
      expect(page0.blocks[1].vertical, isFalse);
      expect(page0.blocks[0].insideBubble, isTrue);
      expect(page0.blocks[1].insideBubble, isFalse);
      // 每页各写一次缓存。
      expect(cache.writes, <int>[0, 1, 2]);
    });

    test('断点续跑：中断后重跑只补未完成页', () async {
      final FakeDetector detector = FakeDetector();
      final FakeRecognizer recognizer = FakeRecognizer();
      final MemoryCache cache = MemoryCache();
      final MangaOcrPipeline pipeline = MangaOcrPipeline(
        detector: detector,
        recognizer: recognizer,
        cache: cache,
      );

      // 第一轮：完成 2 页后取消。
      final OcrCancelToken token = OcrCancelToken();
      await expectLater(
        pipeline.processBook(
          bookId: 'book',
          pageCount: 5,
          loadPage: (int page) async => pageImage(page),
          cancelToken: token,
          onProgress: (int done, int total, int pageIndex) {
            if (done == 2) {
              token.cancel();
            }
          },
        ),
        throwsA(isA<OcrCancelledException>()),
      );
      expect(cache.store.keys, hasLength(2));
      expect(detector.callsByPage, <int, int>{0: 1, 1: 1});

      // 第二轮：页 0/1 命中缓存，检测器只跑 2..4。
      final List<List<int>> progress = <List<int>>[];
      final List<OcrPageResult> results = await pipeline.processBook(
        bookId: 'book',
        pageCount: 5,
        loadPage: (int page) async {
          expect(page, greaterThanOrEqualTo(2), reason: '缓存命中页不应再加载图像');
          return pageImage(page);
        },
        onProgress: (int done, int total, int pageIndex) =>
            progress.add(<int>[done, total]),
      );
      expect(results, hasLength(5));
      expect(results.map((OcrPageResult r) => r.pageIndex).toList(), <int>[
        0,
        1,
        2,
        3,
        4,
      ]);
      // 每页检测总次数仍为 1：缓存页没有重复检测。
      expect(detector.callsByPage, <int, int>{0: 1, 1: 1, 2: 1, 3: 1, 4: 1});
      expect(progress.last, <int>[5, 5]);
    });

    test('startPage：从当前页起向后、再绕回开头；结果仍按页序', () async {
      final FakeDetector detector = FakeDetector();
      final MemoryCache cache = MemoryCache();
      final MangaOcrPipeline pipeline = MangaOcrPipeline(
        detector: detector,
        recognizer: FakeRecognizer(),
        cache: cache,
      );
      final List<int> loaded = <int>[];
      final List<List<int>> progress = <List<int>>[];
      final List<OcrPageResult> results = await pipeline.processBook(
        bookId: 'book',
        pageCount: 5,
        startPage: 3,
        loadPage: (int page) async {
          loaded.add(page);
          return pageImage(page);
        },
        onProgress: (int done, int total, int pageIndex) =>
            progress.add(<int>[done, total, pageIndex]),
      );

      // 读者停在第 3 页：它最先识别，之后 4，再绕回 0..2。
      expect(loaded, <int>[3, 4, 0, 1, 2]);
      expect(cache.writes, <int>[3, 4, 0, 1, 2]);
      // 进度事件带的是真实页号，不是「第 N 个完成」。
      expect(progress, <List<int>>[
        <int>[1, 5, 3],
        <int>[2, 5, 4],
        <int>[3, 5, 0],
        <int>[4, 5, 1],
        <int>[5, 5, 2],
      ]);
      // 返回值与起点无关：按页序，每页结果属于自己的页。
      expect(
        results.map((OcrPageResult r) => r.pageIndex).toList(),
        <int>[0, 1, 2, 3, 4],
      );
      for (int page = 0; page < 5; page++) {
        expect(results[page].blocks.first.lines.single, 'p$page@400');
      }
    });

    test('startPage：已缓存页跳过推理，但仍按旋转顺序报进度', () async {
      final FakeDetector detector = FakeDetector();
      final MemoryCache cache = MemoryCache();
      final MangaOcrPipeline pipeline = MangaOcrPipeline(
        detector: detector,
        recognizer: FakeRecognizer(),
        cache: cache,
      );
      // 先只把第 0、3 页跑进缓存（模拟边看边识别留下的页）。
      for (final int page in <int>[0, 3]) {
        await cache.write(
          'book',
          await pipeline.processPage(pageIndex: page, image: pageImage(page)),
        );
      }
      detector.callsByPage.clear();

      final List<int> progressPages = <int>[];
      await pipeline.processBook(
        bookId: 'book',
        pageCount: 4,
        startPage: 2,
        loadPage: (int page) async => pageImage(page),
        onProgress: (int done, int total, int pageIndex) =>
            progressPages.add(pageIndex),
      );
      expect(progressPages, <int>[2, 3, 0, 1]);
      expect(detector.callsByPage.keys, <int>[2, 1]);
    });

    test('mangaOcrPageOrder：越界起点夹到合法范围', () {
      expect(mangaOcrPageOrder(0, 3), isEmpty);
      expect(mangaOcrPageOrder(3, 0), <int>[0, 1, 2]);
      expect(mangaOcrPageOrder(3, 1), <int>[1, 2, 0]);
      expect(mangaOcrPageOrder(3, 99), <int>[2, 0, 1]);
      expect(mangaOcrPageOrder(3, -4), <int>[0, 1, 2]);
    });

    test('识别为空串的块被丢弃', () async {
      final FakeDetector detector = FakeDetector();
      final MemoryCache cache = MemoryCache();
      final _EmptyRightRecognizer recognizer = _EmptyRightRecognizer();
      final MangaOcrPipeline pipeline = MangaOcrPipeline(
        detector: detector,
        recognizer: recognizer,
        cache: cache,
      );
      final List<OcrPageResult> results = await pipeline.processBook(
        bookId: 'book',
        pageCount: 1,
        loadPage: (int page) async => pageImage(page),
      );
      expect(results.single.blocks, hasLength(1));
      expect(results.single.blocks.single.lines.single, 'left');
    });

    test('缓存序列化 roundtrip（供文件缓存后端使用）', () {
      const OcrPageResult result = OcrPageResult(
        pageIndex: 3,
        imageWidth: 500,
        imageHeight: 1003,
        blocks: <OcrBlock>[
          OcrBlock(
            box: OcrRect(left: 1, top: 2, right: 3, bottom: 4),
            vertical: true,
            lines: <String>['あ', 'い'],
            score: 0.5,
            insideBubble: true,
          ),
        ],
      );
      final OcrPageResult restored = OcrPageResult.fromJson(result.toJson());
      expect(restored.pageIndex, 3);
      expect(restored.imageWidth, 500);
      expect(restored.blocks, hasLength(1));
      final OcrBlock block = restored.blocks.single;
      expect(block.vertical, isTrue);
      expect(block.lines, <String>['あ', 'い']);
      expect(block.score, 0.5);
      expect(block.insideBubble, isTrue);
      expect(block.box.right, 3);
    });

    test('取消令牌在块间也生效', () async {
      final FakeDetector detector = FakeDetector();
      final MemoryCache cache = MemoryCache();
      final OcrCancelToken token = OcrCancelToken();
      final _CancellingRecognizer recognizer = _CancellingRecognizer(token);
      final MangaOcrPipeline pipeline = MangaOcrPipeline(
        detector: detector,
        recognizer: recognizer,
        cache: cache,
      );
      await expectLater(
        pipeline.processBook(
          bookId: 'book',
          pageCount: 1,
          loadPage: (int page) async => pageImage(page),
          cancelToken: token,
        ),
        throwsA(isA<OcrCancelledException>()),
      );
      // 页没有完成 → 不落缓存。
      expect(cache.store, isEmpty);
      expect(recognizer.calls, 1);
    });
  });

  group('BUG-2813 行几何', () {
    const OcrRect tall = OcrRect(left: 400, top: 10, right: 480, bottom: 130);
    final _FixedDetector oneTallBlock = _FixedDetector(<DetectedTextRegion>[
      const DetectedTextRegion(
        rect: tall,
        score: 0.9,
        classId: 1,
        insideBubble: true,
      ),
    ]);

    test('识别器给的行与行框原样落进 OcrBlock，并随缓存 JSON 往返', () async {
      final _LayoutRecognizer recognizer = _LayoutRecognizer();
      final OcrPageResult result = await MangaOcrPipeline(
        detector: oneTallBlock,
        recognizer: recognizer,
      ).processPage(pageIndex: 0, image: pageImage(0));
      final OcrBlock block = result.blocks.single;
      expect(block.lines, <String>['あいう', 'えお']);
      expect(block.text, 'あいうえお');
      expect(block.lineBoxes!.map((OcrRect r) => r.left), <double>[440, 400]);
      final OcrBlock roundTrip = OcrPageResult.fromJson(
        result.toJson(),
      ).blocks.single;
      expect(roundTrip.lines, block.lines);
      expect(roundTrip.lineBoxes!.map((OcrRect r) => r.right), <double>[
        480,
        440,
      ]);
    });

    test('行拼不回原文时退回整块单行，不让覆盖层的字与句子错位', () async {
      final OcrPageResult result = await MangaOcrPipeline(
        detector: oneTallBlock,
        recognizer: _LayoutRecognizer()..corrupt = true,
      ).processPage(pageIndex: 0, image: pageImage(0));
      expect(result.blocks.single.lines, <String>['あいうえお']);
      expect(result.blocks.single.lineBoxes, isNull);
    });

    test('行框个数与行对不上的缓存 JSON 当作没有行几何', () {
      final OcrBlock block = OcrBlock.fromJson(<String, dynamic>{
        'box': tall.toJson(),
        'vertical': true,
        'lines': <String>['あい', 'う'],
        'lineBoxes': <Map<String, dynamic>>[tall.toJson()],
      });
      expect(block.lines, <String>['あい', 'う']);
      expect(block.lineBoxes, isNull);
    });

    test('旧版缓存只补行几何：不检测、不重新识别，文字原样，写成当前版本缓存', () async {
      final MemoryCache current = MemoryCache();
      final MemoryCache legacy = MemoryCache();
      final OcrPageResult old = OcrPageResult(
        pageIndex: 0,
        imageWidth: 500,
        imageHeight: 1000,
        blocks: const <OcrBlock>[
          OcrBlock(
            box: tall,
            vertical: true,
            lines: <String>['あいうえお'],
            score: 0.9,
            insideBubble: true,
          ),
        ],
      );
      await legacy.write('b', old);
      final _FixedDetector detector =
          _FixedDetector(const <DetectedTextRegion>[]);
      final _LayoutRecognizer recognizer = _LayoutRecognizer();
      final List<OcrPageResult> results = await MangaOcrPipeline(
        detector: detector,
        recognizer: recognizer,
        cache: current,
      ).processBook(
        bookId: 'b',
        pageCount: 1,
        loadPage: (int page) async => pageImage(page),
        legacyCaches: <OcrPageCache>[legacy],
      );
      expect(detector.calls, 0);
      expect(recognizer.recognizeCalls, 0);
      expect(recognizer.layoutCalls, 1);
      final OcrBlock block = results.single.blocks.single;
      expect(block.lines, <String>['あいう', 'えお']);
      expect(block.score, 0.9);
      expect(block.insideBubble, isTrue);
      expect(current.writes, <int>[0]);
      expect(current.store['b/0']!.blocks.single.lineBoxes, isNotNull);
    });

    test('旧版缓存的页尺寸与当前页图不符：不补几何，整页重新识别', () async {
      final MemoryCache legacy = MemoryCache();
      await legacy.write(
        'b',
        const OcrPageResult(
          pageIndex: 0,
          imageWidth: 499,
          imageHeight: 1000,
          blocks: <OcrBlock>[],
        ),
      );
      final _LayoutRecognizer recognizer = _LayoutRecognizer();
      await MangaOcrPipeline(
        detector: oneTallBlock,
        recognizer: recognizer,
      ).processBook(
        bookId: 'b',
        pageCount: 1,
        loadPage: (int page) async => pageImage(page),
        legacyCaches: <OcrPageCache>[legacy],
      );
      expect(recognizer.layoutCalls, 0);
      expect(recognizer.recognizeCalls, 1);
    });

    test('多行块也参与识别后包含去重（按整块文本判断）', () async {
      final OcrPageResult result = await MangaOcrPipeline(
        detector: _FixedDetector(const <DetectedTextRegion>[
          DetectedTextRegion(
            rect: OcrRect(left: 0, top: 0, right: 300, bottom: 100),
            score: 0.9,
            classId: 2,
            insideBubble: false,
          ),
          DetectedTextRegion(
            rect: OcrRect(left: 10, top: 50, right: 200, bottom: 90),
            score: 0.5,
            classId: 2,
            insideBubble: false,
          ),
        ]),
        recognizer: _TwoLineParentRecognizer(),
      ).processPage(pageIndex: 0, image: pageImage(0));
      expect(result.blocks.map((OcrBlock b) => b.text), <String>['題名本文']);
    });
  });

  group('isVerticalBlock', () {
    test('长宽比阈值', () {
      expect(
        isVerticalBlock(const OcrRect(left: 0, top: 0, right: 20, bottom: 100)),
        isTrue,
      );
      expect(
        isVerticalBlock(const OcrRect(left: 0, top: 0, right: 100, bottom: 20)),
        isFalse,
      );
      // 接近方形 → 横排。
      expect(
        isVerticalBlock(const OcrRect(left: 0, top: 0, right: 50, bottom: 60)),
        isFalse,
      );
      // 轴对齐外接框会把倾斜竖排拉宽；真实封面约 1.4:1，仍应判为竖排。
      expect(
        isVerticalBlock(
          const OcrRect(left: 0, top: 0, right: 100, bottom: 140),
        ),
        isTrue,
      );
    });
  });
}

/// 右侧块（left=400）识别为空串。
class _EmptyRightRecognizer implements OcrRecognizer {
  @override
  Future<String> recognize(img.Image page, OcrRect box) async =>
      box.left >= 400 ? '' : 'left';
}

/// 第一个块识别完成后触发取消。
class _CancellingRecognizer implements OcrRecognizer {
  _CancellingRecognizer(this.token);

  final OcrCancelToken token;
  int calls = 0;

  @override
  Future<String> recognize(img.Image page, OcrRect box) async {
    calls++;
    token.cancel();
    return 'x';
  }
}

/// 竖排块识别出「あいうえお」并按两列（右列 3 字、左列 2 字）给回行几何。
class _LayoutRecognizer
    implements OrientedOcrRecognizer, LineLayoutOcrRecognizer {
  int recognizeCalls = 0;
  int layoutCalls = 0;

  /// 让行拼接与文本不一致（识别器 bug 的形状）。
  bool corrupt = false;

  OcrRecognition _laidOut(OcrRect box, String text) => OcrRecognition(
        text: text,
        vertical: true,
        lines: corrupt ? <String>['あいう', 'えX'] : <String>['あいう', 'えお'],
        lineBoxes: <OcrRect>[
          OcrRect(
              left: box.left + 40,
              top: box.top,
              right: box.right,
              bottom: box.bottom),
          OcrRect(
              left: box.left,
              top: box.top,
              right: box.left + 40,
              bottom: box.bottom),
        ],
      );

  @override
  Future<String> recognize(img.Image page, OcrRect box) async {
    recognizeCalls++;
    return 'あいうえお';
  }

  @override
  Future<List<OcrRecognition>> recognizeOriented(
    img.Image page,
    List<OcrRect> boxes,
  ) async {
    recognizeCalls += boxes.length;
    return <OcrRecognition>[
      for (final OcrRect box in boxes) _laidOut(box, 'あいうえお'),
    ];
  }

  @override
  Future<OcrRecognition> layoutRecognized(
    img.Image page,
    OcrRect box,
    String text, {
    required bool vertical,
  }) async {
    layoutCalls++;
    return _laidOut(box, text);
  }
}

/// 父块（宽）按两行给回「題名」「本文」，子块识别出「本文」。
class _TwoLineParentRecognizer implements OrientedOcrRecognizer {
  @override
  Future<String> recognize(img.Image page, OcrRect box) async =>
      throw StateError('pipeline uses recognizeOriented');

  @override
  Future<List<OcrRecognition>> recognizeOriented(
    img.Image page,
    List<OcrRect> boxes,
  ) async =>
      <OcrRecognition>[
        for (final OcrRect box in boxes)
          box.width >= 300
              ? OcrRecognition(
                  text: '題名本文',
                  vertical: false,
                  lines: const <String>['題名', '本文'],
                  lineBoxes: <OcrRect>[
                    OcrRect(
                        left: box.left,
                        top: box.top,
                        right: box.right,
                        bottom: 40),
                    OcrRect(
                        left: box.left,
                        top: 50,
                        right: box.right,
                        bottom: box.bottom),
                  ],
                )
              : const OcrRecognition(text: '本文', vertical: false),
      ];
}

/// 一个正式块（右上竖排）+ 两个弱候选（下方的标题两行）。
class _SweepDetector implements OcrDetector {
  _SweepDetector({List<DetectedTextRegion>? weak}) : weak = weak ?? _title;

  static const OcrRect top = OcrRect(
    left: 400,
    top: 10,
    right: 440,
    bottom: 130,
  );

  static const List<DetectedTextRegion> _title = <DetectedTextRegion>[
    DetectedTextRegion(
      rect: OcrRect(left: 30, top: 300, right: 250, bottom: 330),
      score: 0.125,
      classId: 2,
      insideBubble: false,
    ),
    DetectedTextRegion(
      rect: OcrRect(left: 80, top: 335, right: 200, bottom: 360),
      score: 0.021,
      classId: 2,
      insideBubble: false,
    ),
  ];

  final List<DetectedTextRegion> weak;

  @override
  Future<PageDetections> detect(img.Image page) async => PageDetections(
        textRegions: const <DetectedTextRegion>[
          DetectedTextRegion(
            rect: top,
            score: 0.9,
            classId: 1,
            insideBubble: true,
          ),
        ],
        bubbles: const <OcrRect>[],
        weakTextRegions: weak,
      );
}

class _RecordingSweeper implements OcrPageTextSweeper {
  _RecordingSweeper(this.result);

  final List<OcrBlock> result;
  int calls = 0;
  List<DetectedTextRegion>? candidates;
  List<OcrRect>? covered;

  @override
  Future<List<OcrBlock>> sweep(
    img.Image page, {
    required List<DetectedTextRegion> candidates,
    required List<OcrRect> covered,
  }) async {
    calls++;
    this.candidates = candidates;
    this.covered = covered;
    return result;
  }
}
