import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fushi_engine/tts/local/irodori_local_server.dart';
import 'package:fushi_engine/tts/local/local_service_process.dart';
import 'package:fushi_engine/tts/providers/irodori_server_tts_provider.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

/// 官方 `/health` 的形状（字段取自 Irodori-TTS-Server 61012c7 的 app.py）。
const String _health = '''
{"status":"ok","model":{"id":"irodori-tts","hf_checkpoint":"Aratako/Irodori-TTS-v4.1-Small","model_device":"auto"},
 "runtime":{"preload":true,"loaded":true},"voices":{"dir":"voices","dir_exists":true,"files":0},"defaults":{}}''';
const String _models =
    '{"object":"list","data":[{"id":"irodori-tts","object":"model","created":0,"owned_by":"irodori-tts"}]}';

void main() {
  group('官方服务接口', () {
    late HttpServer server;
    late Directory tmp;
    final List<
      ({String method, String path, List<int> body, HttpHeaders headers})
    >
    requests =
        <({String method, String path, List<int> body, HttpHeaders headers})>[];
    int uploadStatus = 201;

    setUp(() async {
      requests.clear();
      uploadStatus = 201;
      tmp = await Directory.systemTemp.createTemp('irodori_server_test');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        final List<int> body = await req.fold<List<int>>(
          <int>[],
          (List<int> a, List<int> b) => a..addAll(b),
        );
        requests.add((
          method: req.method,
          path: req.uri.path,
          body: body,
          headers: req.headers,
        ));
        final HttpResponse res = req.response;
        switch ((req.method, req.uri.path)) {
          case ('GET', '/v1/audio/voices'):
            res.headers.contentType = ContentType.json;
            res.write(
              jsonEncode(<String, Object?>{
                'object': 'list',
                'data': <Object?>[
                  <String, Object?>{'id': 'alice', 'ref_wav': '/v/alice.wav'},
                  <String, Object?>{'id': 'none', 'no_ref': true},
                ],
              }),
            );
          case ('POST', '/v1/audio/speech'):
            res.add(buildWav(dataBytes: 3200));
          case ('POST', '/v1/audio/voices'):
            res.statusCode = uploadStatus;
            res.write(
              uploadStatus == 409
                  ? '{"error":{"message":"Voice \'bob\' already exists."}}'
                  : '{"id":"bob","object":"voice_file"}',
            );
          case ('DELETE', '/v1/audio/voices/bob'):
            res.write('{"id":"bob","deleted":true}');
          default:
            res.statusCode = 404;
        }
        await res.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      await tmp.delete(recursive: true);
    });

    String endpoint() => 'http://127.0.0.1:${server.port}/v1';

    TtsProvider provider({
      String voice = 'alice',
      String caption = '',
      String apiKey = '',
    }) => const IrodoriServerTtsDescriptor().create(
      TtsVoicePreset(
        id: 'p',
        providerId: IrodoriServerTtsDescriptor.providerId,
        name: 'n',
        params: <String, String>{
          'endpoint': endpoint(),
          'voice': voice,
          'caption': caption,
        },
        secrets: <String, String>{if (apiKey.isNotEmpty) 'api_key': apiKey},
      ),
      TtsHost(httpClientFactory: () => HttpClient()),
    );

    test('合成走 /v1/audio/speech：官方 model 名、wav、caption 进 irodori 选项', () async {
      final TtsProvider p = provider(caption: '落ち着いた声', apiKey: 'k');
      final String out = '${tmp.path}/a.wav';
      final TtsResult r = await p.synthesize(
        'こんにちは',
        outputPath: out,
        cancel: TtsCancelToken(),
      );
      await p.dispose();
      expect(r.format, TtsAudioFormat.wav);
      expect(File(out).lengthSync(), greaterThan(44));
      final ({String method, String path, List<int> body, HttpHeaders headers})
      req = requests.single;
      expect(req.path, '/v1/audio/speech');
      expect(jsonDecode(utf8.decode(req.body)), <String, Object?>{
        'model': 'irodori-tts',
        'input': 'こんにちは',
        'voice': 'alice',
        'response_format': 'wav',
        'irodori': <String, Object?>{'caption': '落ち着いた声'},
      });
      expect(req.headers.value(HttpHeaders.authorizationHeader), 'Bearer k');
    });

    test('不填 caption 时不带 irodori 选项；默认声音是 none', () {
      expect(
        irodoriServerSpeechRequest(text: 'a', voice: ' none '),
        <String, Object?>{
          'model': 'irodori-tts',
          'input': 'a',
          'voice': 'none',
          'response_format': 'wav',
        },
      );
      const TtsVoicePreset empty = TtsVoicePreset(
        id: 'x',
        providerId: IrodoriServerTtsDescriptor.providerId,
        name: 'x',
      );
      expect(const IrodoriServerTtsDescriptor().validate(empty), isEmpty);
    });

    test('列声音：/v1/audio/voices 的 data[].id', () async {
      final TtsProvider p = provider();
      final List<TtsVoice> voices = await p.listVoices();
      await p.dispose();
      expect(voices.map((TtsVoice v) => v.id), <String>['alice', 'none']);
      final List<IrodoriServerVoice> parsed = await IrodoriServerVoiceApi(
        endpoint: endpoint(),
        httpClientFactory: () => HttpClient(),
      ).list();
      expect(parsed.last.noReference, isTrue);
      expect(parsed.first.noReference, isFalse);
    });

    test('上传参考音频：multipart 的 voice_id + file；409 → exists', () async {
      final File wav = File('${tmp.path}/ボブ.wav')..writeAsBytesSync(buildWav());
      final IrodoriServerVoiceApi api = IrodoriServerVoiceApi(
        endpoint: endpoint(),
        httpClientFactory: () => HttpClient(),
      );
      expect(await api.upload(file: wav, voiceId: 'bob'), 'bob');
      final ({String method, String path, List<int> body, HttpHeaders headers})
      req = requests.last;
      expect(req.method, 'POST');
      expect(req.headers.contentType!.mimeType, 'multipart/form-data');
      final String text = latin1.decode(req.body);
      expect(text, contains('name="voice_id"\r\n\r\nbob\r\n'));
      // 文件名换成 ASCII 的 <id>.<扩展名>，服务端只看扩展名。
      expect(text, contains('name="file"; filename="bob.wav"'));
      expect(text, contains('RIFF'));

      uploadStatus = 409;
      await expectLater(
        api.upload(file: wav, voiceId: 'bob'),
        throwsA(
          isA<IrodoriVoiceUploadException>().having(
            (IrodoriVoiceUploadException e) => e.failure,
            'failure',
            IrodoriVoiceUploadFailure.exists,
          ),
        ),
      );
      // 不合法的 id / 扩展名不发请求。
      final int before = requests.length;
      await expectLater(
        api.upload(file: wav, voiceId: 'ボブ'),
        throwsA(isA<IrodoriVoiceUploadException>()),
      );
      await expectLater(
        api.upload(
          file: File('${tmp.path}/a.txt')..writeAsStringSync('x'),
          voiceId: 'a',
        ),
        throwsA(isA<IrodoriVoiceUploadException>()),
      );
      expect(requests.length, before);
    });

    test('删除声音：DELETE /v1/audio/voices/{id}；没有这个声音返回 false', () async {
      final IrodoriServerVoiceApi api = IrodoriServerVoiceApi(
        endpoint: endpoint(),
        httpClientFactory: () => HttpClient(),
      );
      expect(await api.delete('bob'), isTrue);
      expect(requests.last.method, 'DELETE');
      expect(await api.delete('carol'), isFalse);
    });
  });

  test('multipart 体：边界一致、字段顺序固定', () {
    final ({String contentType, List<int> body}) form = irodoriVoiceUploadForm(
      voiceId: 'v',
      fileName: 'v.flac',
      bytes: <int>[1, 2, 3],
      random: Random(1),
    );
    final String boundary = form.contentType.split('boundary=').last;
    final String text = latin1.decode(form.body);
    expect(text, startsWith('--$boundary\r\n'));
    expect(text, endsWith('\r\n--$boundary--\r\n'));
    expect(text.indexOf('voice_id'), lessThan(text.indexOf('filename')));
  });

  test('缓存身份带端口：换一台服务不复用另一台的音频', () {
    TtsVoicePreset preset(String endpoint) => TtsVoicePreset(
      id: 'p',
      providerId: IrodoriServerTtsDescriptor.providerId,
      name: 'n',
      params: <String, String>{'endpoint': endpoint, 'voice': 'a'},
    );
    const IrodoriServerTtsDescriptor d = IrodoriServerTtsDescriptor();
    expect(
      d.audioIdentity(preset('http://127.0.0.1:8088')),
      isNot(d.audioIdentity(preset('http://127.0.0.1:8089'))),
    );
    expect(
      d.audioIdentity(preset('http://127.0.0.1:8088')),
      d.audioIdentity(preset('http://localhost:8088')),
    );
  });

  group('探活与进程托管', () {
    test('只认官方 /health + /v1/models 的形状', () {
      expect(irodoriProbeLooksLikeServer(_health, _models), isTrue);
      // 别的 OpenAI 兼容服务（owned_by 不是 irodori-tts）。
      expect(
        irodoriProbeLooksLikeServer(
          _health,
          '{"data":[{"id":"tts-1","owned_by":"openai"}]}',
        ),
        isFalse,
      );
      // 随便一个答 /health 的服务。
      expect(irodoriProbeLooksLikeServer('{"status":"ok"}', _models), isFalse);
      expect(irodoriProbeLooksLikeServer('<html>', _models), isFalse);
    });

    test('pid 文件名独立、默认就绪超时更长', () {
      final IrodoriLocalServer server = IrodoriLocalServer(
        probe: (int _) async => false,
      );
      expect(server.pidFileName, kIrodoriPidFileName);
      expect(server.readyTimeout, const Duration(minutes: 10));
      server.dispose();
    });

    test('起进程后探活成功即 running，并带上服务的环境变量', () async {
      final Directory dir = Directory.systemTemp.createTempSync('irodori_srv_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File python = File('${dir.path}/python.exe')..writeAsStringSync('');
      Map<String, String>? env;
      int probes = 0;
      int afterKill = 0;
      final _HangingProcess process = _HangingProcess();
      final IrodoriLocalServer server = IrodoriLocalServer(
        spawn:
            (
              String exe,
              List<String> args, {
              String? workingDirectory,
              Map<String, String>? environment,
            }) async {
              env = environment;
              return process;
            },
        // 杀掉后端口还要答两次话（Windows 上 venv 启动器的子进程晚一拍退出）。
        probe: (int port) async =>
            process.killed ? ++afterKill <= 2 : ++probes >= 3,
        probeInterval: Duration.zero,
      );
      final bool ok = await server.start(
        LocalServiceLaunchSpec(
          executable: python.path,
          arguments: const <String>['-m', 'irodori_openai_tts'],
          workingDirectory: dir.path,
          port: 18088,
          environment: const <String, String>{'IRODORI_PRELOAD': 'true'},
        ),
      );
      expect(ok, isTrue);
      expect(env!['IRODORI_PRELOAD'], 'true');
      expect(env!['PYTHONIOENCODING'], 'utf-8');
      expect(File('${dir.path}/$kIrodoriPidFileName').existsSync(), isTrue);
      await server.stop();
      expect(server.phase, LocalServicePhase.stopped);
      // stop 等到端口不再答话才返回，紧接着的 start 不会把退出中的服务当外部服务借用。
      expect(afterKill, 3);
    });
  });
}

class _HangingProcess implements Process {
  final Completer<int> _exit = Completer<int>();
  bool killed = false;

  @override
  Stream<List<int>> get stdout => const Stream<List<int>>.empty();
  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();
  @override
  IOSink get stdin => throw UnimplementedError();
  @override
  int get pid => 4343;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(-15);
    return true;
  }
}
