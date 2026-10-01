// 漫画 OCR「边看边识别」：整卷任务跟着读者当前页改道 + 在线直读章逐页识别。
//
// 两条都是手机上「翻到的页要等整卷识别完才能查」的根因：整卷任务的起点只在开跑
// 时定一次，手机上本地模型一页几十秒、读者翻得比识别快；直读章则根本不识别。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_stream_ocr.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ocr_pipeline.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

class _EmptyDetector implements OcrDetector {
  @override
  Future<PageDetections> detect(img.Image page) async => const PageDetections(
    textRegions: <DetectedTextRegion>[],
    bubbles: <OcrRect>[],
  );
}

class _NeverRecognizer implements OcrRecognizer {
  @override
  Future<String> recognize(img.Image page, OcrRect box) async => '';
}

/// 逐页可控的识别器：每页一个 completer，测试决定何时完成。
class _ControlledRecognizer implements MangaStreamPageRecognizer {
  final List<String> started = <String>[];
  final Map<String, Completer<MokuroImage>> pending =
      <String, Completer<MokuroImage>>{};
  int closeCalls = 0;
  int active = 0;
  int maxActive = 0;

  @override
  Future<MokuroImage> recognize(File pageFile) async {
    final String name = p.basename(pageFile.path);
    started.add(name);
    active += 1;
    if (active > maxActive) maxActive = active;
    final Completer<MokuroImage> completer = Completer<MokuroImage>();
    pending[name] = completer;
    try {
      return await completer.future;
    } finally {
      active -= 1;
    }
  }

  void finish(String name) => pending
      .remove(name)!
      .complete(
        MokuroImage(
          url: name,
          size: const MokuroSize(100, 200),
          blocks: <MokuroBlock>[
            MokuroBlock(
              rectangle: MokuroRect.fromLTRB(1, 2, 3, 4),
              isVertical: true,
              fontSize: 10,
              zIndex: 0,
              lines: <String>[name],
            ),
          ],
        ),
      );

  void fail(String name) =>
      pending.remove(name)!.completeError(StateError('boom $name'));

  @override
  Future<void> close() async => closeCalls += 1;
}

Future<void> _settle() async {
  for (int i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('MangaOcrPageScheduler', () {
    test('不改道时与 mangaOcrPageOrder 逐项相同', () {
      for (final int count in <int>[0, 1, 2, 5, 9]) {
        for (final int start in <int>[-3, 0, 1, 4, 8, 20]) {
          final MangaOcrPageScheduler scheduler = MangaOcrPageScheduler(
            count,
            start,
          );
          final List<int> order = <int>[
            for (
              int? page = scheduler.next();
              page != null;
              page = scheduler.next()
            )
              page,
          ];
          expect(
            order,
            mangaOcrPageOrder(count, start),
            reason: '$count/$start',
          );
        }
      }
    });

    test('读者翻页：从那页起向后取，绕回补齐，每页恰好一次', () {
      final MangaOcrPageScheduler scheduler = MangaOcrPageScheduler(8, 0);
      expect(scheduler.next(), 0);
      expect(scheduler.next(), 1);
      scheduler.focus(5);
      expect(
        <int?>[scheduler.next(), scheduler.next(), scheduler.next()],
        <int?>[5, 6, 7],
      );
      // 往回翻到已处理过的页：跳过它，从后面第一个没处理的接着跑。
      scheduler.focus(1);
      expect(
        <int?>[scheduler.next(), scheduler.next(), scheduler.next()],
        <int?>[2, 3, 4],
      );
      expect(scheduler.next(), isNull);
    });

    test('越界的改道请求忽略', () {
      final MangaOcrPageScheduler scheduler = MangaOcrPageScheduler(3, 1);
      scheduler.focus(-1);
      scheduler.focus(3);
      expect(
        <int?>[scheduler.next(), scheduler.next(), scheduler.next()],
        <int?>[1, 2, 0],
      );
    });
  });

  group('MangaOcrPageFocus', () {
    test('take 取走最近一次请求，监听者收到每一次', () {
      final MangaOcrPageFocus focus = MangaOcrPageFocus();
      final List<int> heard = <int>[];
      void listener(int page) => heard.add(page);
      focus.addListener(listener);
      expect(focus.take(), isNull);
      focus
        ..request(2)
        ..request(4)
        ..request(-1);
      expect(focus.take(), 4);
      expect(focus.take(), isNull);
      focus.removeListener(listener);
      focus.request(6);
      expect(heard, <int>[2, 4]);
    });
  });

  test('整卷流水线：处理中途读者翻页，下一页就跑读者那页', () async {
    final List<int> loaded = <int>[];
    final MangaOcrPageFocus focus = MangaOcrPageFocus();
    await MangaOcrPipeline(
      detector: _EmptyDetector(),
      recognizer: _NeverRecognizer(),
    ).processBook(
      bookId: 'follow',
      pageCount: 6,
      loadPage: (int pageIndex) async {
        loaded.add(pageIndex);
        // 第 0 页识别期间读者翻到了第 4 页。
        if (pageIndex == 0) focus.request(4);
        return img.Image(width: 10, height: 10);
      },
      takeFocus: focus.take,
    );
    expect(loaded, <int>[0, 4, 5, 1, 2, 3]);
  });

  group('MangaStreamPageOcr（在线直读章）', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('manga_stream_ocr_');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    Future<File?> pageFile(int index) async {
      final File file = File(p.join(dir.path, 'p$index.jpg'));
      file.writeAsBytesSync(<int>[index]);
      return file;
    }

    test('从读者当前页起串行识别眼前这页与后两页，逐页交出结果', () async {
      final _ControlledRecognizer recognizer = _ControlledRecognizer();
      final List<int> delivered = <int>[];
      final List<bool> busy = <bool>[];
      final MangaStreamPageOcr ocr = MangaStreamPageOcr(
        pageCount: 10,
        pageFile: pageFile,
        recognizer: recognizer,
        onPage: (int index, MokuroImage page) {
          delivered.add(index);
          expect(page.blocks.single.lines.single, 'p$index.jpg');
        },
        onBusyChanged: busy.add,
      );
      ocr.focus(3);
      await _settle();
      expect(recognizer.started, <String>['p3.jpg']);
      recognizer.finish('p3.jpg');
      await _settle();
      expect(delivered, <int>[3], reason: '识别完一页就交出一页，不等别的页');
      recognizer.finish('p4.jpg');
      await _settle();
      recognizer.finish('p5.jpg');
      await _settle();
      expect(delivered, <int>[3, 4, 5]);
      expect(recognizer.started, <String>['p3.jpg', 'p4.jpg', 'p5.jpg']);
      expect(recognizer.maxActive, 1, reason: '一次只跑一页');
      expect(busy.first, isTrue);
      expect(busy.last, isFalse, reason: '窗口识别完浮标收起');
      expect(ocr.isBusy, isFalse);
    });

    test('读者翻走：窗口跟着走，旧窗口没轮到的页不再识别', () async {
      final _ControlledRecognizer recognizer = _ControlledRecognizer();
      final List<int> delivered = <int>[];
      final MangaStreamPageOcr ocr = MangaStreamPageOcr(
        pageCount: 20,
        pageFile: pageFile,
        recognizer: recognizer,
        onPage: (int index, MokuroImage _) => delivered.add(index),
      );
      ocr.focus(0);
      await _settle();
      ocr.focus(10);
      recognizer.finish('p0.jpg');
      await _settle();
      expect(recognizer.started, <String>['p0.jpg', 'p10.jpg']);
      recognizer.finish('p10.jpg');
      await _settle();
      recognizer.finish('p11.jpg');
      await _settle();
      recognizer.finish('p12.jpg');
      await _settle();
      expect(delivered, <int>[0, 10, 11, 12]);
      expect(recognizer.started, isNot(contains('p1.jpg')));
    });

    test('失败的页原地不重试，读者重新翻到它才再给一次机会', () async {
      final _ControlledRecognizer recognizer = _ControlledRecognizer();
      final List<Object> errors = <Object>[];
      final MangaStreamPageOcr ocr = MangaStreamPageOcr(
        pageCount: 3,
        pageFile: pageFile,
        recognizer: recognizer,
        onPage: (int index, MokuroImage _) {},
        onError: (Object error, StackTrace _) => errors.add(error),
        lookahead: 0,
      );
      ocr.focus(1);
      await _settle();
      recognizer.fail('p1.jpg');
      await _settle();
      expect(errors, hasLength(1));
      expect(recognizer.started, <String>['p1.jpg']);
      ocr.focus(1);
      await _settle();
      expect(recognizer.started, <String>['p1.jpg'], reason: '同一页原地不重试');
      ocr.focus(2);
      await _settle();
      recognizer.finish('p2.jpg');
      await _settle();
      ocr.focus(1);
      await _settle();
      expect(recognizer.started, <String>['p1.jpg', 'p2.jpg', 'p1.jpg']);
    });

    test('close：在跑那页的结果丢弃、不再调度，识别器被释放', () async {
      final _ControlledRecognizer recognizer = _ControlledRecognizer();
      final List<int> delivered = <int>[];
      final MangaStreamPageOcr ocr = MangaStreamPageOcr(
        pageCount: 5,
        pageFile: pageFile,
        recognizer: recognizer,
        onPage: (int index, MokuroImage _) => delivered.add(index),
      );
      ocr.focus(0);
      await _settle();
      await ocr.close();
      recognizer.finish('p0.jpg');
      await _settle();
      ocr.focus(2);
      await _settle();
      expect(delivered, isEmpty);
      expect(recognizer.started, <String>['p0.jpg']);
      expect(recognizer.closeCalls, 1);
    });
  });
}
