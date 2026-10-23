import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/tts/system_tts_provider.dart';
import 'package:fushi/src/utils/misc/desktop_tts.dart';
import 'package:fushi/src/utils/misc/system_tts.dart';
import 'package:fushi/src/utils/misc/system_tts_voices.dart';
import 'package:fushi/src/utils/misc/windows_speech_worker.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

/// 系统语音的引擎 / 声音选择（「系统语音读不到系统 TTS 引擎」）：各平台原生输出的
/// 解析、声音 id 编码、预设参数与缓存身份、Windows 常驻工作进程的收发。
void main() {
  group('Android', () {
    test('引擎表：默认引擎排第一，缺 label 用包名，坏条目丢弃', () {
      final List<SystemTtsEngine> engines = parseAndroidTtsEngines(<Object?>[
        <String, Object?>{
          'name': 'com.google.android.tts',
          'label': 'Speech Services by Google',
          'isDefault': false,
        },
        <String, Object?>{
          'name': 'com.iflytek.speechcloud',
          'label': '讯飞语音引擎',
          'isDefault': true,
        },
        <String, Object?>{'name': 'org.example.tts'},
        <String, Object?>{'label': 'no package'},
        'garbage',
      ]);
      expect(engines.map((SystemTtsEngine e) => e.id), <String>[
        'com.iflytek.speechcloud',
        'com.google.android.tts',
        'org.example.tts',
      ]);
      expect(engines.first.isDefault, isTrue);
      expect(engines.last.label, 'org.example.tts');
    });

    test('声音表：locale 规整成 BCP-47，需要联网的声音标出来', () {
      final List<TtsVoice> voices = parseAndroidTtsVoices(<Object?>[
        <String, Object?>{
          'name': 'ja-jp-x-htm-local',
          'locale': 'ja-JP',
          'network': false,
        },
        <String, Object?>{
          'name': 'ja-jp-x-jab-network',
          'locale': 'ja_JP',
          'network': true,
        },
      ]);
      expect(voices.first.id, 'ja-jp-x-htm-local');
      expect(voices.first.gender, isNull);
      expect(voices.last.locale, 'ja-JP');
      expect(voices.last.gender, 'network');
    });
  });

  test('iOS：AVSpeechSynthesisVoice 列表', () {
    final List<TtsVoice> voices = parseAppleSpeechVoices(<Object?>[
      <String, Object?>{
        'id': 'com.apple.voice.compact.ja-JP.Kyoko',
        'name': 'Kyoko',
        'locale': 'ja-JP',
        'quality': '',
      },
      <String, Object?>{
        'id': 'com.apple.voice.premium.ja-JP.Otoya',
        'name': 'Otoya',
        'locale': 'ja-JP',
        'quality': 'premium',
      },
    ]);
    expect(voices.map((TtsVoice v) => v.id), <String>[
      'com.apple.voice.compact.ja-JP.Kyoko',
      'com.apple.voice.premium.ja-JP.Otoya',
    ]);
    expect(voices.first.gender, isNull);
    expect(voices.last.gender, 'premium');
  });

  test('macOS：say -v ? 解析（macOS 27 真实输出：括号名、同名重复只留一条）', () {
    const String list =
        'Albert              en_US    # Hello! My name is Albert.\n'
        'Good News           en_US    # We cannot control the weather.\n'
        'Kyoko (日语（日本）)      ja_JP    # こんにちは! 私の名前はKyokoです。\n'
        'Kyoko (日语（日本）)      ja_JP    # こんにちは! 私の名前はKyokoです。\n'
        'garbage line\n';
    final List<TtsVoice> voices = parseMacOSSayVoices(list);
    expect(voices.map((TtsVoice v) => v.id), <String>[
      'Albert',
      'Good News',
      'Kyoko (日语（日本）)',
    ]);
    expect(voices.last.locale, 'ja-JP');
  });

  group('Windows', () {
    test('OneCore 取 token 名作 id；与 OneCore 同名的 SAPI 声音去重，不同名的保留', () {
      final List<TtsVoice> voices = mergeWindowsSpeechVoices(<Object?>[
        <String, Object?>{
          'kind': 'winrt',
          'id':
              r'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Speech_OneCore\Voices\Tokens\MSTTS_V110_jaJP_HarukaM',
          'name': 'Microsoft Haruka',
          'lang': 'ja-JP',
          'gender': 'Female',
        },
        <String, Object?>{
          'kind': 'sapi',
          'id': 'Microsoft Haruka Desktop',
          'name': 'Microsoft Haruka Desktop',
          'lang': 'ja-JP',
          'gender': 'Female',
        },
        <String, Object?>{
          'kind': 'sapi',
          'id': 'Microsoft Haruka',
          'name': 'Microsoft Haruka',
          'lang': 'ja-JP',
          'gender': 'Female',
        },
        <String, Object?>{
          'kind': 'sapi',
          'id': 'VOICEROID Yukari',
          'name': 'VOICEROID Yukari',
          'lang': 'ja-JP',
          'gender': 'NotSet',
        },
      ]);
      expect(voices.map((TtsVoice v) => v.id), <String>[
        'onecore:MSTTS_V110_jaJP_HarukaM',
        'sapi:Microsoft Haruka Desktop',
        'sapi:VOICEROID Yukari',
      ]);
      expect(voices.last.gender, isNull);
    });

    test('声音 id 往返', () {
      expect(parseWindowsVoiceId('onecore:MSTTS_V110_jaJP_HarukaM'), (
        kind: 'onecore',
        key: 'MSTTS_V110_jaJP_HarukaM',
      ));
      expect(parseWindowsVoiceId('sapi:A B'), (kind: 'sapi', key: 'A B'));
      expect(parseWindowsVoiceId('sapi:'), isNull);
      expect(parseWindowsVoiceId('Kyoko'), isNull);
    });

    test('协议消息编解码往返；不是协议的行忽略', () {
      final String line = encodeWindowsSpeechMessage(<String, Object?>{
        'id': 3,
        'text': 'こんにちは',
      });
      expect(line, isNot(contains('\n')));
      expect(decodeWindowsSpeechMessage(line), <String, Object?>{
        'id': 3,
        'text': 'こんにちは',
      });
      expect(decodeWindowsSpeechMessage('WARNING: something'), isNull);
      expect(decodeWindowsSpeechMessage(''), isNull);
    });

    test('工作进程脚本：WinRT 用 AsTask 等待、SAPI 兜底、声音不在报约定码', () {
      expect(
        kWindowsSpeechWorkerScript,
        contains('SynthesizeTextToStreamAsync'),
      );
      expect(kWindowsSpeechWorkerScript, contains("'IAsyncOperation`1'"));
      expect(kWindowsSpeechWorkerScript, contains('System.Speech'));
      expect(kWindowsSpeechWorkerScript, contains("'VOICE_UNAVAILABLE'"));
      expect(kWindowsSpeechWorkerScript, contains("'LANGUAGE_NOT_SUPPORTED'"));
      // 连接断开（宿主退出）就退出循环；等待期间每秒查宿主 PID，不留孤儿进程。
      expect(
        kWindowsSpeechWorkerScript,
        contains(r'if ($null -eq $line) { break }'),
      );
      expect(kWindowsSpeechWorkerScript, contains(r'$parent.HasExited'));
      // 请求走回环 TCP 而不是 stdin（Dart 在 Windows 写进 PowerShell stdin 的后续数据读不到）。
      expect(
        kWindowsSpeechWorkerScript,
        contains('[System.Net.IPAddress]::Loopback'),
      );
      expect(kWindowsSpeechWorkerScript, isNot(contains('[Console]::In')));
      // 口令不对的连接直接断开。
      expect(
        kWindowsSpeechWorkerScript,
        contains(r'if ($first -eq $fushiToken)'),
      );
      final String command = windowsSpeechWorkerCommand(
        parentPid: 42,
        token: 'deadbeef',
      );
      expect(
        command,
        startsWith("\$fushiParentPid = 42\n\$fushiToken = 'deadbeef'\n"),
      );
    });

    test('常驻进程：只起一次、按 id 配对应答、失败码映射成 SystemTtsFailure', () async {
      int starts = 0;
      final _FakeWorkerProcess fake = _FakeWorkerProcess((
        Map<String, Object?> req,
      ) {
        final String out = req['out']! as String;
        if (req['voiceKind'] == 'sapi') {
          return <String, Object?>{'ok': false, 'code': 'VOICE_UNAVAILABLE'};
        }
        File(out).writeAsBytesSync(<int>[1, 2, 3]);
        return <String, Object?>{'ok': true, 'path': out};
      });
      final WindowsSpeechWorker worker = WindowsSpeechWorker(
        startProcess: (String exe, List<String> args) async {
          starts++;
          expect(exe, 'powershell.exe');
          return fake.launch(args);
        },
      );
      final Directory dir = Directory.systemTemp.createTempSync('fushi_win_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String a = await synthesizeWindowsSpeech(
        worker: worker,
        text: 'あ',
        outputPath: '${dir.path}/a.wav',
        languageTag: 'ja',
        voice: null,
      );
      final String b = await synthesizeWindowsSpeech(
        worker: worker,
        text: 'い',
        outputPath: '${dir.path}/b.wav',
        languageTag: 'ja',
        voice: 'onecore:MSTTS_V110_jaJP_HarukaM',
      );
      expect(a, '${dir.path}/a.wav');
      expect(b, '${dir.path}/b.wav');
      await expectLater(
        synthesizeWindowsSpeech(
          worker: worker,
          text: 'う',
          outputPath: '${dir.path}/c.wav',
          languageTag: 'ja',
          voice: 'sapi:Gone',
        ),
        throwsA(
          isA<SystemTtsFailure>().having(
            (SystemTtsFailure f) => f.reason,
            'reason',
            SystemTtsFailureReason.voiceUnavailable,
          ),
        ),
      );
      expect(starts, 1, reason: '每句起一个 PowerShell 正是要消掉的停顿');
      expect(fake.requests.map((Map<String, Object?> r) => r['id']), <int>[
        1,
        2,
        3,
      ]);
      expect(fake.tokensSeen, hasLength(1));
      expect(fake.tokensSeen.single, matches(RegExp(r'^[0-9a-f]{32}$')));
      fake.kill();
    });

    test('工作进程起不来 = 没有引擎', () async {
      final WindowsSpeechWorker worker = WindowsSpeechWorker(
        startProcess: (String exe, List<String> args) =>
            throw ProcessException(exe, args),
      );
      final Directory dir = Directory.systemTemp.createTempSync('fushi_win_');
      addTearDown(() => dir.deleteSync(recursive: true));
      await expectLater(
        synthesizeWindowsSpeech(
          worker: worker,
          text: 'あ',
          outputPath: '${dir.path}/a.wav',
          languageTag: null,
          voice: null,
        ),
        throwsA(
          isA<SystemTtsFailure>().having(
            (SystemTtsFailure f) => f.reason,
            'reason',
            SystemTtsFailureReason.engineUnavailable,
          ),
        ),
      );
    });
  });

  group('Linux', () {
    test('espeak-ng --voices 解析', () {
      const String out =
          'Pty Language       Age/Gender VoiceName          File                 Other Languages\n'
          ' 5  en-us           --/M      English_(America)  gmw/en-US            (en 3)\n'
          ' 5  ja              --/M      Japanese           jpx/ja\n'
          ' 5  cmn             --/F      Chinese_(Mandarin) sit/cmn              (zh-cmn 5)(zh 5)\n';
      final List<TtsVoice> voices = parseEspeakNgVoices(out);
      expect(voices.map((TtsVoice v) => v.id), <String>[
        'espeak:en-us',
        'espeak:ja',
        'espeak:cmn',
      ]);
      expect(voices.first.displayName, 'espeak-ng · English (America)');
      expect(voices.last.gender, 'Female');
    });

    test('声音清单：没有 Open JTalk 辞书就不列它的声音', () async {
      final List<TtsVoice> withDic = await listLinuxTtsVoicesWith(
        openJTalk: (dictionaryDir: '/dic', voicePath: '/v/a.htsvoice'),
        listOpenJTalkVoiceFiles: () => <String>[
          '/v/mei_normal.htsvoice',
          '/v/a.htsvoice',
        ],
        espeakVoiceList: () async => null,
      );
      expect(withDic.map((TtsVoice v) => v.id), <String>[
        'openjtalk:/v/a.htsvoice',
        'openjtalk:/v/mei_normal.htsvoice',
      ]);
      expect(withDic.first.locale, 'ja-JP');
      final List<TtsVoice> noDic = await listLinuxTtsVoicesWith(
        openJTalk: null,
        listOpenJTalkVoiceFiles: () => <String>['/v/a.htsvoice'],
        espeakVoiceList: () async =>
            ' 5  ja              --/M      Japanese           jpx/ja\n',
      );
      expect(noDic.map((TtsVoice v) => v.id), <String>['espeak:ja']);
    });

    test('点名 Open JTalk 声音：用那个 .htsvoice；文件不在 = 声音不可用', () async {
      final Directory dir = Directory.systemTemp.createTempSync('fushi_tts_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final List<List<String>> started = <List<String>>[];
      await expectLater(
        synthesizeLinuxTtsForLanguage(
          text: '学生',
          outputPath: '${dir.path}/a.wav',
          languageTag: 'ja',
          openJTalk: (dictionaryDir: '/dic', voicePath: '/v/default.htsvoice'),
          voice: 'openjtalk:/v/gone.htsvoice',
          fileExists: (String path) => false,
          startProcess: (String exe, List<String> args) {
            started.add(args);
            throw ProcessException(exe, args);
          },
        ),
        throwsA(
          isA<SystemTtsFailure>().having(
            (SystemTtsFailure f) => f.reason,
            'reason',
            SystemTtsFailureReason.voiceUnavailable,
          ),
        ),
      );
      expect(started, isEmpty);
      await expectLater(
        synthesizeLinuxTtsForLanguage(
          text: '学生',
          outputPath: '${dir.path}/a.wav',
          languageTag: 'ja',
          openJTalk: (dictionaryDir: '/dic', voicePath: '/v/default.htsvoice'),
          voice: 'openjtalk:/v/mei.htsvoice',
          fileExists: (String path) => true,
          startProcess: (String exe, List<String> args) {
            started.add(<String>[exe, ...args]);
            throw ProcessException(exe, args);
          },
        ),
        throwsA(isA<SystemTtsFailure>()),
      );
      expect(
        started.single,
        containsAllInOrder(<String>['open_jtalk', '-m', '/v/mei.htsvoice']),
      );
    });

    test('点名 espeak-ng 声音：非日语照常念；日语声音仍只读纯假名', () async {
      final Directory dir = Directory.systemTemp.createTempSync('fushi_tts_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final List<List<String>> started = <List<String>>[];
      Future<Process> start(String exe, List<String> args) {
        started.add(<String>[exe, ...args]);
        throw ProcessException(exe, args);
      }

      await expectLater(
        synthesizeLinuxTtsForLanguage(
          text: 'apple',
          outputPath: '${dir.path}/a.wav',
          languageTag: 'en',
          openJTalk: null,
          voice: 'espeak:en-us',
          startProcess: start,
        ),
        throwsA(isA<SystemTtsFailure>()),
      );
      expect(
        started.single,
        containsAllInOrder(<String>['espeak-ng', '-v', 'en-us']),
      );
      started.clear();
      await expectLater(
        synthesizeLinuxTtsForLanguage(
          text: '学生',
          outputPath: '${dir.path}/a.wav',
          languageTag: 'ja',
          openJTalk: null,
          voice: 'espeak:ja',
          startProcess: start,
        ),
        throwsA(isA<SystemTtsFailure>()),
      );
      expect(started, isEmpty, reason: 'espeak-ng 的日语声音念不了汉字');
      await expectLater(
        synthesizeLinuxTtsForLanguage(
          text: 'a',
          outputPath: '${dir.path}/a.wav',
          languageTag: null,
          openJTalk: null,
          voice: 'espeak:en; rm -rf /',
          startProcess: start,
        ),
        throwsA(
          isA<SystemTtsFailure>().having(
            (SystemTtsFailure f) => f.reason,
            'reason',
            SystemTtsFailureReason.voiceUnavailable,
          ),
        ),
      );
    });
  });

  group('系统语音预设', () {
    test('参数表：只有 Android 有「引擎」，声音都是非必填（不选 = 以前的行为）', () {
      final List<TtsParamSpec> android = systemTtsParamSpecs(
        supportsEngineChoice: true,
      );
      expect(android.map((TtsParamSpec s) => s.key), <String>[
        SystemTtsDescriptor.engineKey,
        SystemTtsDescriptor.voiceKey,
      ]);
      expect(
        android.every(
          (TtsParamSpec s) =>
              !s.required && s.kind == TtsParamKind.voice && s.affectsAudio,
        ),
        isTrue,
      );
      expect(
        systemTtsParamSpecs(
          supportsEngineChoice: false,
        ).map((TtsParamSpec s) => s.key),
        <String>[SystemTtsDescriptor.voiceKey],
      );
    });

    test('缓存身份：没选引擎 / 声音时与旧身份逐字相同；换声音换键', () {
      final Map<String, Object?> legacy = systemTtsAudioIdentity(
        <String, Object?>{'provider': 'system', 'revision': 0},
        platform: 'android',
      );
      final Map<String, Object?> unset = systemTtsAudioIdentity(
        <String, Object?>{
          'provider': 'system',
          'revision': 0,
          'engine': '',
          'voice': '',
        },
        platform: 'android',
      );
      expect(unset, legacy);
      final Map<String, Object?> chosen =
          systemTtsAudioIdentity(<String, Object?>{
            'provider': 'system',
            'revision': 0,
            'engine': 'com.iflytek.speechcloud',
            'voice': 'xiaoyan',
          }, platform: 'android');
      expect(chosen['engine'], 'com.iflytek.speechcloud');
      expect(chosen['voice'], 'xiaoyan');
      expect(chosen, isNot(legacy));
    });

    test('预设里的引擎 / 声音交给合成实例', () {
      const TtsVoicePreset preset = TtsVoicePreset(
        id: 'p',
        providerId: SystemTtsDescriptor.providerId,
        name: 'sys',
        params: <String, String>{
          SystemTtsDescriptor.engineKey: ' com.iflytek.speechcloud ',
          SystemTtsDescriptor.voiceKey: 'xiaoyan',
          'voice_name': 'Xiaoyan',
        },
      );
      final SystemTtsProvider provider =
          const SystemTtsDescriptor().create(preset, const TtsHost())
              as SystemTtsProvider;
      expect(provider.engine, 'com.iflytek.speechcloud');
      expect(provider.voice, 'xiaoyan');
    });
  });
}

/// 假的 PowerShell 工作进程：从 `-EncodedCommand` 里取出口令，在回环口上开一个
/// 真 ServerSocket，stdout 报就绪 + 端口；连上后先验口令，再按协议逐行应答。
class _FakeWorkerProcess implements Process {
  _FakeWorkerProcess(this.respond);

  final Map<String, Object?> Function(Map<String, Object?> request) respond;
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
  final List<String> tokensSeen = <String>[];
  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final StreamController<List<int>> _stderr = StreamController<List<int>>();
  final Completer<int> _exit = Completer<int>();
  ServerSocket? _server;

  /// 由 startProcess 回调调用：解析参数、开端口、报就绪。
  Future<_FakeWorkerProcess> launch(List<String> args) async {
    final String encoded = args[args.indexOf('-EncodedCommand') + 1];
    final List<int> bytes = base64Decode(encoded);
    final String script = String.fromCharCodes(<int>[
      for (int i = 0; i + 1 < bytes.length; i += 2)
        bytes[i] | (bytes[i + 1] << 8),
    ]);
    final String token = RegExp(
      r"\$fushiToken = '([0-9a-f]+)'",
    ).firstMatch(script)!.group(1)!;
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    _server = server;
    server.listen((Socket client) {
      bool authed = false;
      client
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((String line) {
            if (!authed) {
              tokensSeen.add(line);
              authed = line == token;
              if (!authed) client.destroy();
              return;
            }
            final Map<String, Object?> req = decodeWindowsSpeechMessage(line)!;
            requests.add(req);
            if (req['op'] == 'exit') return;
            client.write(
              '${encodeWindowsSpeechMessage(<String, Object?>{...respond(req), 'id': req['id']})}\n',
            );
          });
    });
    _stdout.add(
      utf8.encode(
        '#< CLIXML\r\n${encodeWindowsSpeechMessage(<String, Object?>{'id': 0, 'ready': true, 'port': server.port})}\r\n',
      ),
    );
    return this;
  }

  @override
  IOSink get stdin => IOSink(StreamController<List<int>>().sink);

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  int get pid => 1;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exit.isCompleted) {
      _exit.complete(0);
      unawaited(_server?.close());
      unawaited(_stdout.close());
      unawaited(_stderr.close());
    }
    return true;
  }
}
