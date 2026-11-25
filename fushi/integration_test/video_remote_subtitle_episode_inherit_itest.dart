// BUG-5464 远端合集真 app 复测：互联 host 上的合集，第 1 集选的内封字幕轨，第 2 集按
// 「语言 + 轨标题」沿用，不按序号照搬。真 app、真 libmpv、进程内起一台**真
// `FushiSyncServer`**（自签 TLS + 指纹 + token），用真 `InterconnectSyncBackend` 取流；
// host 端用真 ffprobe 枚举内封轨、真 ffmpeg 抽轨（与 interconnect_remote_video_ios_itest
// 同一套进程内 host）。
//
// 素材：ffmpeg 生成两集 30 秒 mkv，各带 3 条内封 subrip 轨，**两集轨顺序不同**：
//   ep1: [0] jpn「Signs & Songs」 [1] eng「English」 [2] jpn「Full」
//   ep2: [0] jpn「Signs & Songs」 [1] jpn「Full」    [2] eng「English」
// 每集每轨文本互不相同、句数不同，cue 一看就知道是哪集哪条轨：按描述沿用 → EP2 Full；
// 按序号照搬（embedded:2）→ EP2 English；不沿用 → 没有字幕（host 没有默认字幕、轨也
// 不带默认标记、测试数据根里没有字幕语言偏好）。
//
// 流程：
//   1. `VideoFushiPage.remote` 以两集为合集成员开第 1 集（与库页点远端合集同一构造）；
//   2. 走页面登记的 [VideoPlayerRemoteControl.selectSubtitle] 选 jpn「Full」（与字幕
//      面板行的 onTap 同一个 `_selectSubtitleSource`），核对 cue 是 EP1 Full、本机记下
//      `embedded:2` 与它的轨描述；播 6 秒让远端断点（`video_remote_position_at_`）落库；
//   3. 走播放器 EOF 回调同一条路径（`debugHandlePlaybackEnded` → 连播倒计时 →
//      `_switchEpisode` 远端分支 → `_loadRemoteEpisode`）换到第 2 集，核对起播就是
//      EP2 Full，且沿用没有写成第 2 集自己的选择；
//   4. 退出，再以第 2 集为起播成员冷开合集，核对仍是 EP2 Full。
//
// 跑法（在 fushi/ 下）：
//   dart tool/heavy.dart --max-minutes=30 -- powershell -ExecutionPolicy Bypass
//     -File tool/run_windows_itest.ps1 integration_test/video_remote_subtitle_episode_inherit_itest.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_playback_remote.dart'
    show
        VideoPlayerRemoteControl,
        VideoRemoteSubtitleState,
        VideoRemoteSubtitleTrack,
        videoPlaybackRemotes;
import 'package:fushi/src/media/video/video_subtitle_overlay.dart'
    show VideoSubtitleOverlay;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart'
    show VideoFushiPage, VideoFushiTestHooks;
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart' show Video;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _tag = '[remote-sub-inherit]';
const String _token = 'remote-sub-inherit-itest-token';

/// 一条内封轨：语言标签、轨标题、文本前缀（集号 + 种类）、句数。
class _TrackSpec {
  const _TrackSpec(this.language, this.title, this.kind, this.count);

  final String language;
  final String title;
  final String kind;
  final int count;

  String textAt(String episode, int i) => '$episode $kind ${i + 1}';
}

const _TrackSpec _signs = _TrackSpec('jpn', 'Signs & Songs', 'Signs', 6);
const _TrackSpec _english = _TrackSpec('eng', 'English', 'English', 8);
const _TrackSpec _full = _TrackSpec('jpn', 'Full', 'Full', 10);

/// 两集的轨顺序（故意不同）。
const Map<String, List<_TrackSpec>> _kEpisodes = <String, List<_TrackSpec>>{
  'EP1': <_TrackSpec>[_signs, _english, _full],
  'EP2': <_TrackSpec>[_signs, _full, _english],
};

const Map<String, String> _kVideoIds = <String, String>{
  'EP1': 'video/remote-sub-inherit-ep1',
  'EP2': 'video/remote-sub-inherit-ep2',
};

final String _kTestRoot =
    Platform.environment['FUSHI_TEST_ROOT'] ??
    const String.fromEnvironment('FUSHI_TEST_ROOT');

Future<void> _note(String line) async {
  debugPrint('$_tag $line');
  if (_kTestRoot.isEmpty) return;
  await File(
    '$_kTestRoot${Platform.pathSeparator}remote-sub-inherit-report.txt',
  ).writeAsString('$line\n', mode: FileMode.append, flush: true);
}

String _srtTime(int ms) {
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return '${p(ms ~/ 3600000)}:${p(ms ~/ 60000 % 60)}:${p(ms ~/ 1000 % 60)},'
      '${p(ms % 1000, 3)}';
}

String _srtFor(String episode, _TrackSpec spec) {
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < spec.count; i++) {
    final int start = 1000 + i * 2500;
    b
      ..writeln(i + 1)
      ..writeln('${_srtTime(start)} --> ${_srtTime(start + 2000)}')
      ..writeln(spec.textAt(episode, i))
      ..writeln();
  }
  return b.toString();
}

/// 生成一集 30 秒、带 3 条内封 subrip 轨（含语言与标题元数据）的 mkv。
Future<File> _makeEpisode(Directory dir, String episode) async {
  final String sep = Platform.pathSeparator;
  final List<_TrackSpec> tracks = _kEpisodes[episode]!;
  final List<String> srtPaths = <String>[];
  for (final _TrackSpec spec in tracks) {
    final File f = File('${dir.path}$sep${episode}_${spec.kind}.srt');
    await f.writeAsString(_srtFor(episode, spec), flush: true);
    srtPaths.add(f.path);
  }
  final File video = File('${dir.path}${sep}Series - $episode.mkv').absolute;
  final List<String> args = <String>[
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=640x360:rate=24',
    '-f',
    'lavfi',
    '-i',
    'anullsrc=r=44100:cl=mono',
    for (final String p in srtPaths) ...<String>['-i', p],
    '-map',
    '0:v',
    '-map',
    '1:a',
    for (int i = 0; i < srtPaths.length; i++) ...<String>['-map', '${i + 2}:0'],
    '-t',
    '30',
    '-c:v',
    'mpeg4',
    '-q:v',
    '5',
    '-c:a',
    'aac',
    '-c:s',
    'srt',
    for (int i = 0; i < tracks.length; i++) ...<String>[
      '-metadata:s:s:$i',
      'language=${tracks[i].language}',
      '-metadata:s:s:$i',
      'title=${tracks[i].title}',
    ],
    video.path,
  ];
  final FfmpegRunResult r = await resolveFfmpegBackend().run(
    args,
    const Duration(seconds: 180),
  );
  if (!r.isSuccess) {
    throw StateError('ffmpeg 生成 $episode 失败: ${r.failureSummary}');
  }
  return video;
}

/// cue 列表是哪集哪条轨（句数与逐句文本全等），如 `EP2 Full`；都对不上返回 null。
String? _matchTrack(List<AudioCue> cues) {
  for (final MapEntry<String, List<_TrackSpec>> ep in _kEpisodes.entries) {
    for (final _TrackSpec spec in ep.value) {
      if (cues.length != spec.count) continue;
      bool all = true;
      for (int i = 0; i < cues.length; i++) {
        if (cues[i].text.trim() != spec.textAt(ep.key, i)) {
          all = false;
          break;
        }
      }
      if (all) return '${ep.key} ${spec.kind}';
    }
  }
  return null;
}

String _describeCues(List<AudioCue> cues) => cues.isEmpty
    ? 'cues=0'
    : 'cues=${cues.length} first="${cues.first.text}" last="${cues.last.text}"';

Element? _pageElement() {
  final Iterable<Element> pages = find
      .byType(VideoFushiPage, skipOffstage: false)
      .evaluate();
  return pages.isEmpty ? null : pages.last;
}

VideoFushiTestHooks? _hooks() =>
    (_pageElement() as StatefulElement?)?.state as VideoFushiTestHooks?;

/// 当前在树上那一页的字幕 overlay 上的 cue。
List<AudioCue> _pageCues() {
  final Element? page = _pageElement();
  if (page == null) return const <AudioCue>[];
  final Finder overlay = find.descendant(
    of: find.byElementPredicate((Element e) => identical(e, page)),
    matching: find.byType(VideoSubtitleOverlay),
  );
  if (overlay.evaluate().isEmpty) return const <AudioCue>[];
  return List<AudioCue>.of(
    (overlay.evaluate().first.widget as VideoSubtitleOverlay).controller.cues,
  );
}

String? _pageTrack() => _matchTrack(_pageCues());

Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  required Duration timeout,
}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (done()) return true;
    await tester.pump(const Duration(milliseconds: 250));
  }
  return done();
}

Future<T> _pumpFuture<T>(
  WidgetTester tester,
  Future<T> future, {
  required Duration timeout,
}) async {
  bool finished = false;
  T? value;
  Object? error;
  StackTrace? stack;
  unawaited(
    future.then(
      (T v) {
        value = v;
        finished = true;
      },
      onError: (Object e, StackTrace s) {
        error = e;
        stack = s;
        finished = true;
      },
    ),
  );
  if (!await _pumpUntil(tester, () => finished, timeout: timeout)) {
    throw TimeoutException('等待超时', timeout);
  }
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return value as T;
}

/// 焦点落进画面后按 Escape 退出播放页（逐级关前台浮层，最多 4 次）。
Future<bool> _exitPage(WidgetTester tester) async {
  final FocusDriver driver = FocusDriver(tester);
  await driver.requestFocusInside(find.byType(Video));
  bool gone = false;
  for (int i = 0; i < 4 && !gone; i++) {
    await tester.sendKeyEvent(
      LogicalKeyboardKey.escape,
      physicalKey: PhysicalKeyboardKey.escape,
    );
    gone = await _pumpUntil(
      tester,
      () => find.byType(VideoFushiPage).evaluate().isEmpty,
      timeout: const Duration(seconds: 5),
    );
  }
  return gone;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('互联远端合集换集与冷开另一集：内封字幕按语言 + 标题沿用', (WidgetTester tester) async {
    final void Function(FlutterErrorDetails)? originalOnError =
        FlutterError.onError;

    String? flowError;
    String? ep1Default;
    String? ep1Selected;
    String? ep1Stored;
    bool ep1DescriptorStored = false;
    int ep1PlayedAt = 0;
    String? ep2AfterSwitch;
    String? ep2StoredAfterSwitch;
    String? ep2ColdOpen;
    bool exited = false;
    FushiSyncServer? server;
    SyncRepository? repo;
    List<FushiClientUrl>? oldUrls;
    String? oldToken;
    final String ep1Id = _kVideoIds['EP1']!;
    final String ep2Id = _kVideoIds['EP2']!;

    try {
      if (_kTestRoot.isNotEmpty) {
        final File report = File(
          '$_kTestRoot${Platform.pathSeparator}remote-sub-inherit-report.txt',
        );
        if (report.existsSync()) report.deleteSync();
      }
      await launchFushiTestApp();
      final bool homeShown = await waitForHome(tester);
      await _note('home=$homeShown');
      if (!homeShown) throw StateError('主页 90s 内未出现');
      await tester.pump(const Duration(seconds: 2));
      final AppModel appModel = await readyAppModel(tester);
      await appModel.setVideoAutoPlayNext(true);
      await _note(
        'subtitle prefs="${appModel.videoSubtitlePreferredLanguages}"',
      );
      final NavigatorState navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );

      // 进程内 host：两集各自一个视频 id，文件名下发（与真 host 一致）。
      final Directory hostRoot = _kTestRoot.isEmpty
          ? await Directory.systemTemp.createTemp('fushi_remote_subinherit_')
          : Directory('$_kTestRoot${Platform.pathSeparator}remote-host');
      await hostRoot.create(recursive: true);
      final Map<String, File> files = <String, File>{
        ep1Id: await _makeEpisode(hostRoot, 'EP1'),
        ep2Id: await _makeEpisode(hostRoot, 'EP2'),
      };
      final FushiTlsIdentity identity = await FushiTlsIdentityStore(
        dataDir: hostRoot.path,
      ).loadOrCreate();
      final SecurityContext context = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
        ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));
      server = FushiSyncServer(
        syncDataDir: hostRoot.path,
        port: 0,
        token: _token,
        libraryService: _EpisodeLibraryService(files),
        securityContext: context,
        hostFingerprint: identity.fingerprintSha256,
      );
      await server.start();
      final String baseUrl = 'https://127.0.0.1:${server.port}';
      repo = SyncRepository(appModel.database);
      oldUrls = await repo.getFushiClientUrls();
      oldToken = await repo.getFushiClientToken();
      await repo.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(
          url: baseUrl,
          fingerprintSha256: identity.fingerprintSha256,
          token: _token,
        ),
      ]);
      await repo.setFushiClientToken(_token);
      final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
        (String url, String tok) async => true,
      );
      if (!await backend.restoreAuth(repo)) throw StateError('restoreAuth 失败');
      await backend.authenticate(repo: repo);
      final List<RemoteVideoInfo> members = List<RemoteVideoInfo>.of(
        await backend.listRemoteVideos(),
      )..sort((RemoteVideoInfo a, RemoteVideoInfo b) => a.id.compareTo(b.id));
      await _note(
        'host at $baseUrl members=${members.map((RemoteVideoInfo m) => '${m.id}/${m.fileName}').join(', ')}',
      );

      void openCollection(int start) {
        unawaited(
          navigator.push<void>(
            MaterialPageRoute<void>(
              builder: (_) => VideoFushiPage.remote(
                info: members[start],
                repo: VideoBookRepository(appModel.database),
                client: backend,
                initialEpisodeIndex: start,
                remoteCollectionMembers: members,
              ),
            ),
          ),
        );
      }

      // 1. 开第 1 集，等远端流就绪。
      openCollection(0);
      final bool ready = await _pumpUntil(
        tester,
        () => _hooks()?.debugPositionMs != null,
        timeout: const Duration(seconds: 90),
      );
      await tester.pump(const Duration(seconds: 2));
      ep1Default = _pageTrack();
      await _note(
        'ep1 ready=$ready default=${ep1Default ?? '-'} ${_describeCues(_pageCues())} '
        'source=${_hooks()?.debugCurrentSubtitleSource}',
      );
      if (!ready) throw StateError('第 1 集远端流 90s 内没有就绪');

      // 2. 选 jpn「Full」。
      final VideoPlayerRemoteControl remote =
          videoPlaybackRemotes.current.value! as VideoPlayerRemoteControl;
      final VideoRemoteSubtitleState state = await _pumpFuture(
        tester,
        remote.subtitleState(),
        timeout: const Duration(seconds: 30),
      );
      await _note(
        'ep1 tracks: ${state.tracks.map((VideoRemoteSubtitleTrack t) => '${t.source}/${t.language}/${t.label}${t.primary ? '*' : ''}').join(', ')}',
      );
      final VideoRemoteSubtitleTrack full = state.tracks.firstWhere(
        (VideoRemoteSubtitleTrack t) =>
            t.language == 'jpn' && t.label.contains('Full'),
      );
      await _pumpFuture<void>(
        tester,
        remote.selectSubtitle(full.source, secondary: false),
        timeout: const Duration(seconds: 60),
      );
      await _pumpUntil(
        tester,
        () => _pageTrack() == 'EP1 Full',
        timeout: const Duration(seconds: 30),
      );
      ep1Selected = _pageTrack();
      // 播 6 秒：远端断点每秒落一次，>= 5 秒才算真观看（BUG-996）。
      await _hooks()!.debugPlay();
      await _pumpUntil(
        tester,
        () => (_hooks()?.debugPositionMs ?? 0) > 6500,
        timeout: const Duration(seconds: 30),
      );
      await tester.pump(const Duration(seconds: 1));
      ep1Stored = appModel.prefsRepo.remoteSubtitleSource(ep1Id);
      ep1DescriptorStored =
          appModel.prefsRepo.remoteSubtitleDescriptors[ep1Id]?.describes(
            ep1Stored,
          ) ??
          false;
      ep1PlayedAt = await appModel.database.getPrefTyped<int>(
        videoRemotePositionEpisodeAtPrefKey(ep1Id, 0),
        0,
      );
      await _note(
        'ep1 selected ${full.source} -> track=${ep1Selected ?? '-'} '
        'stored=$ep1Stored descriptor=${appModel.prefsRepo.remoteSubtitleDescriptors[ep1Id]?.toJson()} '
        'playedAt=$ep1PlayedAt pos=${_hooks()?.debugPositionMs}',
      );

      // 3. 播完 → 连播倒计时 → 远端换集到第 2 集。
      _hooks()!.debugHandlePlaybackEnded(positionMs: 29500, durationMs: 30000);
      final bool switched = await _pumpUntil(
        tester,
        () => _pageTrack()?.startsWith('EP2') ?? false,
        timeout: const Duration(seconds: 90),
      );
      await tester.pump(const Duration(seconds: 1));
      ep2AfterSwitch = _pageTrack();
      ep2StoredAfterSwitch = appModel.prefsRepo.remoteSubtitleSource(ep2Id);
      await _note(
        'ep2 after switch=$switched track=${ep2AfterSwitch ?? '-'} '
        'source=${_hooks()?.debugCurrentSubtitleSource} '
        'stored=$ep2StoredAfterSwitch ${_describeCues(_pageCues())}',
      );

      // 4. 退出，以第 2 集为起播成员冷开合集。
      exited = await _exitPage(tester);
      await _note('exited=$exited');
      if (!exited) throw StateError('退出播放页失败');
      openCollection(1);
      final bool reopened = await _pumpUntil(
        tester,
        () => _pageTrack() != null,
        timeout: const Duration(seconds: 90),
      );
      ep2ColdOpen = _pageTrack();
      await _note(
        'ep2 cold open=$reopened track=${ep2ColdOpen ?? '-'} '
        'source=${_hooks()?.debugCurrentSubtitleSource} '
        'stored=${appModel.prefsRepo.remoteSubtitleSource(ep2Id)} '
        '${_describeCues(_pageCues())}',
      );
      await _exitPage(tester);
      await tester.pump(const Duration(seconds: 1));
    } catch (e, s) {
      flowError = '$e\n$s';
      await _note('flow error: $e');
    } finally {
      FlutterError.onError = originalOnError;
      await server?.stop();
      if (repo != null && oldUrls != null) {
        await repo.setFushiClientUrls(oldUrls);
        await repo.setFushiClientToken(oldToken);
      }
    }

    expect(flowError, isNull, reason: flowError);
    expect(ep1Default, isNull, reason: '第 1 集起播没有字幕（host 无默认、无偏好）');
    expect(ep1Selected, 'EP1 Full', reason: '第 1 集选中后应是 Full 轨的 cue');
    expect(ep1Stored, 'embedded:2', reason: '第 1 集的选择记在它自己的键上');
    expect(ep1DescriptorStored, isTrue, reason: '选轨时随选择记下轨描述');
    expect(ep1PlayedAt, greaterThan(0), reason: '第 1 集播过，远端断点时刻已落库');
    expect(
      ep2AfterSwitch,
      'EP2 Full',
      reason:
          '换到第 2 集应按语言 + 标题沿用 Full（EP2 English = 按序号照搬，'
          '没有 cue = 没沿用）',
    );
    expect(ep2StoredAfterSwitch, isNull, reason: '沿用只管本次加载，不写成第 2 集的选择');
    expect(exited, isTrue);
    expect(ep2ColdOpen, 'EP2 Full', reason: '冷开第 2 集同样沿用');
  });
}

/// 进程内 host 库服务：两集，各自一个视频 id；其余能力一律 [noSuchMethod]。
class _EpisodeLibraryService implements FushiLibraryHostService {
  _EpisodeLibraryService(this.files);

  final Map<String, File> files;
  final Map<String, ({int positionMs, int updatedAtMs})> _positions =
      <String, ({int positionMs, int updatedAtMs})>{};

  @override
  Future<List<RemoteVideoInfo>> listVideos() async => <RemoteVideoInfo>[
    for (final MapEntry<String, File> e in files.entries)
      RemoteVideoInfo(
        id: e.key,
        title: e.value.uri.pathSegments.last,
        fileName: e.value.uri.pathSegments.last,
        sizeBytes: e.value.lengthSync(),
      ),
  ];

  @override
  Future<bool> videoExists(String id, {int episodeIndex = 0}) async =>
      files.containsKey(id);

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async =>
      files[id];

  @override
  Future<File?> resolveVideoSubtitle(
    String id, {
    String langCode = 'ja',
    int episodeIndex = 0,
  }) async => null;

  @override
  Future<String?> videoCoverPath(String id) async => null;

  @override
  Future<List<RemoteActivityEvent>> listActivityEvents({
    int limit = 100,
  }) async => const <RemoteActivityEvent>[];

  @override
  Future<({int positionMs, int updatedAtMs})> getVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async => _positions[id] ?? (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {
    _positions[id] = (positionMs: positionMs, updatedAtMs: updatedAtMs);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}
