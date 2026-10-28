import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/video_remote_host.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_video_remote.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart'
    show RemoteMineResult;
import 'package:fushi_engine/sync/immersion_mine_payload.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';

/// app 内浏览器的手机视频遥控（[WebBrowserVideoRemote]）：前台标签页的网页正片登记成遥控
/// 播放器——登记 / 切标签 / 关标签 / 换视频的生命周期、命令转发、查词暂停的修订号语义
/// （接真 [VideoRemoteHost]）、制卡按站点分流。页面一侧是假的扩展消息通道。
void main() {
  late FushiDatabase db;
  late VideoRemoteHost host;
  late Map<String, _FakePage> pages;
  late List<ImmersionMinePayload> mined;
  late List<WebBrowserTab> closed;
  late List<Map<String, Object?>> runtimeCalls;
  late WebBrowserVideoRemote remote;
  late WebBrowserTab tabA;
  late WebBrowserTab tabB;
  Map<String, Object?> snapshot = <String, Object?>{};
  int serial = 0;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    host = VideoRemoteHost(
      favorites: () => FavoriteSentenceRepository(db),
      now: () => DateTime(2026, 10, 29),
    );
    tabA = WebBrowserTab(id: 'a', url: Uri.parse('https://example.com/v1'));
    tabB = WebBrowserTab(id: 'b', url: Uri.parse('https://example.com/v2'));
    pages = <String, _FakePage>{
      'a': _FakePage(videoKey: 'example.com/v1'),
      'b': _FakePage(videoKey: 'example.com/v2'),
    };
    mined = <ImmersionMinePayload>[];
    closed = <WebBrowserTab>[];
    runtimeCalls = <Map<String, Object?>>[];
    remote = WebBrowserVideoRemote(
      autoPoll: false,
      ports: WebBrowserVideoRemotePorts(
        request:
            (
              WebBrowserTab tab,
              Map<String, Object?> message,
              Duration timeout,
            ) async => pages[tab.id]?.handle(message),
        runtime: (WebBrowserTab tab, Map<String, Object?> message) async {
          runtimeCalls.add(message);
          if (message['type'] == 'subtitleSearch') {
            return <String, Object?>{
              'ok': true,
              'data': <String, Object?>{
                'ok': true,
                'candidates': <Object?>[
                  <String, Object?>{
                    'handle': 'jimaku:https://example.com/sub.srt',
                    'provider': 'jimaku',
                    'fileName': 'ep1.srt',
                    'language': 'ja',
                    'episode': 1,
                  },
                ],
              },
            };
          }
          return <String, Object?>{
            'ok': true,
            'data': <String, Object?>{
              'ok': true,
              'filename': 'ep1.srt',
              'cues': <Object?>[
                <String, Object?>{'startMs': 0, 'endMs': 900, 'text': '新'},
              ],
            },
          };
        },
        register: host.register,
        unregister: host.unregister,
        mineImmersion: (ImmersionMinePayload payload) async {
          mined.add(payload);
          return const RemoteMineResult(result: 'success');
        },
        miningPads: () => (headPadMs: 100, tailPadMs: 200),
        closeTab: closed.add,
      ),
    );
  });
  tearDown(() async {
    remote.dispose();
    await host.dispose();
    await db.close();
  });

  Future<Map<String, Object?>> connect() async =>
      snapshot = await host.handle('snapshot', <String, dynamic>{}, 'phone');

  Future<Map<String, Object?>> call(
    String operation, [
    Map<String, dynamic> data = const <String, dynamic>{},
  ]) => host.handle(operation, <String, dynamic>{
    'sessionId': snapshot['sessionId'],
    'subtitleVersion': snapshot['subtitleVersion'],
    'requestId': 'request_${++serial}',
    ...data,
  }, 'phone');

  Future<void> activate(WebBrowserTab tab) async {
    remote.setActiveTab(tab);
    await remote.poll();
  }

  Matcher remoteError(int status, String code) => isA<VideoRemoteException>()
      .having((VideoRemoteException e) => e.status, 'status', status)
      .having((VideoRemoteException e) => e.code, 'code', code);

  group('登记生命周期', () {
    test('前台标签页有正片才登记；能力按网页实际可做的声明', () async {
      pages['a']!.durationMs = 0; // 还没有元数据 = 没有可遥控的正片
      await activate(tabA);
      expect(remote.binding, isNull);
      expect((await connect())['available'], isFalse);

      pages['a']!.durationMs = 120000;
      await remote.poll();
      expect(remote.binding, isNotNull);
      final Map<String, Object?> s = await connect();
      expect(s['available'], isTrue);
      expect(s['title'], 'Page a');
      expect(s['identity'], 'web:example.com/v1');
      expect(s['positionMs'], 3000);
      expect(s['durationMs'], 120000);
      expect(s['playing'], isTrue);
      expect(s['volume'], 50);
      expect(s['cueCount'], 2);
      expect(
        s['capabilities'],
        containsAll(<String>[
          videoRemoteCapabilityVolume,
          videoRemoteCapabilitySubtitleTracks,
          videoRemoteCapabilitySubtitleSearch,
          videoRemoteCapabilityCloseVideo,
        ]),
      );
      expect(
        s['capabilities'],
        isNot(
          anyOf(
            contains(videoRemoteCapabilityCaret),
            contains(videoRemoteCapabilityEpisodes),
          ),
        ),
      );
    });

    test('切标签：旧页注销、新页成为新会话', () async {
      await activate(tabA);
      final String first = (await connect())['sessionId']! as String;
      remote.tabDeactivated(tabA);
      expect((await connect())['available'], isFalse);
      await activate(tabB);
      final Map<String, Object?> s = await connect();
      expect(s['available'], isTrue);
      expect(s['identity'], 'web:example.com/v2');
      expect(s['sessionId'], isNot(first));
    });

    test('关标签 / 页面没视频了 → 注销', () async {
      await activate(tabA);
      remote.tabClosed(tabA);
      expect((await connect())['available'], isFalse);

      await activate(tabB);
      expect((await connect())['available'], isTrue);
      pages['b']!.hasVideo = false;
      await remote.poll();
      expect((await connect())['available'], isFalse);
    });

    test('同一标签页换到别的视频（videoKey 变）= 新会话', () async {
      await activate(tabA);
      final String first = (await connect())['sessionId']! as String;
      pages['a']!.videoKey = 'example.com/v9';
      await remote.poll();
      final Map<String, Object?> s = await connect();
      expect(s['sessionId'], isNot(first));
      expect(s['identity'], 'web:example.com/v9');
    });

    test('原生播放器开在浏览页上面：轮询不抢；它关掉后手机回到浏览页', () async {
      await activate(tabA);
      final VideoRemotePlaybackBinding native = _nativeBinding();
      host.register(native);
      await remote.poll();
      expect((await connect())['identity'], 'native');
      host.unregister(native);
      expect((await connect())['identity'], 'web:example.com/v1');
    });

    test('浏览页开在原生播放器上面：浏览页关掉后手机回到原生播放器', () async {
      final VideoRemotePlaybackBinding native = _nativeBinding();
      host.register(native);
      await activate(tabA);
      expect((await connect())['identity'], 'web:example.com/v1');
      remote.dispose();
      expect((await connect())['identity'], 'native');
      // tearDown 还会再 dispose 一次：换一个空控制器接住。
      remote = WebBrowserVideoRemote(autoPoll: false, ports: remote.ports);
    });

    test('dispose 注销', () async {
      await activate(tabA);
      remote.dispose();
      remote = WebBrowserVideoRemote(ports: remote.ports, autoPoll: false);
      expect((await connect())['available'], isFalse);
    });
  });

  group('命令', () {
    setUp(() async {
      await activate(tabA);
      await connect();
    });

    test('播放 / 暂停 / 跳句 / 音量转发到页面', () async {
      final _FakePage page = pages['a']!;
      await call('command', <String, dynamic>{'action': 'pause'});
      expect(page.playing, isFalse);
      await call('command', <String, dynamic>{
        'action': 'seekCue',
        'cueId': 'primary:1',
      });
      expect(page.positionMs, 5000);
      expect(page.playing, isTrue);
      await call('command', <String, dynamic>{
        'action': 'volume',
        'volume': 80,
      });
      expect(page.volume, 80);
      expect(
        page.controls.map((Map<String, Object?> m) => m['action']),
        <Object?>['pause', 'seek', 'play', 'volume'],
      );
    });

    test('查词暂停：电脑前没人动过就续播，有人动过就不续', () async {
      final _FakePage page = pages['a']!;
      Map<String, Object?> lookup = await call('lookupBegin', <String, dynamic>{
        'cueId': 'primary:0',
      });
      expect(page.playing, isFalse);
      await call('lookupEnd', <String, dynamic>{
        'contextId': lookup['contextId'],
      });
      expect(page.playing, isTrue, reason: '遥控自己的暂停，关弹框续播');

      lookup = await call('lookupBegin', <String, dynamic>{
        'cueId': 'primary:0',
      });
      expect(page.playing, isFalse);
      page.revision++; // 电脑前的人拖了一下进度条
      await remote.poll();
      await call('lookupEnd', <String, dynamic>{
        'contextId': lookup['contextId'],
      });
      expect(page.playing, isFalse, reason: '电脑前有人操作过，不替他续播');
    });

    test('试听放的是加过留白的窗；停止试听走 stopRange', () async {
      final _FakePage page = pages['a']!;
      final VideoRemotePlaybackBinding binding = remote.binding!;
      final List<VideoRemoteCue> rows = binding.cues();
      expect(await binding.previewAudio!(rows[1], 5000, 6000), isTrue);
      expect(page.controls.last, <String, Object?>{
        'type': 'fushiRemoteControl',
        'action': 'playRange',
        'startMs': 4900,
        'endMs': 6200,
      });
      await binding.stopAudio!();
      expect(page.controls.last['action'], 'stopRange');
    });

    test('字幕轨：列出、选轨；「关闭」在网页里没有对应状态', () async {
      final List<VideoRemoteSubtitleOption> tracks =
          await remote.binding!.subtitleTracks!();
      expect(tracks.map((VideoRemoteSubtitleOption t) => t.label), <String>[
        '日本語',
        'sub.srt',
      ]);
      expect(tracks.first.selected, isTrue);
      expect(tracks.last.kind, 'external');
      await call('command', <String, dynamic>{
        'action': 'subtitleTrack',
        'trackId': tracks.last.id,
      });
      expect(pages['a']!.activeLang, '外挂:sub.srt');
      await expectLater(
        remote.binding!.selectSubtitleTrack!(null),
        throwsA(remoteError(409, 'subtitle_track_unavailable')),
      );
    });

    test('在线字幕：搜索给不透明 id，下载后装进页面', () async {
      final VideoRemoteOnlineSubtitleSearch search =
          await remote.binding!.searchSubtitles!(null, null);
      expect(search.query, 'Page a');
      expect(search.candidates.single.fileName, 'ep1.srt');
      expect(search.candidates.single.id, isNot(contains('http')));
      final VideoRemoteSubtitleApply apply =
          await remote.binding!.downloadSubtitle!(search.candidates.single.id);
      expect(runtimeCalls.last['handle'], 'jimaku:https://example.com/sub.srt');
      await apply();
      expect(pages['a']!.installed.single['filename'], 'ep1.srt');
      await expectLater(
        remote.binding!.downloadSubtitle!('unknown'),
        throwsA(remoteError(404, 'subtitle_candidate_missing')),
      );
    });

    test('下载期间换了视频：应用回 session_changed', () async {
      final VideoRemotePlaybackBinding binding = remote.binding!;
      final VideoRemoteOnlineSubtitleSearch search =
          await binding.searchSubtitles!('作品', 1);
      final VideoRemoteSubtitleApply apply = await binding.downloadSubtitle!(
        search.candidates.single.id,
      );
      pages['a']!.videoKey = 'example.com/other';
      await remote.poll();
      await expectLater(apply(), throwsA(remoteError(409, 'session_changed')));
      expect(pages['a']!.installed, isEmpty);
    });

    test('关闭视频 = 关掉这个标签页', () async {
      await call('closeVideo');
      expect(closed, <WebBrowserTab>[tabA]);
    });

    test('收藏句：本视频的跳过去播放，别处的回 favorite_source_unavailable', () async {
      final VideoRemotePlaybackBinding binding = remote.binding!;
      await binding.openFavorite(
        FavoriteSentence(
          text: '二',
          bookTitle: 'Page a',
          createdAt: DateTime(2026),
          bookKey: 'web:example.com/v1',
          normCharOffset: 5000,
          source: kFavoriteSentenceSourceVideo,
        ),
      );
      expect(pages['a']!.positionMs, 5000);
      expect(pages['a']!.playing, isTrue);
      await expectLater(
        binding.openFavorite(
          FavoriteSentence(
            text: '二',
            bookTitle: 'x',
            createdAt: DateTime(2026),
            bookKey: 'book-1',
            source: kFavoriteSentenceSourceVideo,
          ),
        ),
        throwsA(remoteError(404, 'favorite_source_unavailable')),
      );
    });
  });

  group('制卡', () {
    const VideoRemoteMineSelection selection = VideoRemoteMineSelection(
      sentence: '二',
      cueSentence: '二',
      startMs: 5000,
      endMs: 6000,
      adjusted: false,
    );
    Map<String, dynamic> request() => <String, dynamic>{
      'rawFields': <String, dynamic>{'expression': '二'},
    };

    test('YouTube：按视频 id + 加过留白的窗交给服务端裁', () async {
      pages['a']!.mineContext = <String, Object?>{
        'ok': true,
        'clip': <String, Object?>{'kind': 'youtube', 'id': 'yt123'},
        'title': 'YT',
      };
      await activate(tabA);
      final VideoRemoteCue cue = remote.binding!.cues()[1];
      final Map<String, Object?> result = await remote.binding!.mine(
        cue,
        request(),
        selection,
      );
      expect(result['success'], isTrue);
      final ImmersionMinePayload payload = mined.single;
      expect(payload.youtubeVideoId, 'yt123');
      expect(payload.clipStartMs, 4900);
      expect(payload.clipEndMs, 6200);
      expect(payload.sentence, '二');
      expect(payload.fields['expression'], '二');
    });

    test('Netflix / 取不到帧的普通站点 → video_extraction_unavailable', () async {
      await activate(tabA);
      final VideoRemoteCue cue = remote.binding!.cues()[1];
      pages['a']!.mineContext = <String, Object?>{
        'ok': true,
        'clip': <String, Object?>{'kind': 'netflix', 'id': '81001'},
      };
      await expectLater(
        remote.binding!.mine(cue, request(), selection),
        throwsA(remoteError(409, 'video_extraction_unavailable')),
      );
      pages['a']!.mineContext = <String, Object?>{'ok': true, 'clip': null};
      await expectLater(
        remote.binding!.mine(cue, request(), selection),
        throwsA(remoteError(409, 'video_extraction_unavailable')),
      );
      expect(mined, isEmpty);
    });

    test('失败与重复按手机认得的形状回报', () async {
      pages['a']!.mineContext = <String, Object?>{
        'ok': true,
        'clip': <String, Object?>{'kind': 'youtube', 'id': 'yt123'},
      };
      final List<String> outcomes = <String>['duplicate', 'error'];
      remote.dispose();
      remote = WebBrowserVideoRemote(
        autoPoll: false,
        ports: WebBrowserVideoRemotePorts(
          request: remote.ports.request,
          runtime: remote.ports.runtime,
          register: host.register,
          unregister: host.unregister,
          mineImmersion: (ImmersionMinePayload payload) async =>
              RemoteMineResult(result: outcomes.removeAt(0)),
          miningPads: () => (headPadMs: 0, tailPadMs: 0),
        ),
      );
      await activate(tabA);
      final VideoRemoteCue cue = remote.binding!.cues()[1];
      Map<String, Object?> r = await remote.binding!.mine(
        cue,
        request(),
        selection,
      );
      expect(r['success'], isFalse);
      expect(r['duplicate'], isTrue);
      expect(r.containsKey('error'), isFalse);
      r = await remote.binding!.mine(cue, request(), selection);
      expect(r['success'], isFalse);
      expect(r['error'], 'mining_failed');
      // 没有 closeTab 时不声明「关闭视频」。
      expect(remote.binding!.close, isNull);
    });

    test('载荷分流（纯函数）：B 站带帧与音轨身份，番剧缺 playurl 时只留帧', () {
      final String frame = base64Encode(<int>[1, 2, 3]);
      ImmersionMinePayload p = webBrowserRemoteMinePayload(
        context: <String, Object?>{
          'clip': <String, Object?>{
            'kind': 'bilibili',
            'id': 'BV1xx',
            'part': 2,
          },
          'screenshotBase64': frame,
          'playurlBody': '{}',
        },
        fields: <String, String>{'expression': 'x'},
        sentence: 's',
        cueSentence: 's',
        documentTitle: 'T',
        clipStartMs: 100,
        clipEndMs: 900,
        cueStartMs: 200,
      );
      expect(p.clipSourceKind, 'bilibili');
      expect(p.clipSourcePart, 2);
      expect(p.clipSourcePlayurlBody, '{}');
      expect(p.screenshotBytes, <int>[1, 2, 3]);
      expect(p.clipStartMs, 100);

      p = webBrowserRemoteMinePayload(
        context: <String, Object?>{
          'clip': <String, Object?>{'kind': 'bilibili-pgc', 'id': '123'},
          'screenshotBase64': frame,
        },
        fields: <String, String>{'expression': 'x'},
        sentence: 's',
        cueSentence: 's',
        documentTitle: 'T',
        clipStartMs: 100,
        clipEndMs: 900,
        cueStartMs: 200,
      );
      expect(p.clipSourceKind, isNull);
      expect(p.clipStartMs, isNull);
      expect(p.screenshotBytes, isNotNull);
      expect(p.isImmersion, isTrue);
    });
  });
}

VideoRemotePlaybackBinding _nativeBinding() => VideoRemotePlaybackBinding(
  identity: () => 'native',
  title: () => 'native',
  bookUid: () => 'native',
  sectionIndex: () => 0,
  cues: () => const <VideoRemoteCue>[],
  state: () => <String, Object?>{},
  command: (String action, Map<String, dynamic> body) async {},
  mine:
      (
        VideoRemoteCue cue,
        Map<String, dynamic> request,
        VideoRemoteMineSelection selection,
      ) async => <String, Object?>{},
  openFavorite: (FavoriteSentence favorite) async {},
  addListener: (_) {},
  removeListener: (_) {},
);

/// 假页面：subtitle-panel.js 的 `fushiRemote*` / 侧栏消息的最小实现。
class _FakePage {
  _FakePage({required this.videoKey});

  String videoKey;
  bool hasVideo = true;
  int positionMs = 3000;
  int durationMs = 120000;
  bool playing = true;
  int volume = 50;

  /// 页面里「不是遥控下发」的显式控制次数。
  int revision = 0;
  String activeLang = 'ja';
  Map<String, Object?>? mineContext;
  final List<Map<String, Object?>> controls = <Map<String, Object?>>[];
  final List<Map<String, Object?>> installed = <Map<String, Object?>>[];

  Map<String, Object?> state(bool includeCues) => <String, Object?>{
    'ok': true,
    'videoKey': videoKey,
    'hasVideo': hasVideo,
    'activeLang': activeLang,
    'currentTimeMs': positionMs,
    'offsetMs': 0,
    'tracks': <Object?>[
      <String, Object?>{
        'lang': 'ja',
        'label': '日本語',
        'pending': false,
        'signature': 'ja-sig',
        'length': 2,
      },
      <String, Object?>{
        'lang': '外挂:sub.srt',
        'label': 'sub.srt',
        'pending': false,
        'signature': 'ext-sig',
        'length': 1,
      },
    ],
    'cues': includeCues
        ? <Object?>[
            <String, Object?>{'startMs': 1000, 'endMs': 2000, 'text': '一'},
            <String, Object?>{'startMs': 5000, 'endMs': 6000, 'text': '二'},
          ]
        : null,
    'remote': <String, Object?>{
      'positionMs': positionMs,
      'durationMs': durationMs,
      'playing': playing,
      'rate': 1,
      'volume': volume,
      'controlRevision': revision,
      'site': 'other',
      'title': 'Page ${videoKey.endsWith('v2') ? 'b' : 'a'}',
    },
  };

  Object? handle(Map<String, Object?> message) {
    switch (message['type']) {
      case 'fushiRemoteState':
        return state(message['includeCues'] == true);
      case 'fushiRemoteControl':
        controls.add(message);
        switch (message['action']) {
          case 'play':
            playing = true;
          case 'pause':
          case 'stopRange':
            playing = false;
          case 'seek':
            positionMs = message['ms']! as int;
          case 'playRange':
            positionMs = message['startMs']! as int;
            playing = true;
          case 'volume':
            volume = message['volume']! as int;
          case 'selectTrack':
            activeLang = message['lang']! as String;
        }
        return state(false);
      case 'fushiRemoteMineContext':
        return mineContext;
      case 'fushiSubtitleSidePanelInstallTrack':
        installed.add(message);
        return state(true);
    }
    return null;
  }
}
