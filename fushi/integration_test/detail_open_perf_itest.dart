import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' as widgets;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/adaptive/page_backdrop_style.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:vm_service/vm_service.dart' as vm;

import 'helpers/library_fixture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 二级页（视频合集详情 / 漫画作品页 / 音乐播放页）打开耗时探针（本地测速用，
/// profile 构建跑）。
///
/// 复现 2026-11-07 录屏：库页点卡片进二级页，骨架之后约 300 ms 一帧不出、漫画页
/// 淡入只出四五帧。与应用同一条 `adaptivePageRoute` 推页，收引擎 [FrameTiming]
///（build / raster 分段、帧间空档）与 timeline 里 UI 线程最长的事件（开着
/// [debugProfileBuildsEnabled]，能看到是哪个 widget 的 build 长），以 `[open-perf]`
/// 前缀打进日志。每页先按用户设置跑，再把路由层背景整个关掉跑一遍做 A/B。
///
/// 跑法（数据根用安装版真实库的只读拷贝；安装版开着时 profile 构建会撞单实例
/// 互斥量直接退出，所以设 FUSHI_TEST_HIDDEN / FUSHI_TEST_ONSCREEN 走测试 runner）：
///   FUSHI_TEST_HIDDEN=1 FUSHI_TEST_ONSCREEN=1
///   FUSHI_WEBVIEW2_USER_DATA_FOLDER=<测试根>/webview2
///   flutter drive --profile -d windows --no-pub
///     --driver=test_driver/integration_test.dart
///     --target=integration_test/detail_open_perf_itest.dart
///     --dart-define=FUSHI_TEST_ROOT=<测试根>
///     --dart-define=FUSHI_PERF_COLLECTION=<合集 id>
///   可选：FUSHI_PERF_ONLY=video-collection|manga-series|music-player 只测一页；
///   FUSHI_PERF_DUMP=<目录> 把第二轮 timeline 落成 JSON；FUSHI_PERF_PROFILE=layout
///   改打 render object 的 layout 事件（默认打用户 widget 的 build 事件）。
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('detail pages open timing', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue);
    final AppModel appModel = await readyAppModel(tester);
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await _wait(3000);

    final FushiDatabase db = appModel.database;
    const int collectionId = int.fromEnvironment(
      'FUSHI_PERF_COLLECTION',
      defaultValue: 3170,
    );
    final MediaCollectionRow? collection = await db.getMediaCollectionById(
      collectionId,
    );
    final List<MediaItem> books = await ReaderFushiSource.instance
        .getBooksFromDb(appModel: appModel);
    final MediaItem? manga = books
        .where(
          (MediaItem i) =>
              i.mediaSourceIdentifier == MangaFushiSource.kUniqueKey &&
              i.uniqueKey.isNotEmpty,
        )
        .firstOrNull;
    final PageBackdropSettings userBackdrop = pageBackdropSettings.value;
    final Map<HomeTab, PageBackdropModuleOverride> userOverrides =
        pageBackdropModuleOverrides.value;
    final Size physical = tester.view.physicalSize;
    debugPrint(
      '[open-perf] collection=${collection?.name} manga=${manga?.title} '
      'size=${physical.width}x${physical.height} '
      'dpr=${tester.view.devicePixelRatio} '
      'backdrop=${userBackdrop.preset.name} motion=${userBackdrop.motion} '
      'blur=${userBackdrop.blur.name} overrides=${userOverrides.length}',
    );

    final NavigatorState nav = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    final VideoBookRepository repo = VideoBookRepository(db);
    final Map<String, widgets.WidgetBuilder> pages =
        <String, widgets.WidgetBuilder>{
          if (collection != null)
            'video-collection': (_) => MediaCollectionDetailPage(
              database: db,
              collection: collection,
              loadEpisodes: () => loadCollectionEpisodeSlots(
                repository: repo,
                collectionId: collection.id,
              ),
              onOpenEpisode: (_) {},
              onChanged: () {},
            ),
          if (manga != null)
            'manga-series': (_) => MangaSeriesPage(
              target: ShelfMangaSeriesTarget(manga.uniqueKey, item: manga),
            ),
          'music-player': (_) => const MusicLyricsPage(),
        };

    const String only = String.fromEnvironment('FUSHI_PERF_ONLY');
    if (only.isNotEmpty) pages.removeWhere((String k, _) => k != only);
    try {
      for (final bool backdropOn in <bool>[true, false]) {
        if (!backdropOn) {
          pageBackdropSettings.value = userBackdrop.copyWith(
            preset: PageBackdropPreset.plain,
          );
          pageBackdropModuleOverrides.value =
              const <HomeTab, PageBackdropModuleOverride>{};
          await _wait(1500);
        }
        final String tag = backdropOn ? 'bd-on' : 'bd-off';
        for (int round = 0; round < 3; round++) {
          for (final MapEntry<String, widgets.WidgetBuilder> page
              in pages.entries) {
            await _measure(
              binding,
              '$tag/r$round/${page.key}',
              nav,
              page.value,
              // 第一轮额外抓 timeline（带 widget build 事件），其余只收帧时间。
              trace: round == 1,
            );
          }
        }
      }
    } finally {
      pageBackdropSettings.value = userBackdrop;
      pageBackdropModuleOverrides.value = userOverrides;
    }
    debugPrint('[open-perf] done');
  });
}

Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

Future<void> _measure(
  IntegrationTestWidgetsFlutterBinding binding,
  String label,
  NavigatorState nav,
  widgets.WidgetBuilder builder, {
  required bool trace,
}) async {
  final List<FrameTiming> timings = <FrameTiming>[];
  void collect(List<FrameTiming> batch) => timings.addAll(batch);
  SchedulerBinding.instance.addTimingsCallback(collect);
  Future<void>? pushed;
  // timeline 只录推页后的前 300 ms（打开的长帧都在这里）：recorder 是定长环形
  // 缓冲，录满 2.2 s 会把开头冲掉。
  Future<void> open() async {
    pushed = nav.push<void>(
      adaptivePageRoute<void>(context: nav.context, builder: builder),
    );
    await _wait(trace ? 300 : 2200);
  }

  vm.Timeline? timeline;
  if (trace) {
    // 只给用户代码里的 widget 打 build 事件：全量打点每帧上千条，同样会冲掉缓冲。
    // FUSHI_PERF_PROFILE=layout：改打 render object 的 layout 事件（看排版耗在哪）。
    const bool profileLayout =
        String.fromEnvironment('FUSHI_PERF_PROFILE') == 'layout';
    debugProfileBuildsEnabledUserWidgets = !profileLayout;
    debugProfileLayoutsEnabled = profileLayout;
    try {
      timeline = await binding.traceTimeline(
        open,
        streams: const <String>['Dart', 'GC'],
      );
    } finally {
      debugProfileBuildsEnabledUserWidgets = false;
      debugProfileLayoutsEnabled = false;
    }
    await _wait(1900);
  } else {
    await open();
  }
  nav.pop();
  await pushed;
  await _wait(1500);
  SchedulerBinding.instance.removeTimingsCallback(collect);

  _printFrames(label, timings);
  if (timeline != null) {
    _printLongEvents(label, timeline);
    const String dump = String.fromEnvironment('FUSHI_PERF_DUMP');
    if (dump.isNotEmpty) {
      final String name = label.replaceAll('/', '_');
      File('$dump/$name.json').writeAsStringSync(jsonEncode(timeline.toJson()));
    }
  }
}

String _f(num v) => v.toStringAsFixed(1);

void _printFrames(String label, List<FrameTiming> timings) {
  if (timings.isEmpty) {
    debugPrint('[open-perf] $label frames=0');
    return;
  }
  final int origin = timings.first.timestampInMicroseconds(
    FramePhase.buildStart,
  );
  final StringBuffer slow = StringBuffer();
  int? prevEnd;
  double maxGap = 0;
  double maxBuild = 0;
  double maxRaster = 0;
  int over = 0;
  for (final FrameTiming t in timings) {
    final int start = t.timestampInMicroseconds(FramePhase.buildStart);
    final double gap = prevEnd == null ? 0 : (start - prevEnd) / 1000;
    prevEnd = t.timestampInMicroseconds(FramePhase.rasterFinish);
    final double build = t.buildDuration.inMicroseconds / 1000;
    final double raster = t.rasterDuration.inMicroseconds / 1000;
    if (gap > maxGap) maxGap = gap;
    if (build > maxBuild) maxBuild = build;
    if (raster > maxRaster) maxRaster = raster;
    if (t.totalSpan.inMicroseconds > 16667) over++;
    if (build > 12 || raster > 12 || gap > 40) {
      slow.write(
        ' @${_f((start - origin) / 1000)}[b${_f(build)} r${_f(raster)} '
        'g${_f(gap)}]',
      );
    }
  }
  debugPrint(
    '[open-perf] $label frames=${timings.length} over16ms=$over '
    'maxBuild=${_f(maxBuild)} maxRaster=${_f(maxRaster)} '
    'maxGap=${_f(maxGap)} slow:$slow',
  );
}

/// UI / raster 线程上最长的同步事件（B/E 配对 + X 完整事件），按时长取前若干条。
void _printLongEvents(String label, vm.Timeline timeline) {
  final List<({String name, String thread, double ms, int depth})> spans =
      <({String name, String thread, double ms, int depth})>[];
  final Map<String, String> threadNames = <String, String>{};
  final Map<String, List<Map<String, dynamic>>> stacks =
      <String, List<Map<String, dynamic>>>{};
  for (final vm.TimelineEvent ev
      in timeline.traceEvents ?? <vm.TimelineEvent>[]) {
    final Map<String, dynamic> e = ev.json ?? <String, dynamic>{};
    final String tid = '${e['tid']}';
    final String ph = '${e['ph']}';
    if (ph == 'M' && e['name'] == 'thread_name') {
      final Object? args = e['args'];
      if (args is Map) threadNames[tid] = '${args['name']}';
      continue;
    }
    if (ph == 'B') {
      (stacks[tid] ??= <Map<String, dynamic>>[]).add(e);
    } else if (ph == 'E') {
      final List<Map<String, dynamic>>? s = stacks[tid];
      if (s == null || s.isEmpty) continue;
      final Map<String, dynamic> b = s.removeLast();
      final double ms = ((e['ts'] as int) - (b['ts'] as int)) / 1000;
      if (ms >= 4) {
        spans.add((name: '${b['name']}', thread: tid, ms: ms, depth: s.length));
      }
    } else if (ph == 'X') {
      final double ms = ((e['dur'] as int?) ?? 0) / 1000;
      if (ms >= 4) {
        spans.add((name: '${e['name']}', thread: tid, ms: ms, depth: -1));
      }
    }
  }
  spans.sort((a, b) => b.ms.compareTo(a.ms));
  for (final ({String name, String thread, double ms, int depth}) s
      in spans.take(70)) {
    debugPrint(
      '[open-perf] $label   ev ${_f(s.ms)}ms d${s.depth} '
      '[${threadNames[s.thread] ?? s.thread}] ${s.name}',
    );
  }
}
