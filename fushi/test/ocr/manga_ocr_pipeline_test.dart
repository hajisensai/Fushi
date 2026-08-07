import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ocr/manga_ocr_pipeline.dart';
import 'package:fushi/src/ocr/ocr_types.dart';
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
    const OcrRect rightTall =
        OcrRect(left: 400, top: 10, right: 440, bottom: 130);
    const OcrRect leftWide = OcrRect(left: 20, top: 40, right: 200, bottom: 80);
    return const PageDetections(
      textRegions: <DetectedTextRegion>[
        DetectedTextRegion(
            rect: leftWide, score: 0.8, classId: 2, insideBubble: false),
        DetectedTextRegion(
            rect: rightTall, score: 0.9, classId: 1, insideBubble: true),
      ],
      bubbles: <OcrRect>[
        OcrRect(left: 390, top: 0, right: 450, bottom: 140),
      ],
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

void main() {
  group('MangaOcrPipeline', () {
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
        onProgress: (int done, int total) => progress.add(<int>[done, total]),
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
          onProgress: (int done, int total) {
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
        onProgress: (int done, int total) => progress.add(<int>[done, total]),
      );
      expect(results, hasLength(5));
      expect(
        results.map((OcrPageResult r) => r.pageIndex).toList(),
        <int>[0, 1, 2, 3, 4],
      );
      // 每页检测总次数仍为 1：缓存页没有重复检测。
      expect(detector.callsByPage, <int, int>{0: 1, 1: 1, 2: 1, 3: 1, 4: 1});
      expect(progress.last, <int>[5, 5]);
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
