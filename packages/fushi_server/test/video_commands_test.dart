/// `fushi_server video …` 的契约：参数解析 → 引擎调用、`--json` 形状、退出码。
///
/// 不连网络：AniDB 走注入的 FILE 假实现 + 404 的 Fribb 映射；sidecar 走注入的重写
/// 函数（另有一条打到真协调器的「作品不存在」）。片段导出用真 ffmpeg 现做一段视频，
/// 本机没有 ffmpeg 时 skip（原因写在 skip 文案里）。蓝光盘用字节级合成的 MPLS。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/metadata/anidb_file_identity_store.dart';
import 'package:fushi_engine/media/video/metadata/anidb_hash_identity_service.dart';
import 'package:fushi_engine/media/video/metadata/anidb_udp_file_client.dart';
import 'package:fushi_engine/media/video/metadata/anime_identity_mapping.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_server/src/cli.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/library_scanner.dart';
import 'package:fushi_server/src/commands/video_cli_support.dart';
import 'package:fushi_server/src/commands/video_commands.dart';
import 'package:fushi_server/src/server_runtime.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/bluray_fixture.dart';

ArgResults _parse(List<String> args) {
  final ArgParser parser = ArgParser();
  buildVideoParser(parser);
  return parser.parse(args).command!;
}

bool _which(String tool) {
  try {
    return Process.runSync(tool, <String>['-version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

const AnidbFileIdentity _identity = AnidbFileIdentity(
  fileId: 99,
  animeId: 1234,
  episodeId: 5678,
  episodeNumber: '3',
  romajiTitle: 'Show Name',
  kanjiTitle: '番組名',
  englishTitle: 'Show Name EN',
  episodeTitle: 'Third',
  episodeRomajiTitle: 'Daisanwa',
  episodeKanjiTitle: '第三話',
  animeType: 'TV Series',
);

void main() {
  late Directory temp;
  late File config;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('fushi_video_cli_');
    config = File(p.join(temp.path, 'fushi_server.yaml'));
    expect(await runFushiServerCli(<String>['-c', config.path, 'init']), 0);
  });

  tearDownAll(() async {
    await temp.delete(recursive: true);
  });

  Future<T> withRt<T>(Future<T> Function(ServerRuntime rt) body) async {
    late T value;
    await withServerRuntime(config, false, (ServerRuntime rt) async {
      value = await body(rt);
      return 0;
    });
    return value;
  }

  group('时间参数', () {
    test('秒 / mm:ss / hh:mm:ss.mmm / ms 都认，非法写法返回 null', () {
      expect(parseClockArgToMs('90'), 90000);
      expect(parseClockArgToMs('1.5'), 1500);
      expect(parseClockArgToMs('1:30'), 90000);
      expect(parseClockArgToMs('01:02:03.250'), 3723250);
      expect(parseClockArgToMs('1500ms'), 1500);
      expect(parseClockArgToMs('1:75'), isNull);
      expect(parseClockArgToMs('abc'), isNull);
      expect(parseClockArgToMs('-3'), isNull);
      expect(formatClockMs(3723250), '01:02:03.250');
    });
  });

  group('video hash', () {
    test('ED2K = 单块文件的 MD4；JSON 带 ed2k 链接', () async {
      final File file = File(p.join(temp.path, 'abc.bin'))..writeAsStringSync('abc');
      final StringBuffer out = StringBuffer();
      final int code = await videoHash(
        _parse(<String>['hash', file.path, '--json']),
        io: CliIo(out: out, err: StringBuffer(), json: true),
        deps: const VideoDeps(),
      );
      expect(code, kExitOk);
      final Map<String, Object?> json = jsonDecode(out.toString()) as Map<String, Object?>;
      expect(json['ed2k'], 'a448017aaf21d8525fc10ae87aa6729d');
      expect(json['size'], 3);
      expect(json['link'], 'ed2k://|file|abc.bin|3|a448017aaf21d8525fc10ae87aa6729d|/');
    });

    test('经主 CLI：缺参数 64、文件不存在 66', () async {
      expect(await runFushiServerCli(<String>['-c', config.path, 'video']), kExitUsage);
      expect(await runFushiServerCli(<String>['-c', config.path, 'video', 'hash']), kExitUsage);
      expect(await runFushiServerCli(<String>['-c', config.path, 'video', 'hash', '/no/such/file']), kExitNoInput);
    });
  });

  group('video identify', () {
    late File file;
    setUp(() => file = File(p.join(temp.path, 'ep03.mkv'))..writeAsBytesSync(Uint8List(4096)));

    test('没有 AniDB 账号 → 发请求前就判 69，不造身份服务', () async {
      bool built = false;
      final StringBuffer out = StringBuffer();
      final int code = await withRt(
        (ServerRuntime rt) => videoIdentify(
          _parse(<String>['identify', file.path, '--json']),
          rt: rt,
          io: CliIo(out: out, err: StringBuffer(), json: true),
          deps: VideoDeps(
            environment: const <String, String>{},
            identityServiceFactory: (AnidbUdpConfig c, FushiDatabase db) {
              built = true;
              throw StateError('不该走到这里');
            },
          ),
        ),
      );
      expect(code, kExitUnavailable);
      expect(built, isFalse);
      expect((jsonDecode(out.toString()) as Map<String, Object?>)['error'], contains(kAniDbUsernameEnv));
    });

    test('账号来自环境变量、客户端身份是 Fushi 自己的；命中 → 0 并落持久层', () async {
      AnidbUdpConfig? seen;
      final StringBuffer out = StringBuffer();
      final int code = await withRt(
        (ServerRuntime rt) => videoIdentify(
          _parse(<String>['identify', file.path, '--json']),
          rt: rt,
          io: CliIo(out: out, err: StringBuffer(), json: true),
          deps: VideoDeps(
            environment: const <String, String>{kAniDbUsernameEnv: 'someuser', kAniDbPasswordEnv: 'pw'},
            identityServiceFactory: (AnidbUdpConfig c, FushiDatabase db) {
              seen = c;
              return AnidbHashIdentityService(
                enabled: true,
                config: c,
                lookup: ({required int size, required String ed2k}) async => _identity,
                episodeLookup: ({required int episodeId}) async => null,
                mapping: AnimeIdentityMapping(
                  httpClient: VideoMetadataHttpClient(
                    client: MockClient((http.Request r) async => http.Response('', 404)),
                    maxAttempts: 1,
                  ),
                ),
                store: AnidbFileIdentityDatabaseStore(db),
              );
            },
          ),
        ),
      );
      expect(code, kExitOk, reason: out.toString());
      expect(seen!.username, 'someuser');
      expect(seen!.clientName, 'fushiplayer');
      expect(seen!.clientName, isNot(contains('shoko')));
      final Map<String, Object?> json = jsonDecode(out.toString()) as Map<String, Object?>;
      expect(json['status'], 'matched');
      expect((json['identity'] as Map<String, Object?>)['animeId'], 1234);
      expect(json['ed2k'], isA<String>());
      expect(json['mappingError'], isNotNull); // Fribb 映射 404：不影响身份
    });

    test('AniDB 未收录 → 1；网络 / 封禁类失败 → 69', () {
      expect(aniDbFailureExitCode(const AnidbUdpException(AnidbUdpFailure.banned)), kExitUnavailable);
      expect(aniDbFailureExitCode(const AnidbUdpException(AnidbUdpFailure.timeout)), kExitUnavailable);
      expect(aniDbFailureExitCode(const AnidbUdpException(AnidbUdpFailure.malformedResponse)), kExitFailure);
    });
  });

  group('video sidecar write', () {
    Future<(int, String)> run(List<String> args, VideoDeps deps) async {
      final StringBuffer out = StringBuffer();
      final ArgResults sub = _parse(args);
      final int code = await withRt(
        (ServerRuntime rt) => runVideoCommand(
          sub,
          rt: rt,
          io: CliIo(out: out, err: StringBuffer(), json: args.contains('--json')),
          deps: deps,
        ),
      );
      return (code, out.toString());
    }

    test('workId → 调重写并输出报告；--replace 透传', () async {
      final List<(int, bool)> calls = <(int, bool)>[];
      final (int code, String out) = await run(
        <String>['sidecar', 'write', '7', '--replace', '--json'],
        VideoDeps(
          sidecarRewriter: (ServerRuntime rt, int id, {required bool replace}) async {
            calls.add((id, replace));
            return const SourceScrapeReport(sourceIds: <int>[1], totalWorks: 1, succeededWorks: 1, nfoWritten: 3);
          },
        ),
      );
      expect(code, kExitOk);
      expect(calls, <(int, bool)>[(7, true)]);
      final Map<String, Object?> json = jsonDecode(out) as Map<String, Object?>;
      expect(((json['works'] as List<Object?>).single as Map<String, Object?>)['nfoWritten'], 3);
    });

    test('用法错误 64；作品不存在 66（真协调器）；--all 空库 0', () async {
      expect((await run(<String>['sidecar', 'write'], const VideoDeps())).$1, kExitUsage);
      expect((await run(<String>['sidecar', 'write', '1', '--all'], const VideoDeps())).$1, kExitUsage);
      expect((await run(<String>['sidecar', 'write', 'abc'], const VideoDeps())).$1, kExitUsage);
      expect((await run(<String>['sidecar'], const VideoDeps())).$1, kExitUsage);
      expect((await run(<String>['sidecar', 'write', '424242'], const VideoDeps())).$1, kExitNoInput);
      expect((await run(<String>['sidecar', 'write', '--all'], const VideoDeps())).$1, kExitOk);
    });

    test('端到端：扫描入库 + 落一份规范资料 → 真协调器把 NFO 写到视频旁', () async {
      final Directory lib = Directory(p.join(temp.path, 'movies', 'Some Movie (2001)'))..createSync(recursive: true);
      final File movie = File(p.join(lib.path, 'Some Movie (2001).mkv'))..writeAsBytesSync(Uint8List(2048));
      final int workId = await withRt((ServerRuntime rt) async {
        await LibraryScanner(
          db: rt.db,
          subtitleLanguage: 'ja',
          pruneMissing: false,
        ).scanAll(<LibraryRootConfig>[LibraryRootConfig(id: 'movies', path: p.join(temp.path, 'movies'))]);
        final SourceLibraryRow source = (await rt.db.getMediaSourcesByKind('video')).single;
        final VideoSourceScrapeWork work = (await VideoSourceWorkPlanner(rt.db).plan(source)).single;
        final PersistedVideoMetadata persisted = await VideoMetadataDatabaseStore(rt.db).apply(
          work,
          VideoMetadataWork(
            provider: VideoMetadataProviderKind.tmdb,
            kind: VideoMetadataMediaKind.movie,
            title: 'Some Movie',
            year: 2001,
            plot: '一部电影。',
            ids: <VideoMetadataId>[VideoMetadataId(type: 'tmdb', value: '4242', isDefault: true)],
          ),
        );
        return persisted.workId;
      });
      final (int code, String out) = await run(<String>['sidecar', 'write', '$workId', '--json'], const VideoDeps());
      expect(code, kExitOk, reason: out);
      final Map<String, Object?> report =
          ((jsonDecode(out) as Map<String, Object?>)['works'] as List<Object?>).single as Map<String, Object?>;
      expect(report['nfoWritten'], 1);
      final List<File> nfos = lib
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith('.nfo'))
          .toList(growable: false);
      expect(nfos, hasLength(1));
      expect(nfos.single.readAsStringSync(), contains('<title>Some Movie</title>'));
      expect(nfos.single.readAsStringSync(), contains('4242'));
      // 再写一次：缺省「只补缺失」→ 已存在的不动。
      final (int again, String againOut) = await run(<String>[
        'sidecar',
        'write',
        '$workId',
        '--json',
      ], const VideoDeps());
      expect(again, kExitOk);
      expect(
        (((jsonDecode(againOut) as Map<String, Object?>)['works'] as List<Object?>).single
            as Map<String, Object?>)['nfoWritten'],
        0,
      );
      expect(movie.existsSync(), isTrue);
    });

    test('没有规范身份的作品 → 1，--all 时记跳过不中断', () async {
      final (int code, String out) = await run(
        <String>['sidecar', 'write', '5', '--json'],
        VideoDeps(
          sidecarRewriter: (ServerRuntime rt, int id, {required bool replace}) async => throw StateError('无身份'),
        ),
      );
      expect(code, kExitFailure);
      expect(
        ((jsonDecode(out) as Map<String, Object?>)['works'] as List<Object?>).single,
        containsPair('skipped', true),
      );
    });
  });

  group('video clip', () {
    late File video;
    setUp(() => video = File(p.join(temp.path, 'clip_src.mkv'))..writeAsStringSync('x'));

    Future<int> clip(List<String> args, {VideoDeps deps = const VideoDeps()}) => videoClip(
      _parse(args),
      io: CliIo(out: StringBuffer(), err: StringBuffer()),
      deps: deps,
    );

    test('用法 64 / 缺输入 66 / 缺 ffmpeg 69', () async {
      final String out = p.join(temp.path, 'o.mkv');
      expect(await clip(<String>['clip', video.path, '--from', '1', '-o', out]), kExitUsage);
      expect(await clip(<String>['clip', video.path, '--from', 'x', '--to', '2', '-o', out]), kExitUsage);
      expect(await clip(<String>['clip', video.path, '--from', '3', '--to', '2', '-o', out]), kExitUsage);
      expect(await clip(<String>['clip', video.path, '--from', '1', '--to', '2', '-o', video.path]), kExitUsage);
      expect(await clip(<String>['clip', '/no/such.mkv', '--from', '1', '--to', '2', '-o', out]), kExitNoInput);
      expect(
        await clip(<String>['clip', video.path, '--from', '1', '--to', '2', '-o', out, '--subs', '/no/such.srt']),
        kExitNoInput,
      );
      expect(
        await clip(<String>['clip', video.path, '--from', '1', '--to', '2', '-o', out, '--burn-subs', '/no/such.srt']),
        kExitNoInput,
      );
      expect(
        await clip(<String>[
          'clip',
          video.path,
          '--from',
          '1',
          '--to',
          '2',
          '-o',
          out,
        ], deps: VideoDeps(ffmpegProblem: ({required bool probe}) async => '找不到 ffmpeg')),
        kExitUnavailable,
      );
    });

    test(
      '真 ffmpeg：裁 1–3 秒并软封裁过的字幕进 mkv',
      () async {
        final File src = File(p.join(temp.path, 'real_src.mkv'));
        final ProcessResult made = await Process.run('ffmpeg', <String>[
          '-y', '-v', 'error', //
          '-f', 'lavfi', '-i', 'color=c=black:s=64x64:r=10:d=6',
          '-f', 'lavfi', '-i', 'sine=frequency=440:duration=6',
          '-c:v', 'mpeg4', '-c:a', 'aac', '-shortest',
          src.path,
        ]);
        expect(made.exitCode, 0, reason: '${made.stderr}');
        final File srt = File(p.join(temp.path, 'clip.srt'))
          ..writeAsStringSync('1\n00:00:01,500 --> 00:00:02,500\n片段里的台词\n\n2\n00:00:05,000 --> 00:00:05,500\n区间外\n\n');
        final String out = p.join(temp.path, 'clip_out.mkv');
        final StringBuffer json = StringBuffer();
        final int code = await videoClip(
          _parse(<String>['clip', src.path, '--from', '1', '--to', '0:03', '-o', out, '--subs', srt.path, '--json']),
          io: CliIo(out: json, err: StringBuffer(), json: true),
          deps: const VideoDeps(),
        );
        expect(code, kExitOk, reason: json.toString());
        final Map<String, Object?> body = jsonDecode(json.toString()) as Map<String, Object?>;
        expect(body['subtitleTracks'], 1);
        expect(File(out).lengthSync(), greaterThan(0));
      },
      skip: _which('ffmpeg') ? false : '本机 PATH 上没有 ffmpeg：片段导出要真跑 ffmpeg，跳过',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('video probe-bluray', () {
    test('合成盘：正片 + 预告，只列正片并带音轨 / 字幕轨', () async {
      final String root = p.join(temp.path, 'Movie [BDMV]');
      for (final String dir in <String>['PLAYLIST', 'CLIPINF', 'STREAM']) {
        Directory(p.join(root, 'BDMV', dir)).createSync(recursive: true);
      }
      void title(String id, int seconds) {
        const int start = 45000 * 4;
        File(p.join(root, 'BDMV', 'PLAYLIST', '$id.mpls')).writeAsBytesSync(
          buildMplsFixture(
            playItems: <FixturePlayItem>[
              FixturePlayItem(clipId: id, inTimeTicks: start, outTimeTicks: start + 45000 * seconds),
            ],
            streams: const <FixtureStream>[
              FixtureStream.video(codingType: 0x1B, videoFormat: 6, frameRate: 1),
              FixtureStream.audio(codingType: 0x83, language: 'jpn'),
              FixtureStream.subtitle(codingType: 0x90, language: 'jpn'),
            ],
            marks: const <FixtureMark>[FixtureMark(playItemIndex: 0, timestampTicks: start)],
          ),
        );
        File(p.join(root, 'BDMV', 'CLIPINF', '$id.clpi')).writeAsBytesSync(
          buildClpiFixture(presentationStartTicks: start, presentationEndTicks: start + 45000 * seconds),
        );
        File(p.join(root, 'BDMV', 'STREAM', '$id.m2ts')).writeAsBytesSync(Uint8List(4096));
      }

      title('00001', 7200);
      title('00002', 120);
      final StringBuffer out = StringBuffer();
      final int code = await videoProbeBluray(
        _parse(<String>['probe-bluray', root, '--json']),
        io: CliIo(out: out, err: StringBuffer(), json: true),
      );
      expect(code, kExitOk, reason: out.toString());
      final Map<String, Object?> json = jsonDecode(out.toString()) as Map<String, Object?>;
      expect(json['playlists'], 2);
      final Map<String, Object?> main = (json['titles'] as List<Object?>).single as Map<String, Object?>;
      expect(main['playlist'], '00001.mpls');
      expect(main['mainFeature'], isTrue);
      expect(main['durationMs'], 7200 * 1000);
      final Map<String, Object?> facts = main['facts'] as Map<String, Object?>;
      expect((facts['video'] as Map<String, Object?>)['codec'], 'h264');
      expect((facts['audio'] as List<Object?>).single, containsPair('codec', 'truehd'));
      expect((facts['subtitles'] as List<Object?>).single, containsPair('codec', 'hdmv_pgs_subtitle'));
    });

    test('不是盘目录 / 目录不存在 → 66；缺参数 64', () async {
      final CliIo io = CliIo(out: StringBuffer(), err: StringBuffer());
      expect(await videoProbeBluray(_parse(<String>['probe-bluray', temp.path]), io: io), kExitNoInput);
      expect(await videoProbeBluray(_parse(<String>['probe-bluray', '/no/such/dir']), io: io), kExitNoInput);
      expect(await videoProbeBluray(_parse(<String>['probe-bluray']), io: io), kExitUsage);
    });
  });
}
