import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/providers/voicepeak_tts_provider.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

/// 可编排的假 CLI 进程：写 stdout、按需写输出文件、可挂起直到被杀。
class _FakeProcess implements Process {
  _FakeProcess({required this.args});

  final List<String> args;
  final Completer<int> _exit = Completer<int>();
  final StreamController<List<int>> _out = StreamController<List<int>>();
  final StreamController<List<int>> _err = StreamController<List<int>>();
  bool killed = false;

  void finish(int code, {String stdout = ''}) {
    if (stdout.isNotEmpty) _out.add(utf8.encode(stdout));
    unawaited(_out.close());
    unawaited(_err.close());
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    finish(-1);
    return true;
  }

  @override
  Future<int> get exitCode => _exit.future;

  @override
  int get pid => 4242;

  @override
  Stream<List<int>> get stdout => _out.stream;

  @override
  Stream<List<int>> get stderr => _err.stream;

  @override
  IOSink get stdin => throw UnimplementedError();
}

void main() {
  late Directory tmp;
  final List<_FakeProcess> spawned = <_FakeProcess>[];
  final List<String> executables = <String>[];

  /// 每次起进程时的行为：默认写出 wav 并退出 0。
  late Future<void> Function(_FakeProcess) behaviour;
  bool spawnFails = false;
  int active = 0;
  int maxActive = 0;

  Future<Process> starter(String exe, List<String> args) async {
    if (spawnFails) throw ProcessException(exe, args, 'not found', 2);
    executables.add(exe);
    final _FakeProcess proc = _FakeProcess(args: args);
    spawned.add(proc);
    active++;
    if (active > maxActive) maxActive = active;
    unawaited(proc.exitCode.whenComplete(() => active--));
    unawaited(behaviour(proc));
    return proc;
  }

  Future<void> writeWavAndExit(_FakeProcess proc) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final int at = proc.args.indexOf('-o');
    await File(proc.args[at + 1]).writeAsBytes(buildWav());
    proc.finish(0);
  }

  setUp(() async {
    spawned.clear();
    executables.clear();
    spawnFails = false;
    active = 0;
    maxActive = 0;
    behaviour = writeWavAndExit;
    tmp = await Directory.systemTemp.createTemp('tts_voicepeak_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  VoicepeakTtsDescriptor descriptor({
    Duration timeout = const Duration(minutes: 2),
  }) => VoicepeakTtsDescriptor(
    starter: starter,
    available: true,
    synthesisTimeout: timeout,
  );

  TtsVoicePreset preset({
    String exe = '/opt/voicepeak/voicepeak',
    String narrator = 'Japanese Female 1',
    Map<String, String> extra = const <String, String>{},
  }) => TtsVoicePreset(
    id: 'p',
    providerId: VoicepeakTtsDescriptor.providerId,
    name: 'n',
    params: <String, String>{
      VoicepeakTtsDescriptor.executableKey: exe,
      VoicepeakTtsDescriptor.narratorKey: narrator,
      ...extra,
    },
  );

  Future<TtsResult> synth(
    TtsVoicePreset preset, {
    String text = '吾輩は猫である',
    String name = 'out.wav',
    TtsCancelToken? cancel,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final TtsProvider provider = descriptor(
      timeout: timeout,
    ).create(preset, const TtsHost());
    try {
      return await provider.synthesize(
        text,
        outputPath: p.join(tmp.path, name),
        cancel: cancel ?? TtsCancelToken(),
      );
    } finally {
      await provider.dispose();
    }
  }

  Matcher failsWith(TtsFailureCode code) =>
      throwsA(isA<TtsFailure>().having((TtsFailure f) => f.code, 'code', code));

  test('capabilities: offline, serial, 140 chars, desktop-only', () {
    const VoicepeakTtsDescriptor d = VoicepeakTtsDescriptor();
    expect(d.id, 'voicepeak');
    expect(d.capabilities.online, isFalse);
    expect(d.capabilities.maxConcurrency, 1);
    expect(d.capabilities.maxInputLength, 140);
    expect(const VoicepeakTtsDescriptor(available: false).isAvailable, isFalse);
    expect(
      d.params.firstWhere((TtsParamSpec s) => s.key == 'narrator').kind,
      TtsParamKind.voice,
    );
    expect(
      d.params
          .firstWhere((TtsParamSpec s) => s.key == 'executable')
          .affectsAudio,
      isFalse,
    );
  });

  test('default executable per platform', () {
    expect(
      voicepeakDefaultExecutable(
        isWindows: true,
        isMacOS: false,
        environment: <String, String>{'ProgramFiles': r'D:\Apps'},
      ),
      r'D:\Apps\VOICEPEAK\voicepeak.exe',
    );
    expect(
      voicepeakDefaultExecutable(isWindows: false, isMacOS: true),
      '/Applications/voicepeak.app/Contents/MacOS/voicepeak',
    );
    expect(voicepeakDefaultExecutable(isWindows: false, isMacOS: false), '');
  });

  test('validate: speed / pitch ranges and emotion format', () {
    final VoicepeakTtsDescriptor d = descriptor();
    expect(d.validate(preset()), isEmpty);
    expect(d.validate(preset(narrator: '')), <String>['narrator']);
    expect(
      d.validate(
        preset(
          extra: <String, String>{
            'speed': '201',
            'pitch': '-301',
            'emotion': 'happy=50,sad',
          },
        ),
      ),
      <String>['speed', 'pitch', 'emotion'],
    );
    expect(
      d.validate(
        preset(
          extra: <String, String>{
            'speed': '50',
            'pitch': '300',
            'emotion': 'happy=50, sad=0',
          },
        ),
      ),
      isEmpty,
    );
    expect(
      d.validate(preset(extra: <String, String>{'emotion': 'happy=101'})),
      <String>['emotion'],
    );
  });

  test('command line: text, narrator, output, emotion, speed, pitch', () async {
    final TtsResult result = await synth(
      preset(
        extra: <String, String>{
          'emotion': 'happy=50, sad=0',
          'speed': '120',
          'pitch': '-50',
        },
      ),
      text: '吾輩は\n猫である',
    );
    expect(result.format, TtsAudioFormat.wav);
    expect(executables.single, '/opt/voicepeak/voicepeak');
    expect(spawned.single.args, <String>[
      '-s',
      '吾輩は 猫である',
      '-n',
      'Japanese Female 1',
      '-o',
      p.join(tmp.path, 'out.wav'),
      '-e',
      'happy=50,sad=0',
      '--speed',
      '120',
      '--pitch',
      '-50',
    ]);
  });

  test(
    'optional flags are omitted when empty; leading dash is padded',
    () async {
      await synth(preset(), text: '-にゃん');
      expect(spawned.single.args, <String>[
        '-s',
        ' -にゃん',
        '-n',
        'Japanese Female 1',
        '-o',
        p.join(tmp.path, 'out.wav'),
      ]);
    },
  );

  test('over 140 characters is rejected without spawning', () async {
    await expectLater(
      synth(preset(), text: 'あ' * 141),
      failsWith(TtsFailureCode.rejected),
    );
    await synth(preset(), text: 'あ' * 140);
    expect(spawned, hasLength(1));
  });

  test('missing executable / narrator is notConfigured', () async {
    await expectLater(
      synth(preset(narrator: ' ')),
      failsWith(TtsFailureCode.notConfigured),
    );
    spawnFails = true;
    await expectLater(synth(preset()), failsWith(TtsFailureCode.notConfigured));
  });

  test(
    'non-zero exit and missing output map to transient badResponse',
    () async {
      behaviour = (_FakeProcess proc) async => proc.finish(3);
      await expectLater(
        synth(preset()),
        throwsA(
          isA<TtsFailure>()
              .having(
                (TtsFailure f) => f.code,
                'code',
                TtsFailureCode.badResponse,
              )
              .having((TtsFailure f) => f.detail, 'detail', 'exit 3')
              .having((TtsFailure f) => f.isTransient, 'transient', isTrue),
        ),
      );
      behaviour = (_FakeProcess proc) async => proc.finish(0);
      await expectLater(synth(preset()), failsWith(TtsFailureCode.badResponse));
    },
  );

  test('cancel kills the running process', () async {
    behaviour = (_FakeProcess proc) async {};
    final TtsCancelToken token = TtsCancelToken();
    final Future<TtsResult> future = synth(preset(), cancel: token);
    await waitFor(() => spawned.isNotEmpty);
    token.cancel();
    await expectLater(
      future.timeout(const Duration(seconds: 5)),
      failsWith(TtsFailureCode.cancelled),
    );
    expect(spawned.single.killed, isTrue);
  });

  test('timeout kills the running process', () async {
    behaviour = (_FakeProcess proc) async {};
    await expectLater(
      synth(preset(), timeout: const Duration(milliseconds: 100)),
      failsWith(TtsFailureCode.timeout),
    );
    expect(spawned.single.killed, isTrue);
  });

  test('calls are serialised across provider instances', () async {
    final List<Future<TtsResult>> all = <Future<TtsResult>>[
      for (int i = 0; i < 4; i++) synth(preset(), name: 'o$i.wav'),
    ];
    await Future.wait(all);
    expect(spawned, hasLength(4));
    expect(maxActive, 1);
  });

  test(
    'cancel while queued never spawns and does not break the queue',
    () async {
      final Completer<void> gate = Completer<void>();
      behaviour = (_FakeProcess proc) async {
        await gate.future;
        await writeWavAndExit(proc);
      };
      final Future<TtsResult> first = synth(preset(), name: 'a.wav');
      await waitFor(() => spawned.length == 1);
      final TtsCancelToken token = TtsCancelToken();
      final Future<TtsResult> queued = synth(
        preset(),
        name: 'b.wav',
        cancel: token,
      );
      final Future<TtsResult> third = synth(preset(), name: 'c.wav');
      token.cancel();
      await expectLater(queued, failsWith(TtsFailureCode.cancelled));
      await settle();
      expect(spawned, hasLength(1)); // 第三个仍在等第一个
      gate.complete();
      await first;
      await third;
      expect(spawned, hasLength(2));
      expect(maxActive, 1);
    },
  );

  test('listVoices / listEmotions parse one name per line', () async {
    behaviour = (_FakeProcess proc) async => proc.finish(
      0,
      stdout: proc.args.first == '--list-narrator'
          ? 'Japanese Male 1\r\nJapanese Female 1\n\n'
          : 'happy\nfun\nangry\nsad\n',
    );
    final VoicepeakTtsProvider provider =
        descriptor().create(preset(), const TtsHost()) as VoicepeakTtsProvider;
    final List<TtsVoice> voices = await provider.listVoices();
    expect(voices.map((TtsVoice v) => v.id), <String>[
      'Japanese Male 1',
      'Japanese Female 1',
    ]);
    expect(await provider.listEmotions('Japanese Male 1'), <String>[
      'happy',
      'fun',
      'angry',
      'sad',
    ]);
    expect(spawned.last.args, <String>['--list-emotion', 'Japanese Male 1']);
  });

  group('detectVoicepeakExecutable', () {
    test('finds the default install location first', () async {
      final String? found = await detectVoicepeakExecutable(
        isWindows: true,
        isMacOS: false,
        environment: <String, String>{'ProgramFiles': r'C:\Program Files'},
        exists: (String path) =>
            path == r'C:\Program Files\VOICEPEAK\voicepeak.exe',
        run: (String exe, List<String> args) async =>
            fail('registry should not be queried'),
      );
      expect(found, r'C:\Program Files\VOICEPEAK\voicepeak.exe');
    });

    test('falls back to the uninstall registry entry', () async {
      const String key =
          r'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{ABC}';
      final String? found = await detectVoicepeakExecutable(
        isWindows: true,
        isMacOS: false,
        environment: const <String, String>{},
        exists: (String path) => path == r'E:\Tools\VOICEPEAK\voicepeak.exe',
        run: (String exe, List<String> args) async {
          expect(exe, 'reg');
          if (args.contains('/f')) {
            return args[1].startsWith(r'HKLM\SOFTWARE\Microsoft')
                ? (
                    exitCode: 0,
                    output:
                        '\r\n$key\r\n    DisplayName    REG_SZ    VOICEPEAK\r\n',
                  )
                : (exitCode: 1, output: '');
          }
          expect(args, <String>['query', key]);
          return (
            exitCode: 0,
            output:
                '$key\r\n'
                '    DisplayName    REG_SZ    VOICEPEAK\r\n'
                '    DisplayIcon    REG_SZ    "E:\\Tools\\VOICEPEAK\\voicepeak.exe",0\r\n',
          );
        },
      );
      expect(found, r'E:\Tools\VOICEPEAK\voicepeak.exe');
    });

    test('registry value parsing (InstallLocation / DisplayIcon)', () {
      expect(
        voicepeakPathsFromRegistryValues(
          '    InstallLocation    REG_SZ    D:\\VP\r\n'
          '    DisplayIcon    REG_SZ    D:\\VP\\voicepeak.exe,0\r\n'
          '    DisplayIcon    REG_SZ    D:\\VP\\uninstall.exe\r\n',
        ),
        <String>[r'D:\VP\voicepeak.exe', r'D:\VP\voicepeak.exe'],
      );
    });

    test('macOS: /Applications, else null', () async {
      expect(
        await detectVoicepeakExecutable(
          isWindows: false,
          isMacOS: true,
          environment: const <String, String>{},
          exists: (String path) =>
              path == '/Applications/voicepeak.app/Contents/MacOS/voicepeak',
        ),
        '/Applications/voicepeak.app/Contents/MacOS/voicepeak',
      );
      expect(
        await detectVoicepeakExecutable(
          isWindows: false,
          isMacOS: true,
          environment: const <String, String>{},
          exists: (String _) => false,
        ),
        isNull,
      );
    });
  });
}
