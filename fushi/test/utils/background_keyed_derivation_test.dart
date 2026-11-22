import 'dart:io';

import 'package:flutter/foundation.dart'
    show FlutterError, FlutterErrorDetails, FlutterExceptionHandler;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/cover_ui/video_series_meta.dart';
import 'package:fushi/src/utils/background_keyed_derivation.dart';
import 'package:fushi/src/utils/components/fushi_series_cover_block.dart';
import 'package:fushi_core/fushi_core.dart' show CollectionScrapeMetaRow;
import 'package:fushi_engine/media/video/video_filename_parser.dart'
    show parsedEpisodeNumbersOf;

/// 计算函数在**本 isolate** 里被调用的次数。派生值在后台 isolate 算时，那边改的是
/// 它自己那份全局变量，这里的计数保持 0——借此证明计算没落在调用方（UI）isolate。
int _callsOnThisIsolate = 0;

int _countedLength(String input) {
  _callsOnThisIsolate++;
  return input.length;
}

bool _sameString(String a, String b) => a == b;

int _lengthOrThrow(String input) {
  if (input == 'boom') throw StateError('bad input');
  return input.length;
}

/// BUG-5253 余项：视频库卡片 build 不在 UI 线程上解析刮削资料 / 集号。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => _callsOnThisIsolate = 0);

  test('lookup 只读：未就绪返回 null，计算在后台 isolate，同一输入只算一次', () async {
    int ready = 0;
    final BackgroundKeyedDerivation<int, String, int> store =
        BackgroundKeyedDerivation<int, String, int>(
          compute: _countedLength,
          inputEquals: _sameString,
          onReady: () => ready++,
        );
    addTearDown(store.dispose);

    expect(store.lookup(1, 'abc'), isNull, reason: 'build 时还没算好：不就地计算');
    expect(store.lookup(2, 'hello'), isNull);
    // 同一帧的多个请求合成一批。
    await pumpEventQueue();
    while (ready == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(store.debugBatchCount, 1, reason: '同一帧攒到的键合成一次后台批');
    expect(store.lookup(1, 'abc'), 3);
    expect(store.lookup(2, 'hello'), 5);
    expect(_callsOnThisIsolate, 0, reason: '计算必须在后台 isolate，不在调用方 isolate');

    // 输入不变：直接读，不再派活。
    expect(store.lookup(1, 'abc'), 3);
    await pumpEventQueue();
    expect(store.debugBatchCount, 1);

    // 输入变了：允许先读旧值，后台重算后换新。
    expect(store.lookup(1, 'abcdef', allowStale: true), 3);
    expect(store.lookup(1, 'abcdef'), isNull);
    final int before = ready;
    while (ready == before) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(store.lookup(1, 'abcdef'), 6);
    expect(store.debugBatchCount, 2);
    expect(_callsOnThisIsolate, 0);
  });

  test('prefetch 跳过输入没变的键；dispose 后结果丢弃不回调', () async {
    int ready = 0;
    final BackgroundKeyedDerivation<int, String, int> store =
        BackgroundKeyedDerivation<int, String, int>(
          compute: _countedLength,
          inputEquals: _sameString,
          onReady: () => ready++,
        );
    store.prefetch(<int, String>{1: 'a', 2: 'bb'});
    await pumpEventQueue();
    while (ready == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(store.lookup(2, 'bb'), 2);
    store.prefetch(<int, String>{1: 'a', 2: 'bb'});
    await pumpEventQueue();
    expect(store.debugBatchCount, 1, reason: '输入没变不重算');

    store.prefetch(<int, String>{1: 'changed'});
    // 让排好的整批微任务先跑（派往后台），再在结果回来前 dispose。
    await Future<void>.value();
    expect(store.debugBatchCount, 2);
    store.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(ready, 1, reason: 'dispose 后晚到的结果不得回调');
  });

  test('视频系列色块计划与集号能整批在后台 isolate 算，结果与就地算一致', () async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    final CollectionScrapeMetaRow scrape = CollectionScrapeMetaRow(
      collectionId: 1,
      source: 'anilist',
      subjectId: '1',
      title: 'x',
      airDate: '2014-04-01',
      rating: 8.8,
      episodeCount: 12,
      tagsJson: '[{"name":"日常"},{"name":"喜剧"},{"name":"校园"}]',
      scrapedAt: DateTime(2026, 11, 16),
    );
    final VideoSeriesMetaInput input = (
      work: null,
      mediaImages: null,
      workImages: null,
      scrape: scrape,
    );
    VideoSeriesMetaPlan? plan;
    final BackgroundKeyedDerivation<
      String,
      VideoSeriesMetaInput,
      VideoSeriesMetaPlan
    >
    plans =
        BackgroundKeyedDerivation<
          String,
          VideoSeriesMetaInput,
          VideoSeriesMetaPlan
        >(
          compute: videoSeriesMetaPlan,
          inputEquals: videoSeriesMetaInputSame,
          onReady: () {},
        );
    addTearDown(plans.dispose);
    expect(plans.lookup('c:1', input), isNull);
    while ((plan = plans.lookup('c:1', input)) == null) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(plan!.genres, <String>['日常', '喜剧']);
    expect(plan.year, 2014);
    expect(plan.episodeCount, 12);
    final FushiSeriesMeta resolved = resolveVideoSeriesMeta(
      plan,
      localImage: (String? path) => null,
    );
    final FushiSeriesMeta direct = videoSeriesMeta(
      work: null,
      mediaImages: null,
      workImages: null,
      scrape: scrape,
      localImage: (String? path) => null,
    );
    expect(resolved.overview, direct.overview);
    expect(resolved.chip, direct.chip);

    final List<String> names = <String>[
      '/v/[Grp] Show - 151.mkv',
      '/v/[Grp] Show - 152.mkv',
    ];
    List<int?>? numbers;
    final BackgroundKeyedDerivation<int, List<String>, List<int?>> episodes =
        BackgroundKeyedDerivation<int, List<String>, List<int?>>(
          compute: parsedEpisodeNumbersOf,
          inputEquals: (List<String> a, List<String> b) =>
              a.length == b.length &&
              Iterable<int>.generate(a.length).every((int i) => a[i] == b[i]),
          onReady: () {},
        );
    addTearDown(episodes.dispose);
    while ((numbers = episodes.lookup(1, List<String>.of(names))) == null) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(numbers, parsedEpisodeNumbersOf(names));
    expect(numbers, <int?>[151, 152]);
  });

  test('源码守卫：视频库卡片 build 不再就地调用解析函数', () {
    final String page = File(
      'lib/src/pages/implementations/home_video_page.dart',
    ).readAsStringSync();
    String body(String signature) {
      final int start = page.indexOf(signature);
      expect(start, isNonNegative, reason: '找不到 $signature');
      final int end = page.indexOf('\n  }\n', start);
      return page.substring(start, end);
    }

    final String blockMeta = body('FushiSeriesMeta _videoBlockMeta(');
    expect(blockMeta, isNot(contains('videoSeriesMeta(')));
    expect(blockMeta, contains('_seriesPlans.lookup('));
    final String progress = body(
      '_collectionProgress(CollectionGroup<_VideoSlot> group)',
    );
    expect(progress, isNot(contains('collectionMemberEpisodeNumber(')));
    expect(progress, isNot(contains('parsedEpisodeNumbersOf(')));
    expect(progress, contains('_episodeNumbers.lookup('));
  });

  test('计算抛错：同批其它键照常出结果，失败键报一次错、同一输入不再派活、换输入重算', () async {
    final List<FlutterErrorDetails> reported = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? previous = FlutterError.onError;
    FlutterError.onError = reported.add;
    addTearDown(() => FlutterError.onError = previous);
    int ready = 0;
    final BackgroundKeyedDerivation<int, String, int> store =
        BackgroundKeyedDerivation<int, String, int>(
          compute: _lengthOrThrow,
          inputEquals: _sameString,
          onReady: () => ready++,
        );
    addTearDown(store.dispose);

    expect(store.lookup(1, 'boom'), isNull);
    expect(store.lookup(2, 'ok'), isNull);
    while (ready == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(store.lookup(2, 'ok'), 2, reason: '一个键抛错不连累同批其它键');
    expect(reported, hasLength(1), reason: '失败要报出来，不吞掉');
    expect('${reported.single.exception}', contains('bad input'));

    // 同一份失败输入：不再派活（不会每帧重派一个必抛的批）。
    expect(store.lookup(1, 'boom'), isNull);
    await pumpEventQueue();
    expect(store.debugBatchCount, 1);

    // 输入变了：重新计算，不卡在「在算」里。
    expect(store.lookup(1, 'fixed'), isNull);
    final int before = ready;
    while (ready == before) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(store.debugBatchCount, 2);
    expect(store.lookup(1, 'fixed'), 5);
  });
}
