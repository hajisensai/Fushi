import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/desktop_tts.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

void main() {
  group('resolveOpenJTalkAssets', () {
    OpenJTalkAssets? resolve({
      Map<String, String> environment = const <String, String>{},
      Set<String> dirs = const <String>{},
      Set<String> files = const <String>{},
      Map<String, List<String>> voices = const <String, List<String>>{},
    }) => resolveOpenJTalkAssets(
      environment: environment,
      directoryExists: dirs.contains,
      fileExists: files.contains,
      listVoiceFiles: (String dir) =>
          List<String>.of(voices[dir] ?? const <String>[]),
    );

    test('Debian/Ubuntu 包的标准落点', () {
      const String dic = '/var/lib/mecab/dic/open-jtalk/naist-jdic';
      const String voice =
          '/usr/share/hts-voice/nitech-jp-atr503-m001/nitech_jp_atr503_m001.htsvoice';
      expect(
        resolve(
          dirs: <String>{dic, '/usr/share/hts-voice'},
          voices: <String, List<String>>{
            '/usr/share/hts-voice': <String>[voice],
          },
        ),
        (dictionaryDir: dic, voicePath: voice),
      );
    });

    test('多个声音时取排序后的第一个（结果稳定）', () {
      const String dic = '/usr/share/open-jtalk/dic';
      expect(
        resolve(
          dirs: <String>{dic, '/usr/share/open-jtalk/voices'},
          voices: <String, List<String>>{
            '/usr/share/open-jtalk/voices': <String>[
              '/usr/share/open-jtalk/voices/mei_normal.htsvoice',
              '/usr/share/open-jtalk/voices/mei_angry.htsvoice',
            ],
          },
        )?.voicePath,
        '/usr/share/open-jtalk/voices/mei_angry.htsvoice',
      );
    });

    test('缺辞书或缺声音都判没装', () {
      expect(
        resolve(
          dirs: <String>{'/usr/share/hts-voice'},
          voices: <String, List<String>>{
            '/usr/share/hts-voice': <String>['/usr/share/hts-voice/a.htsvoice'],
          },
        ),
        isNull,
      );
      expect(
        resolve(dirs: <String>{'/var/lib/mecab/dic/open-jtalk/naist-jdic'}),
        isNull,
      );
    });

    test('环境变量点名的路径优先；点名的不存在就不换别的', () {
      const Map<String, String> env = <String, String>{
        'FUSHI_OPEN_JTALK_DIC': '/opt/dic',
        'FUSHI_OPEN_JTALK_VOICE': '/opt/v.htsvoice',
      };
      expect(
        resolve(
          environment: env,
          dirs: <String>{
            '/opt/dic',
            '/var/lib/mecab/dic/open-jtalk/naist-jdic',
          },
          files: <String>{'/opt/v.htsvoice'},
        ),
        (dictionaryDir: '/opt/dic', voicePath: '/opt/v.htsvoice'),
      );
      expect(
        resolve(
          environment: env,
          dirs: <String>{'/var/lib/mecab/dic/open-jtalk/naist-jdic'},
          files: <String>{'/opt/v.htsvoice'},
        ),
        isNull,
      );
    });
  });

  group('isKanaOnlyText', () {
    test('假名（含长音、标点、全半角空格）', () {
      expect(isKanaOnlyText('にほんご'), isTrue);
      expect(isKanaOnlyText('コーヒー、ください。'), isTrue);
      expect(isKanaOnlyText(' ｶﾀｶﾅ '), isTrue);
    });

    test('带汉字 / 拉丁字母 / 空文本一律否', () {
      expect(isKanaOnlyText('日本語'), isFalse);
      expect(isKanaOnlyText('たべ物'), isFalse);
      expect(isKanaOnlyText('abc'), isFalse);
      expect(isKanaOnlyText('、。'), isFalse);
      expect(isKanaOnlyText('  '), isFalse);
    });
  });

  // BUG-3092：读音里常见的符号要收，espeak-ng 念成 "Japanese letter" 的要拒。
  // 判据来自 espeak-ng 1.51 `-v ja -q -x` 的音素输出实测。
  group('isKanaOnlyText 符号', () {
    test('波浪长音、全角波浪、省略号、括号、半角标点都收', () {
      expect(isKanaOnlyText('え〜と'), isTrue);
      expect(isKanaOnlyText('すご～い'), isTrue);
      expect(isKanaOnlyText('あの…'), isTrue);
      expect(isKanaOnlyText('ええ‥'), isTrue);
      expect(isKanaOnlyText('「ほん」『ほん』'), isTrue);
      expect(isKanaOnlyText('ｶﾀｶﾅｰ｡'), isTrue);
      expect(isKanaOnlyText('ﾎﾝ･ﾎﾝ'), isTrue);
    });

    test('中点・与片假名音标扩展拒收（espeak-ng 念成英语字母名）', () {
      expect(isKanaOnlyText('にほんご・えいご'), isFalse);
      expect(isKanaOnlyText('ㇰㇱ'), isFalse);
      expect(isKanaOnlyText('かㇷ'), isFalse);
    });

    test('只有符号没有假名仍是否；ASCII 波浪号仍拒（espeak-ng 念 tilde）', () {
      expect(isKanaOnlyText('〜…'), isFalse);
      expect(isKanaOnlyText('ほん~'), isFalse);
    });
  });

  // BUG-3088：外部 TTS 进程卡住 / stdin EPIPE 都按该引擎失败处理，继续兜底。
  group('runLinuxTtsProcess / synthesizeLinuxTts', () {
    late Directory dir;
    late String out;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('fushi_tts_fake_');
      out = '${dir.path}/term.wav';
    });

    tearDown(() async {
      await ErrorLogService.instance.pendingFileWrite;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    const Duration shortTimeout = Duration(milliseconds: 200);

    test('正常：文本经 stdin 送入，产出文件即成功', () async {
      final _FakeTtsProcess process = _FakeTtsProcess.ok(out);
      final String? result = await runLinuxTtsProcess(
        executable: 'espeak-ng',
        arguments: const <String>['--stdin'],
        text: 'にほんご',
        outputPath: out,
        logTag: 'test',
        startProcess: (String _, List<String> __) async => process,
        timeout: shortTimeout,
      );
      expect(result, out);
      expect(utf8.decode(process.stdinBytes), 'にほんご');
      expect(process.killedWith, isNull);
    });

    test('卡住：到上界 SIGKILL 并返回 null，不会永远挂起', () async {
      final _FakeTtsProcess process = _FakeTtsProcess.hang(out);
      final Stopwatch watch = Stopwatch()..start();
      final String? result = await runLinuxTtsProcess(
        executable: 'open_jtalk',
        arguments: const <String>[],
        text: '日本語\n',
        outputPath: out,
        logTag: 'test',
        startProcess: (String _, List<String> __) async => process,
        timeout: shortTimeout,
      );
      expect(result, isNull);
      expect(process.killedWith, ProcessSignal.sigkill);
      expect(File(out).existsSync(), isFalse, reason: '半截产物要删掉');
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('stdin EPIPE：按该引擎失败返回 null，不抛出', () async {
      final _FakeTtsProcess process = _FakeTtsProcess.brokenPipe(out);
      final String? result = await runLinuxTtsProcess(
        executable: 'open_jtalk',
        arguments: const <String>[],
        text: '日本語\n',
        outputPath: out,
        logTag: 'test',
        startProcess: (String _, List<String> __) async => process,
        timeout: shortTimeout,
      );
      expect(result, isNull);
      expect(process.killedWith, ProcessSignal.sigkill);
    });

    test('没装引擎（ProcessException）返回 null', () async {
      final String? result = await runLinuxTtsProcess(
        executable: 'espeak-ng',
        arguments: const <String>[],
        text: 'にほんご',
        outputPath: out,
        logTag: 'test',
        startProcess: (String executable, List<String> _) async =>
            throw ProcessException(executable, const <String>[]),
        timeout: shortTimeout,
      );
      expect(result, isNull);
    });

    Future<(String?, List<String>)> synthesize({
      required String text,
      required _FakeTtsProcess Function() openJTalk,
    }) async {
      final List<String> started = <String>[];
      final String? result = await synthesizeLinuxTts(
        text: text,
        outputPath: out,
        openJTalk: (dictionaryDir: '/dic', voicePath: '/v.htsvoice'),
        processTimeout: shortTimeout,
        startProcess: (String executable, List<String> _) async {
          started.add(executable);
          return executable == 'open_jtalk'
              ? openJTalk()
              : _FakeTtsProcess.ok(out);
        },
      );
      return (result, started);
    }

    test('open_jtalk 卡住 → 假名文本照样落到 espeak-ng', () async {
      final (String? result, List<String> started) = await synthesize(
        text: 'にほんご',
        openJTalk: () => _FakeTtsProcess.hang(out),
      );
      expect(started, <String>['open_jtalk', 'espeak-ng']);
      expect(result, out);
    });

    test('open_jtalk stdin EPIPE → 假名文本照样落到 espeak-ng', () async {
      final (String? result, List<String> started) = await synthesize(
        text: 'にほんご',
        openJTalk: () => _FakeTtsProcess.brokenPipe(out),
      );
      expect(started, <String>['open_jtalk', 'espeak-ng']);
      expect(result, out);
    });

    test('open_jtalk 失败 + 带汉字：不交给 espeak-ng，返回 null', () async {
      final (String? result, List<String> started) = await synthesize(
        text: '日本語',
        openJTalk: () => _FakeTtsProcess.hang(out),
      );
      expect(started, <String>['open_jtalk']);
      expect(result, isNull);
    });
  });

  // 同一条路径换成真实子进程：真的 EPIPE、真的卡死（POSIX sh）。
  group('runLinuxTtsProcess 真实子进程', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('fushi_tts_proc_'));
    tearDown(() async {
      await ErrorLogService.instance.pendingFileWrite;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('引擎不读 stdin 就退出（EPIPE）：返回 null，不抛', () async {
      final String? result = await runLinuxTtsProcess(
        executable: 'sh',
        arguments: const <String>['-c', 'exec 0<&-; exit 3'],
        // 远超管道缓冲，保证写端撞上已关闭的读端。
        text: 'あ' * (1 << 20),
        outputPath: '${dir.path}/a.wav',
        logTag: 'test',
        timeout: const Duration(seconds: 10),
      );
      expect(result, isNull);
    });

    test('引擎卡死：到上界被杀，返回 null', () async {
      final Stopwatch watch = Stopwatch()..start();
      final String? result = await runLinuxTtsProcess(
        executable: 'sh',
        arguments: const <String>['-c', 'cat >/dev/null; exec sleep 30'],
        text: 'にほんご',
        outputPath: '${dir.path}/a.wav',
        logTag: 'test',
        timeout: const Duration(milliseconds: 500),
      );
      expect(result, isNull);
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    });
  }, skip: Platform.isWindows ? 'needs POSIX sh' : false);

  // 装了 Open JTalk（可执行文件 + 辞书 + 声音）的 Linux 机器上跑真引擎：读汉字词
  // 也要产出非空 WAV。只判可执行文件在 PATH 不够——缺辞书 / 声音时生产路径根本不会
  // 调 open_jtalk，这条会误红（BUG-3091）。判据与生产路径同一处。
  final bool hasOpenJTalk =
      Platform.isLinux &&
      Process.runSync('sh', <String>['-c', 'command -v open_jtalk']).exitCode ==
          0 &&
      resolveSystemOpenJTalkAssets() != null;
  test(
    'Linux 真引擎：汉字词合成出 WAV',
    () async {
      final Directory dir = Directory.systemTemp.createTempSync('fushi_tts_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String out = '${dir.path}/term.wav';
      final String? result = await ttsToFileDesktop(
        text: '日本語',
        outputPath: out,
      );
      expect(result, out);
      final List<int> header = File(out).readAsBytesSync().sublist(0, 4);
      expect(String.fromCharCodes(header), 'RIFF');
    },
    skip: hasOpenJTalk
        ? false
        : 'open_jtalk with dictionary and voice not installed',
  );
}

/// stdin 的落点：正常收下字节；[error] 非空时模拟引擎已退出（写管道 EPIPE）。
class _StdinConsumer implements StreamConsumer<List<int>> {
  _StdinConsumer({this.error, this.onClosed});

  final SocketException? error;
  final void Function()? onClosed;
  final List<int> bytes = <int>[];

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    if (error != null) {
      await stream.drain<void>();
      throw error!;
    }
    await for (final List<int> chunk in stream) {
      bytes.addAll(chunk);
    }
  }

  @override
  Future<void> close() async {
    if (error == null) onClosed?.call();
  }
}

/// 可控的假 TTS 进程：正常合成 / 卡死 / stdin 断管三种。
class _FakeTtsProcess implements Process {
  _FakeTtsProcess._(this._consumer) : stdin = IOSink(_consumer);

  /// 读完 stdin 写出一个 WAV 头并以 0 退出。
  factory _FakeTtsProcess.ok(String outputPath) {
    late final _FakeTtsProcess process;
    process = _FakeTtsProcess._(
      _StdinConsumer(
        onClosed: () {
          File(outputPath).writeAsBytesSync(ascii.encode('RIFF0000WAVE'));
          process._finish(0);
        },
      ),
    );
    return process;
  }

  /// 收下 stdin 后既不输出也不退出，直到被 kill。还先写半截产物。
  factory _FakeTtsProcess.hang(String outputPath) {
    File(outputPath).writeAsBytesSync(ascii.encode('RI'));
    return _FakeTtsProcess._(_StdinConsumer());
  }

  /// 引擎一启动就退出（缺辞书等），写 stdin 撞上 EPIPE。
  factory _FakeTtsProcess.brokenPipe(String outputPath) {
    final _FakeTtsProcess process = _FakeTtsProcess._(
      _StdinConsumer(
        error: const SocketException(
          'Write failed',
          osError: OSError('Broken pipe', 32),
        ),
      ),
    );
    process._finish(1);
    return process;
  }

  final _StdinConsumer _consumer;
  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final StreamController<List<int>> _stderr = StreamController<List<int>>();
  final Completer<int> _exitCode = Completer<int>();
  ProcessSignal? killedWith;

  List<int> get stdinBytes => _consumer.bytes;

  void _finish(int code) {
    if (_exitCode.isCompleted) return;
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    _exitCode.complete(code);
  }

  @override
  final IOSink stdin;

  @override
  int get pid => 4242;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killedWith = signal;
    _finish(-9);
    return true;
  }
}
