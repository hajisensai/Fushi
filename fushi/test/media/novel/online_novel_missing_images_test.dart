import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/novel/online/lnreader_missing_images.dart';
import 'package:fushi/src/media/novel/online/online_novel_missing_images.dart';
import 'package:fushi/src/media/novel/online/online_novel_missing_images_notice.dart';
import 'package:material_ui/material_ui.dart';

/// 可控的补取实现：每章缺几张 / 能否自动补取 / 每轮补到几张都由测试定。
class _FakeRetrier implements OnlineNovelMissingImagesRetrier {
  final Map<int, int> missing = <int, int>{};
  final Map<int, bool> autoAvailable = <int, bool>{};

  /// 下一轮补取补到几张（缺省 0）。
  int recoverNext = 0;

  /// 置非 null 时补取挂在这里，测「补取进行中」。
  Completer<void>? gate;
  final List<({int index, bool automatic})> retries =
      <({int index, bool automatic})>[];

  @override
  Future<OnlineNovelMissingImages> missingImages(int index) async =>
      OnlineNovelMissingImages(
        index: index,
        count: missing[index] ?? 0,
        autoRetryAvailable: autoAvailable[index] ?? true,
      );

  @override
  Future<OnlineNovelMissingImagesRetry> retryMissingImages(
    int index, {
    required bool automatic,
  }) async {
    retries.add((index: index, automatic: automatic));
    await gate?.future;
    final int before = missing[index] ?? 0;
    final int recovered = recoverNext.clamp(0, before);
    missing[index] = before - recovered;
    return OnlineNovelMissingImagesRetry(
      index: index,
      recovered: recovered,
      remaining: before - recovered,
    );
  }
}

void main() {
  group('缺图占位标记', () {
    test('失败的 <img> 换成无文字占位；解析出地址 / alt / 次数；补取后换回或记次', () {
      const String url = 'https://img.example.com/a.png?x=1&y="2"';
      final String body = replaceLnReaderImageWithMissingMarker(
        '<p>前<img alt="挿絵" src="images/p-0.png"/>後</p>'
        '<p><img src="images/p-1.png" alt=""/></p>',
        fileName: 'images/p-0.png',
        url: url,
      );
      expect(body, isNot(contains('src="images/p-0.png"')));
      expect(body, contains('src="images/p-1.png"'));
      expect(body, contains('hidden="hidden"></span>'));

      final LnReaderMissingImage image = parseLnReaderMissingImages(
        body,
      ).single;
      expect(image.fileName, 'images/p-0.png');
      expect(image.url, url);
      expect(image.alt, '挿絵');
      expect(image.tries, 1);
      expect(image.autoRetryAvailable, isTrue);

      // 没补到：次数加一，到 1 + 自动轮数后不再自动补取。
      String next = body;
      for (int i = 0; i < kLnReaderMissingImageAutoRetries; i++) {
        next = applyLnReaderMissingImageRetry(
          next,
          recovered: const <String>{},
          failed: const <String>{'images/p-0.png'},
        );
      }
      final LnReaderMissingImage exhausted = parseLnReaderMissingImages(
        next,
      ).single;
      expect(exhausted.tries, 1 + kLnReaderMissingImageAutoRetries);
      expect(exhausted.autoRetryAvailable, isFalse);
      expect(exhausted.url, url);

      // 补到：换回原 alt 的 <img>，占位消失，其余内容不动。
      final String restored = applyLnReaderMissingImageRetry(
        next,
        recovered: const <String>{'images/p-0.png'},
        failed: const <String>{},
      );
      expect(
        restored,
        contains('<p>前<img alt="挿絵" src="images/p-0.png"/>後</p>'),
      );
      expect(restored, contains('src="images/p-1.png"'));
      expect(parseLnReaderMissingImages(restored), isEmpty);
    });
  });

  group('OnlineNovelMissingImagesController', () {
    late _FakeRetrier retrier;
    late List<int> recoveredChapters;
    late List<OnlineNovelMissingImagesRetry> manualResults;
    late OnlineNovelMissingImagesController controller;

    setUp(() {
      retrier = _FakeRetrier();
      recoveredChapters = <int>[];
      manualResults = <OnlineNovelMissingImagesRetry>[];
      controller = OnlineNovelMissingImagesController(
        retrier: retrier,
        onRecovered: recoveredChapters.add,
        onManualRetryFinished: manualResults.add,
      );
    });

    tearDown(() => controller.dispose());

    test('打开缺图章：先静默自动补取一轮，补取中不提示；全补到就刷新本章、不提示', () async {
      retrier.missing[0] = 2;
      retrier.recoverNext = 2;
      retrier.gate = Completer<void>();
      controller.show(0);
      final Future<void> opened = controller.chapterRequested(0);
      await pumpEventQueue();
      expect(retrier.retries, <({int index, bool automatic})>[
        (index: 0, automatic: true),
      ]);
      expect(controller.notice, isNull);
      retrier.gate!.complete();
      await opened;
      expect(recoveredChapters, <int>[0]);
      expect(controller.notice, isNull);
    });

    test('自动补取没补全才提示剩余张数；同一章本次开书只自动补取一次', () async {
      retrier.missing[1] = 3;
      retrier.recoverNext = 1;
      controller.show(1);
      await controller.chapterRequested(1);
      expect(recoveredChapters, <int>[1]);
      expect(controller.notice?.chapter, 1);
      expect(controller.notice?.count, 2);
      await controller.chapterRequested(1);
      expect(retrier.retries.length, 1);
    });

    test('自动次数已用尽：不自动请求，直接提示；手动补取补全后提示消失', () async {
      retrier.missing[0] = 1;
      retrier.autoAvailable[0] = false;
      controller.show(0);
      await controller.chapterRequested(0);
      expect(retrier.retries, isEmpty);
      expect(controller.notice?.count, 1);

      retrier.recoverNext = 1;
      retrier.gate = Completer<void>();
      final Future<void> manual = controller.retry();
      await pumpEventQueue();
      expect(controller.notice?.retrying, isTrue);
      // 取的过程中再点不重复发起。
      await controller.retry();
      expect(retrier.retries.length, 1);
      retrier.gate!.complete();
      await manual;
      expect(retrier.retries.single.automatic, isFalse);
      expect(recoveredChapters, <int>[0]);
      expect(manualResults.single.remaining, 0);
      expect(controller.notice, isNull);
    });

    test('提示只跟当前章；关掉后本次开书这一章不再出，别的章照常', () async {
      retrier.missing[0] = 1;
      retrier.missing[1] = 1;
      retrier.autoAvailable[0] = false;
      retrier.autoAvailable[1] = false;
      await controller.chapterRequested(0);
      await controller.chapterRequested(1);
      expect(controller.notice, isNull);
      controller.show(0);
      expect(controller.notice?.chapter, 0);
      controller.dismiss();
      expect(controller.notice, isNull);
      controller.show(1);
      expect(controller.notice?.chapter, 1);
      controller.show(0);
      expect(controller.notice, isNull);
    });
  });

  testWidgets('提示条：显示张数，点「重新获取」走手动补取，点关闭收起', (WidgetTester tester) async {
    LocaleSettings.setLocale(AppLocale.en);
    final _FakeRetrier retrier = _FakeRetrier()
      ..missing[0] = 2
      ..autoAvailable[0] = false;
    final OnlineNovelMissingImagesController controller =
        OnlineNovelMissingImagesController(
          retrier: retrier,
          onRecovered: (int _) {},
        );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: OnlineNovelMissingImagesNoticeBar(controller: controller),
          ),
        ),
      ),
    );
    expect(find.text(t.novel_online_images_missing(n: 2)), findsNothing);

    controller.show(0);
    await controller.chapterRequested(0);
    await tester.pumpAndSettle();
    expect(find.text(t.novel_online_images_missing(n: 2)), findsOneWidget);

    retrier.recoverNext = 1;
    await tester.tap(
      find.byKey(const ValueKey<String>('missing_images_retry')),
    );
    await tester.pumpAndSettle();
    expect(retrier.retries.single.automatic, isFalse);
    expect(find.text(t.novel_online_images_missing(n: 1)), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('missing_images_dismiss')),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.novel_online_images_missing(n: 1)), findsNothing);
  });
}
