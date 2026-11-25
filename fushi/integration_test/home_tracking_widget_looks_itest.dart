// 首页「追踪」小组件（HomeWidgetKind.tracking）：最近同步 / 发送失败 / 发送中三种状态，
// 在 MD3 分区卡、海报色块与 Apple 玻璃三种外观下按 1×1 … 6×2 抓真像素。
// 数据是隔离库里现写的：两个假站点（不发网络请求）、五部带封面的视频、
// Activity 日志与待发队列。
//
// 跑法（在 fushi/ 下，离屏、不抢焦点）：
//   dart tool/heavy.dart -- powershell -ExecutionPolicy Bypass -File \
//     tool/run_windows_itest.ps1 integration_test/home_tracking_widget_looks_itest.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiGlassMaterial;
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/generate_test_image.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _tag = '[tracking-looks]';

void _log(String message) => debugPrint('$_tag $message');

final class _Session implements TrackingProviderSession {
  @override
  void close() {}
}

/// A signed-in site that never finishes a push (nothing leaves the machine;
/// queued rows stay queued).
final class _FakeSite implements TrackingProvider {
  _FakeSite(this.id, this.displayName);

  @override
  final String id;

  @override
  final String displayName;

  @override
  String get siteHost => '';

  @override
  TrackingProviderCapabilities get capabilities =>
      const TrackingProviderCapabilities(
        kinds: <TrackingKind>{TrackingKind.anime},
        progressModes: <TrackingProgressMode>{TrackingProgressMode.episode},
      );

  @override
  bool get isConfigured => true;

  @override
  Future<TrackingProviderSession> openSession() async => _Session();

  @override
  Future<void> push(
    TrackingProviderSession session,
    PendingTrackingUpdate update,
  ) => Completer<void>().future;

  @override
  TrackingFailureKind classify(Object error) => TrackingFailureKind.transient;
}

typedef _Show = ({String key, String title, int seed});

const List<_Show> _shows = <_Show>[
  (key: 'trk-frieren', title: '葬送のフリーレン', seed: 3),
  (key: 'trk-meshi', title: 'ダンジョン飯', seed: 11),
  (key: 'trk-kusuriya', title: '薬屋のひとりごと', seed: 23),
  (key: 'trk-bocchi', title: 'ぼっち・ざ・ろっく！', seed: 37),
  (key: 'trk-oshi', title: '【推しの子】', seed: 51),
];

final List<_FakeSite> _sites = <_FakeSite>[
  _FakeSite('anilist', 'AniList'),
  _FakeSite('mal', 'MyAnimeList'),
];

/// mapping id per (site id, show key).
final Map<String, int> _mappings = <String, int>{};

Future<void> _seed(AppModel appModel) async {
  final FushiDatabase db = appModel.database;
  final MediaTrackingRepository repo = MediaTrackingRepository(db);
  final Directory covers = Directory(
    '${observeScreenshotDir().parent.path}/tracking-covers',
  )..createSync(recursive: true);
  for (final _Show show in _shows) {
    final File cover = File('${covers.path}/${show.key}.png');
    await cover.writeAsBytes(
      const TestImageGenerator().pngBytes(
        width: 240,
        height: 360,
        seed: show.seed,
      ),
    );
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: show.key,
        title: show.title,
        videoPath: 'C:/fixtures/${show.key}.mp4',
        coverPath: Value<String?>(cover.path),
        language: const Value<String>('ja'),
      ),
    );
    for (final _FakeSite site in _sites) {
      _mappings['${site.id}|${show.key}'] = await repo.saveMapping(
        mediaType: TrackingMediaType.video,
        mediaKey: show.key,
        mediaTitle: show.title,
        kind: TrackingKind.anime,
        subjectId: 1000 + show.seed,
        subjectName: show.title,
        progressMode: TrackingProgressMode.episode,
        progressOffset: 0,
        provider: site.id,
      );
    }
  }
  final int now = DateTime.now().millisecondsSinceEpoch;
  int ago(Duration d) => now - d.inMilliseconds;
  Future<void> sent(
    String site,
    _Show show,
    int episode,
    Duration age, {
    bool completed = false,
  }) => db
      .into(db.mediaTrackingActivity)
      .insert(
        MediaTrackingActivityCompanion.insert(
          provider: site,
          mediaType: TrackingMediaType.video.value,
          mediaKey: show.key,
          mediaTitle: show.title,
          kind: TrackingKind.anime.value,
          progressMode: TrackingProgressMode.episode.value,
          progress: episode,
          completed: Value<bool>(completed),
          ok: true,
          createdAt: ago(age),
        ),
      );
  // Oldest first so ids grow with time, like the real log.
  await sent('anilist', _shows[4], 2, const Duration(days: 3));
  await sent('anilist', _shows[4], 3, const Duration(hours: 26));
  await sent('mal', _shows[3], 12, const Duration(hours: 5), completed: true);
  await sent('anilist', _shows[2], 5, const Duration(hours: 2));
  await sent('mal', _shows[2], 5, const Duration(hours: 2));
  await sent('anilist', _shows[1], 8, const Duration(minutes: 40));
  await sent('anilist', _shows[0], 12, const Duration(minutes: 3));
  await sent('mal', _shows[0], 12, const Duration(minutes: 3));
  final prefs = appModel.prefsRepo;
  for (final _FakeSite site in _sites) {
    final TrackingProviderPrefKeys keys = TrackingProviderPrefKeys.forProvider(
      site.id,
    );
    await prefs.setPref(keys.lastSyncAt, ago(const Duration(minutes: 3)));
    await prefs.setPref(keys.lastSyncSucceeded, 1);
    await prefs.setPref(keys.lastSyncFailed, 0);
    await prefs.setPref(keys.lastSyncUnauthorized, 0);
  }
}

/// Replaces the queue with [rows] (site, show, episode, error) and nudges
/// the home page to reload.
Future<void> _queue(
  AppModel appModel,
  List<(String, _Show, int, String?)> rows,
) async {
  final FushiDatabase db = appModel.database;
  await db.delete(db.mediaTrackingOutbox).go();
  final int now = DateTime.now().millisecondsSinceEpoch;
  for (final (String site, _Show show, int episode, String? error) in rows) {
    await db
        .into(db.mediaTrackingOutbox)
        .insert(
          MediaTrackingOutboxCompanion.insert(
            mappingId: _mappings['$site|${show.key}']!,
            progress: episode,
            attemptCount: Value<int>(error == null ? 0 : 2),
            // Far future: the sync never picks these up while we look.
            nextAttemptAt: Value<int>(
              now + const Duration(days: 1).inMilliseconds,
            ),
            lastError: Value<String?>(error),
            updatedAt: now - 30000,
          ),
        );
  }
  _register(appModel);
}

void _register(AppModel appModel) {
  final MediaTrackingService service = appModel.mediaTrackingService;
  service.setExtraProviders(_sites);
}

HomeWidgetLayout _layout(HomeWidgetSize size) {
  final List<HomeWidgetItem> items = <HomeWidgetItem>[
    HomeWidgetItem(HomeWidgetKind.tracking, size),
    const HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(2, 1)),
  ];
  return HomeWidgetLayout(compact: items, wide: items);
}

Future<void> _shot(WidgetTester tester, String name) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
  try {
    final RenderView view = tester.binding.renderViews.first;
    // ignore: invalid_use_of_protected_member
    final OffsetLayer? layer = view.layer as OffsetLayer?;
    if (layer == null) return;
    final ui.Image image = await layer.toImage(view.paintBounds);
    try {
      final ByteData? png = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (png == null) return;
      final String path = '${observeScreenshotDir().path}/$name.png';
      await File(path).writeAsBytes(png.buffer.asUint8List(), flush: true);
      _log('shot $path');
    } finally {
      image.dispose();
    }
  } catch (e) {
    _log('shot $name failed: $e');
  }
}

List<String> _texts(Finder root) {
  final List<String> out = <String>[];
  for (final Element e
      in find
          .descendant(of: root, matching: find.byType(RichText))
          .evaluate()) {
    final String s = (e.widget as RichText).text.toPlainText().trim();
    if (s.isNotEmpty && !out.contains(s)) out.add(s);
  }
  return out;
}

Future<void> _settle(WidgetTester tester, [int frames = 10]) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('首页「追踪」小组件：三种状态 × 各尺寸 × 三种外观', (WidgetTester tester) async {
    final List<String> errors = <String>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details.exceptionAsString());
      _log('FlutterError: ${details.exceptionAsString()}');
    };
    try {
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      await tester.pump(const Duration(seconds: 2));
      final AppModel appModel = await readyAppModel(tester);
      await appModel.setModuleEnabled(ModuleId.tracking, true);
      await _settle(tester, 20);
      await _seed(appModel);
      _register(appModel);
      for (final _FakeSite site in _sites) {
        await appModel.mediaTrackingService.setProviderEnabled(site.id, true);
      }

      final Finder card = find.byKey(
        const ValueKey<String>('home-tracking-card'),
      );
      int feedShots = 0;
      Future<void> capture(
        String state,
        String look,
        HomeWidgetSize size,
      ) async {
        await appModel.setHomeWidgetLayout(_layout(size));
        HomePage.debugSelectTab?.call(HomeTab.home);
        _register(appModel);
        await _settle(tester, 20);
        final String name = '$state-$look-${size.cols}x${size.rows}';
        await _shot(tester, name);
        final List<String> texts = _texts(card);
        if (texts.isNotEmpty) feedShots++;
        _log('$name feed=${card.evaluate().isNotEmpty} texts=$texts');
      }

      const List<HomeWidgetSize> all = <HomeWidgetSize>[
        HomeWidgetSize(1, 1),
        HomeWidgetSize(2, 1),
        HomeWidgetSize(3, 1),
        HomeWidgetSize(4, 1),
        HomeWidgetSize(6, 1),
        HomeWidgetSize(2, 2),
        HomeWidgetSize(4, 2),
        HomeWidgetSize(6, 2),
      ];
      const List<HomeWidgetSize> few = <HomeWidgetSize>[
        HomeWidgetSize(1, 1),
        HomeWidgetSize(2, 1),
        HomeWidgetSize(2, 2),
        HomeWidgetSize(6, 2),
      ];
      for (final (String look, String design, ShellContentLayout layout)
          in <(String, String, ShellContentLayout)>[
            ('md3-card', 'material', ShellContentLayout.grid),
            ('md3-poster', 'material', ShellContentLayout.collage),
            ('apple', 'glass', ShellContentLayout.grid),
          ]) {
        await appModel.themeNotifier.setDesignSystem(design);
        await appModel.setGlassMaterial(FushiGlassMaterial.off);
        await appModel.setShellContentLayout(layout);

        await _queue(appModel, const <(String, _Show, int, String?)>[]);
        for (final HomeWidgetSize size in look == 'md3-card' ? all : few) {
          await capture('synced', look, size);
        }

        await _queue(appModel, <(String, _Show, int, String?)>[
          ('mal', _shows[1], 9, 'HTTP 503: Service Unavailable'),
        ]);
        for (final HomeWidgetSize size in few) {
          await capture('failed', look, size);
        }

        await _queue(appModel, <(String, _Show, int, String?)>[
          ('anilist', _shows[0], 13, null),
          ('mal', _shows[0], 13, null),
          ('anilist', _shows[1], 9, null),
        ]);
        for (final HomeWidgetSize size in few) {
          await capture('sending', look, size);
        }
      }

      await appModel.themeNotifier.setDesignSystem('auto');
      await appModel.setShellContentLayout(ShellContentLayout.grid);
      _log('feed shots: $feedShots');
      _log('errors: ${errors.length}');
      for (final String e in errors.take(10)) {
        _log('error: $e');
      }
      expect(feedShots, greaterThan(0), reason: '追踪卡应至少渲染一次');
      expect(errors, isEmpty);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
