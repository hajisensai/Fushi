/// `fushi_server subs …` 的契约：参数解析 → 引擎调用、`--json` 形状、退出码
/// （64 用法 / 66 缺输入 / 69 缺凭据或 ffmpeg / 1 业务失败）。
///
/// 不连网络：字幕来源全部换成注入的假 provider；视频时长与内嵌参考轨也走注入。
/// 只有最后一组用真 ffmpeg 现做一个带内嵌字幕轨的 mkv 跑通「对齐 → 还原」，本机没有
/// ffmpeg 时整组 skip（原因写在 skip 文案里）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi_server/src/cli.dart';
import 'package:fushi_server/src/commands/subs_commands.dart';
import 'package:fushi_server/src/commands/video_cli_support.dart';
import 'package:fushi_server/src/server_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _MapPrefs implements PrefStore {
  _MapPrefs([Map<String, Object?>? values]) : values = values ?? <String, Object?>{};

  final Map<String, Object?> values;

  @override
  dynamic getPref(String key, {dynamic defaultValue}) => values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => values[key] = value;
}

class _FakeCandidate extends VideoSubtitleCandidate {
  _FakeCandidate(String id, {required super.fileName, required super.language})
    : super(providerId: 'jimaku', remoteId: id, providerPriority: 100, releaseName: 'Group');
}

/// 记录请求、按 remoteId 回字节的假来源（冒用 jimaku 的 id，好过凭据门）。
class _FakeProvider implements VideoSubtitleProvider {
  _FakeProvider(this.candidates, {this.bytes = const <String, String>{}, this.failure});

  final List<VideoSubtitleCandidate> candidates;
  final Map<String, String> bytes;
  final ExternalProviderFailure? failure;
  final List<VideoSubtitleSearchRequest> requests = <VideoSubtitleSearchRequest>[];
  int downloads = 0;
  bool closed = false;

  @override
  String get id => 'jimaku';

  @override
  int get priority => 100;

  @override
  bool get allowsFreeProbeDownload => true;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(VideoSubtitleSearchRequest request) async {
    requests.add(request);
    if (failure != null) return ProviderBatchResult<VideoSubtitleCandidate>.failure(failure!);
    return ProviderBatchResult<VideoSubtitleCandidate>.success(candidates);
  }

  @override
  Future<VideoSubtitleDownload> download(VideoSubtitleCandidate candidate) async {
    downloads++;
    return VideoSubtitleDownload(
      bytes: Uint8List.fromList(utf8.encode(bytes[candidate.remoteId] ?? '')),
      fileName: candidate.fileName,
      language: candidate.language,
    );
  }

  @override
  void close() => closed = true;
}

ArgResults _parse(List<String> args) {
  final ArgParser parser = ArgParser();
  buildSubsParser(parser);
  return parser.parse(args).command!;
}

/// 一份 SRT：[count] 条，开始时刻按 [starts] 给（秒）。
String _srt(List<double> starts, {double length = 1.5}) {
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < starts.length; i++) {
    b
      ..writeln(i + 1)
      ..writeln('${_ts(starts[i])} --> ${_ts(starts[i] + length)}')
      ..writeln('台词 $i')
      ..writeln();
  }
  return b.toString();
}

String _ts(double seconds) {
  final int ms = (seconds * 1000).round();
  final Duration d = Duration(milliseconds: ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))},'
      '${d.inMilliseconds.remainder(1000).toString().padLeft(3, '0')}';
}

/// 不规则间隔的台词开始时刻（对齐算法要能在时间模板上找到唯一相关峰）。
List<double> _irregularStarts(int count, {double from = 10}) {
  final List<double> out = <double>[];
  double t = from;
  for (int i = 0; i < count; i++) {
    out.add(double.parse(t.toStringAsFixed(3)));
    t += 2.0 + (i * 7 % 5) * 0.9 + (i % 3) * 0.37;
  }
  return out;
}

void main() {
  late Directory temp;
  late File config;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('fushi_subs_cli_');
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

  group('凭据', () {
    test('环境变量优先且视为启用；偏好次之；缺 key 给配置提示', () {
      final _MapPrefs prefs = _MapPrefs(<String, Object?>{
        kSubdlApiKeyPref: 'from-pref',
        kSubdlEnabledPref: false,
        kJimakuApiKeyPref: '',
      });
      final SubsCredentials none = resolveSubsCredentials(prefs, const <String, String>{});
      expect(none.unavailableReason(kSubsProviderIds[1]), contains('关闭'));
      expect(none.unavailableReason('jimaku'), contains(kJimakuApiKeyEnv));

      final SubsCredentials env = resolveSubsCredentials(prefs, const <String, String>{
        kSubdlApiKeyEnv: 'env-key',
        kJimakuApiKeyEnv: 'jk',
        kOpenSubtitlesApiKeyEnv: 'os-key',
      });
      expect(env.subdlApiKey, 'env-key');
      expect(env.unavailableReason('subdl'), isNull);
      expect(env.unavailableReason('jimaku'), isNull);
      expect(env.openSubtitles.effectiveApiKey, 'os-key');
      expect(env.unavailableReason('opensubtitles'), isNull);
    });

    test('OpenSubtitles 偏好 JSON 与 app 同口径解码', () {
      final _MapPrefs prefs = _MapPrefs(<String, Object?>{
        kOpenSubtitlesConfigPref: jsonEncode(<String, Object?>{'apiKey': 'k1', 'enabled': true}),
      });
      expect(resolveSubsCredentials(prefs, const <String, String>{}).openSubtitles.effectiveApiKey, 'k1');
    });
  });

  group('subs search / download', () {
    late File video;

    setUp(() async {
      video = File(p.join(temp.path, '[Group] Show Name - 03 [1080p].mkv'));
      await video.writeAsBytes(List<int>.filled(256 * 1024, 7));
    });

    test('按文件名解析出标题与集号，合并结果并落搜索缓存', () async {
      final _FakeProvider provider = _FakeProvider(<VideoSubtitleCandidate>[
        _FakeCandidate('11:ep03.ja.srt', fileName: 'ep03.ja.srt', language: 'ja'),
        _FakeCandidate('11:ep03.en.srt', fileName: 'ep03.en.srt', language: 'en'),
      ]);
      final StringBuffer out = StringBuffer();
      final int code = await withRt(
        (ServerRuntime rt) => runSubsCommand(
          _parse(<String>['search', video.path, '-l', 'ja,EN', '--provider', 'jimaku', '--json']),
          rt: rt,
          io: CliIo(out: out, err: StringBuffer(), json: true),
          deps: SubsDeps(
            providerFactory: (String id, SubsCredentials c) => provider,
            environment: const <String, String>{kJimakuApiKeyEnv: 'jk'},
          ),
        ),
      );
      expect(code, kExitOk);
      final VideoSubtitleSearchRequest request = provider.requests.single;
      expect(request.query, 'Show Name');
      expect(request.episode, 3);
      expect(request.languages, <String>['ja', 'en']);
      expect(request.fingerprint?.fileSize, 256 * 1024);
      expect(request.fingerprint?.openSubtitlesMovieHash, isNotNull);
      expect(provider.closed, isTrue);
      final Map<String, Object?> json = jsonDecode(out.toString()) as Map<String, Object?>;
      expect(json['ok'], isTrue);
      final List<Object?> results = json['results'] as List<Object?>;
      expect(results, hasLength(2));
      expect((results.first as Map<String, Object?>)['id'], 'jimaku:11:ep03.ja.srt');
      expect((results.first as Map<String, Object?>)['language'], 'ja');
      expect(await withRt((ServerRuntime rt) async => subsSearchCacheFile(rt).existsSync()), isTrue);
    });

    test('download 按缓存的请求重新定位同一条，写到视频旁', () async {
      final _FakeProvider provider = _FakeProvider(
        <VideoSubtitleCandidate>[_FakeCandidate('11:ep03.ja.srt', fileName: 'ep03.ja.srt', language: 'ja')],
        bytes: <String, String>{
          '11:ep03.ja.srt': _srt(<double>[1, 5, 9, 1300]),
        },
      );
      final SubsDeps deps = SubsDeps(
        providerFactory: (String id, SubsCredentials c) => provider,
        environment: const <String, String>{kJimakuApiKeyEnv: 'jk'},
        probeDurationMs: (String path) async => 24 * 60 * 1000,
      );
      await withRt(
        (ServerRuntime rt) => runSubsCommand(
          _parse(<String>['search', video.path, '--provider', 'jimaku']),
          rt: rt,
          io: CliIo(out: StringBuffer(), err: StringBuffer()),
          deps: deps,
        ),
      );
      final StringBuffer out = StringBuffer();
      final int code = await withRt(
        (ServerRuntime rt) => runSubsCommand(
          _parse(<String>['download', 'jimaku:11:ep03.ja.srt', '--to', video.path, '--json']),
          rt: rt,
          io: CliIo(out: out, err: StringBuffer(), json: true),
          deps: deps,
        ),
      );
      expect(code, kExitOk);
      final String expected = p.join(temp.path, '[Group] Show Name - 03 [1080p].ja.srt');
      final Map<String, Object?> json = jsonDecode(out.toString()) as Map<String, Object?>;
      expect(json['output'], expected);
      expect((json['timing'] as Map<String, Object?>)['verdict'], 'ok');
      expect(File(expected).readAsStringSync(), contains('台词 3'));
      expect(provider.downloads, 1);

      // 已存在且没给 --force → 业务失败，不覆盖。
      final int again = await withRt(
        (ServerRuntime rt) => runSubsCommand(
          _parse(<String>['download', 'jimaku:11:ep03.ja.srt', '--to', video.path]),
          rt: rt,
          io: CliIo(out: StringBuffer(), err: StringBuffer()),
          deps: deps,
        ),
      );
      expect(again, kExitFailure);
      // 不在上次结果里的 id → 66；缺 --to → 64。
      Future<int> dl(List<String> args) => withRt(
        (ServerRuntime rt) => runSubsCommand(
          _parse(args),
          rt: rt,
          io: CliIo(out: StringBuffer(), err: StringBuffer()),
          deps: deps,
        ),
      );
      expect(await dl(<String>['download', 'jimaku:nope', '--to', video.path]), kExitNoInput);
      expect(await dl(<String>['download', 'jimaku:11:ep03.ja.srt']), kExitUsage);
      expect(await dl(<String>['download', 'bad-id', '--to', video.path]), kExitUsage);
    });

    test('点名的来源没配凭据 → 69，且不造 provider、不发请求', () async {
      bool built = false;
      final StringBuffer out = StringBuffer();
      final int code = await withRt(
        (ServerRuntime rt) => runSubsCommand(
          _parse(<String>['search', video.path, '--provider', 'subdl', '--json']),
          rt: rt,
          io: CliIo(out: out, err: StringBuffer(), json: true),
          deps: SubsDeps(
            providerFactory: (String id, SubsCredentials c) {
              built = true;
              return _FakeProvider(const <VideoSubtitleCandidate>[]);
            },
            environment: const <String, String>{},
          ),
        ),
      );
      expect(code, kExitUnavailable);
      expect(built, isFalse);
      expect((jsonDecode(out.toString()) as Map<String, Object?>)['exitCode'], kExitUnavailable);
    });

    test('唯一的来源搜索失败 → 69；没有结果 → 1', () async {
      Future<int> search(_FakeProvider provider) => withRt(
        (ServerRuntime rt) => runSubsCommand(
          _parse(<String>['search', video.path, '--provider', 'jimaku']),
          rt: rt,
          io: CliIo(out: StringBuffer(), err: StringBuffer()),
          deps: SubsDeps(
            providerFactory: (String id, SubsCredentials c) => provider,
            environment: const <String, String>{kJimakuApiKeyEnv: 'jk'},
          ),
        ),
      );
      expect(
        await search(
          _FakeProvider(
            const <VideoSubtitleCandidate>[],
            failure: const ExternalProviderFailure(
              providerId: 'jimaku',
              operation: 'search',
              kind: ExternalProviderFailureKind.unavailable,
              message: 'down',
            ),
          ),
        ),
        kExitUnavailable,
      );
      expect(await search(_FakeProvider(const <VideoSubtitleCandidate>[])), kExitFailure);
    });

    test('经主 CLI：缺参数 64、目标既非文件也非库内 id 66', () async {
      expect(await runFushiServerCli(<String>['-c', config.path, 'subs']), kExitUsage);
      expect(await runFushiServerCli(<String>['-c', config.path, 'subs', 'search']), kExitUsage);
      expect(await runFushiServerCli(<String>['-c', config.path, 'subs', 'search', 'no-such-video-id']), kExitNoInput);
      expect(await runFushiServerCli(<String>['-c', config.path, 'subs', 'search', '--provider', 'nope', 'x']), 64);
    });

    test('库内视频 id 解析到文件', () async {
      await withRt((ServerRuntime rt) async {
        await rt.db.upsertVideoBook(
          VideoBooksCompanion.insert(bookUid: 'vid-1', title: 'Show Name 03', videoPath: video.path),
        );
        return 0;
      });
      final _FakeProvider provider = _FakeProvider(const <VideoSubtitleCandidate>[]);
      await withRt(
        (ServerRuntime rt) => runSubsCommand(
          // 点名 jimaku：CI 会注入内置 OpenSubtitles key，不点名时 opensubtitles 也算可用，
          // 假工厂对两家返回同一个实例，请求就记了两条。
          _parse(<String>['search', 'vid-1', '--season', '2', '--provider', 'jimaku']),
          rt: rt,
          io: CliIo(out: StringBuffer(), err: StringBuffer()),
          deps: SubsDeps(
            providerFactory: (String id, SubsCredentials c) => provider,
            environment: const <String, String>{kJimakuApiKeyEnv: 'jk'},
          ),
        ),
      );
      expect(provider.requests.single.query, 'Show Name');
      expect(provider.requests.single.season, 2);
      expect(provider.requests.single.episode, 3);
    });
  });

  group('subs check', () {
    late File video;
    setUp(() async {
      video = File(p.join(temp.path, 'check.mkv'))..writeAsStringSync('not a real video');
    });

    Future<(int, Map<String, Object?>)> check(String subtitle, int? durationMs) async {
      final File sub = File(p.join(temp.path, 'check.srt'))..writeAsStringSync(subtitle);
      final StringBuffer out = StringBuffer();
      final int code = await subsCheck(
        _parse(<String>['check', video.path, sub.path, '--json']),
        io: CliIo(out: out, err: StringBuffer(), json: true),
        deps: SubsDeps(probeDurationMs: (String path) async => durationMs),
      );
      return (code, jsonDecode(out.toString()) as Map<String, Object?>);
    }

    test('与视频自洽 → 0；整季合并文件（远超视频）→ 1；读不出时间 → 1', () async {
      final (int ok, Map<String, Object?> okJson) = await check(_srt(<double>[5, 600, 1300]), 24 * 60 * 1000);
      expect(ok, kExitOk);
      expect(okJson['verdict'], 'ok');
      expect(okJson['cueCount'], 3);
      expect(okJson['videoDurationMs'], 24 * 60 * 1000);
      final (int over, Map<String, Object?> overJson) = await check(_srt(<double>[5, 5 * 3600]), 24 * 60 * 1000);
      expect(over, kExitFailure);
      expect(overJson['verdict'], 'overrunsVideo');
      expect((await check('garbage', 24 * 60 * 1000)).$1, kExitFailure);
    });

    test('量不到视频时长 → 69（主判据没跑，不能报通过）', () async {
      final (int code, Map<String, Object?> json) = await check(_srt(<double>[5, 600]), null);
      expect(code, kExitUnavailable);
      expect(json['videoDurationMs'], isNull);
    });

    test('缺文件 66、缺参数 64', () async {
      final CliIo io = CliIo(out: StringBuffer(), err: StringBuffer());
      expect(await subsCheck(_parse(<String>['check', video.path]), io: io, deps: const SubsDeps()), kExitUsage);
      expect(
        await subsCheck(_parse(<String>['check', video.path, '/no/such.srt']), io: io, deps: const SubsDeps()),
        kExitNoInput,
      );
    });
  });

  group('subs sync / restore（注入参考轨，不跑 ffmpeg）', () {
    test('ffmpeg 不可用 → 69；视频没有参考轨 → 1；非对齐产物 restore → 1', () async {
      final File video = File(p.join(temp.path, 'sync.mkv'))..writeAsStringSync('x');
      final File sub = File(p.join(temp.path, 'sync.srt'))..writeAsStringSync(_srt(_irregularStarts(30)));
      await withRt((ServerRuntime rt) async {
        final CliIo io = CliIo(out: StringBuffer(), err: StringBuffer());
        expect(
          await subsSync(
            _parse(<String>['sync', video.path, sub.path]),
            io: io,
            deps: SubsDeps(ffmpegProblem: ({required bool probe}) async => '找不到 ffmpeg'),
          ),
          kExitUnavailable,
        );
        final StringBuffer out = StringBuffer();
        expect(
          await subsSync(
            _parse(<String>['sync', video.path, sub.path, '--json']),
            io: CliIo(out: out, err: StringBuffer(), json: true),
            deps: SubsDeps(
              ffmpegProblem: ({required bool probe}) async => null,
              loadReferences: (String path) async => const [],
              probeDurationMs: (String path) async => null,
            ),
          ),
          kExitFailure,
        );
        expect((jsonDecode(out.toString()) as Map<String, Object?>)['status'], 'noReference');
        expect(await subsRestore(_parse(<String>['restore', sub.path]), io: io), kExitFailure);
        expect(await subsSync(_parse(<String>['sync', video.path]), io: io, deps: const SubsDeps()), kExitUsage);
        return 0;
      });
    });
  });

  group('真 ffmpeg：对齐 → 还原', () {
    final bool hasFfmpeg = _which('ffmpeg') && _which('ffprobe');
    test(
      '外挂字幕整体晚 4 秒 → 按内嵌轨拉回，restore 找回原稿',
      () async {
        final List<double> starts = _irregularStarts(40);
        final File ref = File(p.join(temp.path, 'ref.srt'))..writeAsStringSync(_srt(starts));
        final File video = File(p.join(temp.path, 'with_subs.mkv'));
        final ProcessResult made = await Process.run('ffmpeg', <String>[
          '-y', '-v', 'error', //
          '-f', 'lavfi', '-i', 'color=c=black:s=32x32:r=2:d=${(starts.last + 30).ceil()}',
          '-i', ref.path,
          '-map', '0:v', '-map', '1:s',
          '-c:v', 'mpeg4', '-c:s', 'srt',
          video.path,
        ]);
        expect(made.exitCode, 0, reason: '${made.stderr}');
        final String original = _srt(starts.map((double s) => s + 4.0).toList());
        final File sub = File(p.join(temp.path, 'late.srt'))..writeAsStringSync(original);

        await withRt((ServerRuntime rt) async {
          final StringBuffer out = StringBuffer();
          final int code = await subsSync(
            _parse(<String>['sync', video.path, sub.path, '--force', '--json']),
            io: CliIo(out: out, err: StringBuffer(), json: true),
            deps: const SubsDeps(),
          );
          final Map<String, Object?> json = jsonDecode(out.toString()) as Map<String, Object?>;
          expect(code, kExitOk, reason: '$json');
          expect(json['applied'], isTrue);
          final double offset =
              ((json['offsets'] as List<Object?>).first as Map<String, Object?>)['offsetSeconds'] as double;
          expect(offset, closeTo(-4.0, 0.2));
          expect(sub.readAsStringSync(), isNot(original));

          // 已是对齐产物：再 sync 被拒（先 restore）。
          expect(
            await subsSync(
              _parse(<String>['sync', video.path, sub.path]),
              io: CliIo(out: StringBuffer(), err: StringBuffer()),
              deps: const SubsDeps(),
            ),
            kExitFailure,
          );
          expect(
            await subsRestore(
              _parse(<String>['restore', sub.path]),
              io: CliIo(out: StringBuffer(), err: StringBuffer()),
            ),
            kExitOk,
          );
          expect(sub.readAsStringSync(), original);

          // 真 ffprobe 探时长：ref 与视频自洽。
          expect(
            await subsCheck(
              _parse(<String>['check', video.path, ref.path]),
              io: CliIo(out: StringBuffer(), err: StringBuffer()),
              deps: const SubsDeps(),
            ),
            kExitOk,
          );
          return 0;
        });
      },
      skip: hasFfmpeg ? false : '本机 PATH 上没有 ffmpeg / ffprobe：对齐要抽内嵌字幕轨，跳过真机路径',
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}

bool _which(String tool) {
  try {
    return Process.runSync(tool, <String>['-version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}
