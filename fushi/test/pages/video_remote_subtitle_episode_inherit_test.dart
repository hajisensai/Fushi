// BUG-5464 远端合集：成员自己没选过字幕时，按描述沿用兄弟成员最近一次的选择。
//
// 钉子（经真实开页路径 `_init → _loadRemoteEpisode → _applyLoad`，假的远端 client 记下
// 向 host 要了哪条内封轨；控制器在测试环境建不起来 → 失败态，字幕判定早已走完）：
// - 兄弟成员选了 jpn「Full」（记了描述 + 有播放时刻）：本成员按语言 + 标题要自己的
//   Full（两成员轨顺序不同），压过服务器默认标记，且不写回本成员；
// - 兄弟成员关了字幕：本成员关着起播，不向 host 要任何字幕；
// - 兄弟成员的选择没有描述（旧版本记的）/ 没有播放时刻：不沿用，照常按服务器默认；
// - 本成员自己有选择：自己的优先；
// - 选轨那一刻随选择写描述（源码守卫）。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_subtitle_inherit.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/source_guard.dart';
import '../helpers/test_platform_services.dart';
import 'video_fushi_page_source_corpus.dart';

class _TestAppModel extends AppModel {
  _TestAppModel(PlatformServices platformServices, this._db)
    : super(platformServices);

  final FushiDatabase _db;

  @override
  double get appUiScale => 1.0;

  @override
  FushiDatabase get database => _db;
}

/// 两个成员的内封轨（顺序不同）：ep-a [Signs, English, Full]，ep-b [Signs, Full, English]。
/// 两边的 Signs 都带服务器默认标记：不沿用时起播挑的就是它（`embedded:0`）。
const Map<String, List<RemoteVideoEmbeddedSubtitleTrack>> _tracks =
    <String, List<RemoteVideoEmbeddedSubtitleTrack>>{
      'ep-a': <RemoteVideoEmbeddedSubtitleTrack>[
        RemoteVideoEmbeddedSubtitleTrack(
          streamIndex: 0,
          codec: 'subrip',
          language: 'jpn',
          title: 'Signs & Songs',
          isDefault: true,
        ),
        RemoteVideoEmbeddedSubtitleTrack(
          streamIndex: 1,
          codec: 'subrip',
          language: 'eng',
          title: 'English',
        ),
        RemoteVideoEmbeddedSubtitleTrack(
          streamIndex: 2,
          codec: 'subrip',
          language: 'jpn',
          title: 'Full',
        ),
      ],
      'ep-b': <RemoteVideoEmbeddedSubtitleTrack>[
        RemoteVideoEmbeddedSubtitleTrack(
          streamIndex: 0,
          codec: 'subrip',
          language: 'jpn',
          title: 'Signs & Songs',
          isDefault: true,
        ),
        RemoteVideoEmbeddedSubtitleTrack(
          streamIndex: 1,
          codec: 'subrip',
          language: 'jpn',
          title: 'Full',
        ),
        RemoteVideoEmbeddedSubtitleTrack(
          streamIndex: 2,
          codec: 'subrip',
          language: 'eng',
          title: 'English',
        ),
      ],
    };

/// 取流立即给出各成员的内封轨；按序号抽字幕时写一份 SRT 并记下要的是哪条。
class _RecordingRemoteClient implements RemoteVideoClient {
  final List<String> subtitleRequests = <String>[];

  @override
  String get remoteLibrarySourceId => 'test_sub_inherit_remote';

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async =>
      const <RemoteVideoInfo>[];

  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(
    String id, {
    int episodeIndex = 0,
  }) async => RemoteVideoStreamUrls(
    streamUrl: 'http://127.0.0.1:9/stream/$id',
    embeddedSubtitleTracks:
        _tracks[id] ?? const <RemoteVideoEmbeddedSubtitleTrack>[],
  );

  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async => (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    int? embeddedStreamIndex,
    int episodeIndex = 0,
    void Function(double progress)? onProgress,
  }) async {
    subtitleRequests.add('$id#$embeddedStreamIndex');
    await dest.writeAsString(
      '1\n00:00:01,000 --> 00:00:02,000\n$id $embeddedStreamIndex\n',
      flush: true,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected ${invocation.memberName}');
}

const RemoteVideoInfo _epA = RemoteVideoInfo(id: 'ep-a', title: 'A');
const RemoteVideoInfo _epB = RemoteVideoInfo(id: 'ep-b', title: 'B');

final RemoteSubtitleChoiceDescriptor _epAFull = describeRemoteSubtitleChoice(
  source: 'embedded:2',
  embeddedTracks: _tracks['ep-a']!,
  videoFileName: null,
)!;

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late Directory storeDir;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;

  setUpAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => Directory.systemTemp.path,
    );
  });

  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
  });

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_remote_sub_inherit');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = _TestAppModel(platformServices, db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
    try {
      if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
    } on FileSystemException {
      // 失败态的页面可能还握着句柄；留给系统临时目录回收。
    }
  });

  Widget wrap(Widget page) => ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(platformServices),
      ankiRepositoryProvider.overrideWithValue(ankiRepository),
      appProvider.overrideWith((ref) => appModel),
    ],
    child: TranslationProvider(child: MaterialApp(home: page)),
  );

  /// 落 ep-a 的字幕记忆（选择 / 描述 / 播放时刻）与 ep-b 自己的选择。
  Future<void> seed(
    WidgetTester tester, {
    String? epASource,
    RemoteSubtitleChoiceDescriptor? epADescriptor,
    int epAPlayedAt = 0,
    String? epBSource,
  }) async {
    await tester.runAsync(() async {
      if (epASource != null) {
        await prefs.setRemoteSubtitleSource('ep-a', 0, epASource);
      }
      if (epADescriptor != null) {
        await prefs.setRemoteSubtitleDescriptor('ep-a', 0, epADescriptor);
      }
      if (epAPlayedAt > 0) {
        await prefs.setPref(
          videoRemotePositionEpisodePrefKey('ep-a', 0),
          60000,
        );
        await prefs.setPref(
          videoRemotePositionEpisodeAtPrefKey('ep-a', 0),
          epAPlayedAt,
        );
      }
      if (epBSource != null) {
        await prefs.setRemoteSubtitleSource('ep-b', 0, epBSource);
      }
    });
  }

  /// 以 ep-b 为起播成员打开远端合集，推到字幕判定交给 [_applyLoad]。
  Future<VideoFushiTestHooks> openEpB(
    WidgetTester tester,
    _RecordingRemoteClient client,
  ) async {
    await tester.pumpWidget(
      wrap(
        VideoFushiPage.remote(
          info: _epB,
          repo: VideoBookRepository(db),
          client: client,
          initialEpisodeIndex: 1,
          remoteCollectionMembers: const <RemoteVideoInfo>[_epA, _epB],
        ),
      ),
    );
    final VideoFushiTestHooks hooks =
        tester.state(find.byType(VideoFushiPage)) as VideoFushiTestHooks;
    for (int round = 0; round < 40; round++) {
      if (hooks.debugLastLoadSubtitle != null) break;
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(hooks.debugLastLoadSubtitle, isNotNull, reason: '载入链应走到 _applyLoad');
    return hooks;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('兄弟成员选了 Full：本成员按语言 + 标题要自己的 Full，不写回', (
    WidgetTester tester,
  ) async {
    await seed(
      tester,
      epASource: 'embedded:2',
      epADescriptor: _epAFull,
      epAPlayedAt: 1000,
    );
    final _RecordingRemoteClient client = _RecordingRemoteClient();
    final VideoFushiTestHooks hooks = await openEpB(tester, client);

    expect(client.subtitleRequests, <String>[
      'ep-b#1',
    ], reason: 'ep-b 里 Full 是第 1 条（按序号照搬会是 English，不沿用会是默认的 Signs）');
    expect(hooks.debugLastLoadSubtitle!.cueCount, 1);
    expect(prefs.remoteSubtitleSource('ep-b'), isNull, reason: '沿用不写回本成员');
    expect(prefs.remoteSubtitleDescriptors.containsKey('ep-b'), isFalse);
    expect(prefs.remoteSubtitleSource('ep-a'), 'embedded:2');
    await close(tester);
  });

  testWidgets('兄弟成员关了字幕：本成员关着起播', (WidgetTester tester) async {
    await seed(
      tester,
      epASource: SubtitleSource.offSentinel,
      epAPlayedAt: 1000,
    );
    final _RecordingRemoteClient client = _RecordingRemoteClient();
    final VideoFushiTestHooks hooks = await openEpB(tester, client);

    expect(client.subtitleRequests, isEmpty);
    expect(hooks.debugLastLoadSubtitle!.cueCount, 0);
    expect(prefs.remoteSubtitleSource('ep-b'), isNull);
    await close(tester);
  });

  testWidgets('兄弟成员的选择没有描述（旧版本记的）：不沿用，照常按服务器默认', (WidgetTester tester) async {
    await seed(tester, epASource: 'embedded:2', epAPlayedAt: 1000);
    final _RecordingRemoteClient client = _RecordingRemoteClient();
    await openEpB(tester, client);

    expect(client.subtitleRequests, <String>['ep-b#0']);
    await close(tester);
  });

  testWidgets('兄弟成员没有播放时刻：不沿用', (WidgetTester tester) async {
    await seed(tester, epASource: 'embedded:2', epADescriptor: _epAFull);
    final _RecordingRemoteClient client = _RecordingRemoteClient();
    await openEpB(tester, client);

    expect(client.subtitleRequests, <String>['ep-b#0']);
    await close(tester);
  });

  testWidgets('本成员自己有选择：自己的优先', (WidgetTester tester) async {
    await seed(
      tester,
      epASource: 'embedded:2',
      epADescriptor: _epAFull,
      epAPlayedAt: 1000,
      epBSource: 'embedded:2',
    );
    final _RecordingRemoteClient client = _RecordingRemoteClient();
    await openEpB(tester, client);

    expect(client.subtitleRequests, <String>['ep-b#2']);
    await close(tester);
  });

  group('源码守卫', () {
    late String load;
    late String remember;
    setUpAll(() {
      final String src = maskComments(readVideoFushiSource());
      load = methodBody(src, 'Future<void> _loadRemoteEpisode(');
      remember = methodBody(src, 'void _rememberRemoteSubtitleSource(');
    });

    test('优先级：本成员选择 > 沿用 > 语言偏好 / 服务器默认；只在远端合集里沿用', () {
      final int persistedAt = load.indexOf('appModel.remoteSubtitleSource(');
      final int inheritAt = load.indexOf(
        '_inheritedRemoteSubtitleSource(info)',
      );
      final int pickAt = load.indexOf('pickRemoteStartupSubtitleTrack(');
      expect(persistedAt, greaterThan(-1));
      expect(inheritAt, greaterThan(persistedAt));
      expect(pickAt, greaterThan(inheritAt));
      expect(
        load.contains('persistedSub == null && _isRemoteCollection'),
        isTrue,
      );
      expect(
        RegExp(
          r'persistedSub \?\?\s*inheritedSub \?\?\s*\(startupTrack == null',
        ).hasMatch(load),
        isTrue,
      );
    });

    test('沿用来的轨不写回：libmpv 回落与图形轨都只在重放本成员选择时才记', () {
      expect(load.contains('setRemoteSubtitleSource('), isFalse);
      expect(load.contains('setRemoteSubtitleDescriptor('), isFalse);
      expect(
        RegExp(r'remember: persistedSub != null').allMatches(load).length,
        2,
      );
    });

    test('选轨那一刻随选择写描述（按本集轨表），两者同一个暂存出口', () {
      expect(remember.contains('describeRemoteSubtitleChoice('), isTrue);
      expect(remember.contains('_remoteEmbeddedSubtitleTracks'), isTrue);
      final int saveAt = remember.indexOf('_saveReviewableChoice(');
      expect(saveAt, greaterThan(-1));
      expect(
        remember.indexOf('setRemoteSubtitleDescriptor(', saveAt),
        greaterThan(saveAt),
      );
      expect(
        remember.indexOf('setRemoteSubtitleSource(', saveAt),
        greaterThan(saveAt),
      );
    });
  });
}
