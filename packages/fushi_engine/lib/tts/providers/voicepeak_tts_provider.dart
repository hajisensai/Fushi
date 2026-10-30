/// VOICEPEAK（AHS 的商用朗读软件）：只有命令行，没有 HTTP 服务。
///
/// `voicepeak -s <text> -n <narrator> -o <out.wav> [-e happy=50,sad=0]
/// [--speed 50..200] [--pitch -300..300]`；`--list-narrator` 列旁白，
/// `--list-emotion <narrator>` 列该旁白的情感。
///
/// - CLI 不能并发（同时起两个会互相踩，实测常见崩溃 / 空文件）：本进程内所有
///   VOICEPEAK 调用经同一把锁串行，[TtsCapabilities.maxConcurrency] 也是 1。
/// - 单次输入上限 140 字（CLI 自己的限制，超了直接报错）。
/// - 付费软件，不代下载：路径由用户装好后填（[detectVoicepeakExecutable] 帮着找）。
/// - 桌面三端；移动端不可用。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/local/local_service_support.dart'
    show LocalCommandRunner, runLocalCommand;
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:fushi_engine/utils/misc/helper_process_registry.dart';
import 'package:path/path.dart' as p;

/// 起 VOICEPEAK 子进程（测试注入假进程）。
typedef VoicepeakProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

/// 默认经 [HelperProcessRegistry] 起：app 退出时一并终止，不留孤儿。
Future<Process> _registryStart(String executable, List<String> arguments) =>
    HelperProcessRegistry.instance.start(executable, arguments);

/// CLI 的单次输入上限（字符数）。
const int kVoicepeakMaxInputLength = 140;

/// 本平台的默认安装位置（Linux 没有固定位置：空串，让用户填）。
String voicepeakDefaultExecutable({
  bool? isWindows,
  bool? isMacOS,
  Map<String, String>? environment,
}) {
  if (isWindows ?? Platform.isWindows) {
    final String programFiles =
        (environment ?? Platform.environment)['ProgramFiles'] ??
        r'C:\Program Files';
    return p.windows.join(programFiles, 'VOICEPEAK', 'voicepeak.exe');
  }
  if (isMacOS ?? Platform.isMacOS) {
    return '/Applications/voicepeak.app/Contents/MacOS/voicepeak';
  }
  return '';
}

/// 找已装的 VOICEPEAK：先看默认安装位置（含 32 位 Program Files、用户级安装），
/// Windows 再翻注册表卸载项（`InstallLocation` / `DisplayIcon`）。找不到返回 null。
Future<String?> detectVoicepeakExecutable({
  LocalCommandRunner? run,
  bool Function(String path)? exists,
  bool? isWindows,
  bool? isMacOS,
  Map<String, String>? environment,
}) async {
  final bool win = isWindows ?? Platform.isWindows;
  final bool mac = isMacOS ?? Platform.isMacOS;
  final bool Function(String) found =
      exists ?? ((String path) => File(path).existsSync());
  final Map<String, String> env = environment ?? Platform.environment;
  final List<String> candidates = <String>[];
  if (win) {
    for (final String? root in <String?>[
      env['ProgramFiles'],
      env['ProgramW6432'],
      env['ProgramFiles(x86)'],
      if (env['LOCALAPPDATA'] != null)
        p.windows.join(env['LOCALAPPDATA']!, 'Programs'),
    ]) {
      if (root != null && root.isNotEmpty) {
        candidates.add(p.windows.join(root, 'VOICEPEAK', 'voicepeak.exe'));
      }
    }
    candidates.add(r'C:\Program Files\VOICEPEAK\voicepeak.exe');
  } else if (mac) {
    candidates.add('/Applications/voicepeak.app/Contents/MacOS/voicepeak');
    final String? home = env['HOME'];
    if (home != null && home.isNotEmpty) {
      candidates.add(
        p.posix.join(
          home,
          'Applications',
          'voicepeak.app',
          'Contents',
          'MacOS',
          'voicepeak',
        ),
      );
    }
  } else {
    final String? home = env['HOME'];
    if (home != null && home.isNotEmpty) {
      candidates.add(p.posix.join(home, 'Voicepeak', 'voicepeak'));
      candidates.add(p.posix.join(home, 'voicepeak', 'voicepeak'));
    }
    candidates.add('/opt/voicepeak/voicepeak');
    candidates.add('/opt/Voicepeak/voicepeak');
  }
  for (final String c in candidates) {
    if (found(c)) return c;
  }
  if (!win) return null;
  final LocalCommandRunner runner = run ?? runLocalCommand;
  for (final String hive in const <String>[
    r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    r'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    r'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
  ]) {
    final ({int exitCode, String output}) r = await runner('reg', <String>[
      'query',
      hive,
      '/s',
      '/f',
      'VOICEPEAK',
      '/d',
    ]);
    if (r.exitCode != 0) continue;
    for (final String keyPath in voicepeakRegistryKeys(r.output)) {
      final ({int exitCode, String output}) values = await runner(
        'reg',
        <String>['query', keyPath],
      );
      if (values.exitCode != 0) continue;
      for (final String c in voicepeakPathsFromRegistryValues(values.output)) {
        if (found(c)) return c;
      }
    }
  }
  return null;
}

/// `reg query ... /f VOICEPEAK /d` 的输出里命中的键路径（`HKEY_...` 开头的行）。
List<String> voicepeakRegistryKeys(String output) => <String>[
  for (final String line in const LineSplitter().convert(output))
    if (line.trim().startsWith('HKEY_')) line.trim(),
];

/// 一个卸载项的值（`reg query <key>` 输出）里可能指向 voicepeak.exe 的路径：
/// `InstallLocation` 拼上 exe 名、`DisplayIcon` 去掉 `,0` 图标序号。
List<String> voicepeakPathsFromRegistryValues(String output) {
  final List<String> paths = <String>[];
  final RegExp row = RegExp(r'^\s*(\S+)\s+REG_(?:EXPAND_)?SZ\s+(.+?)\s*$');
  for (final String line in const LineSplitter().convert(output)) {
    final RegExpMatch? m = row.firstMatch(line);
    if (m == null) continue;
    final String name = m.group(1)!;
    String value = m.group(2)!.replaceAll('"', '');
    if (name == 'InstallLocation' && value.isNotEmpty) {
      paths.add(p.windows.join(value, 'voicepeak.exe'));
    } else if (name == 'DisplayIcon') {
      value = value.replaceFirst(RegExp(r',\s*-?\d+$'), '');
      if (value.toLowerCase().endsWith('voicepeak.exe')) paths.add(value);
    }
  }
  return paths;
}

class VoicepeakTtsDescriptor extends TtsProviderDescriptor {
  const VoicepeakTtsDescriptor({
    this.starter,
    this.available,
    this.synthesisTimeout = const Duration(minutes: 2),
    this.listTimeout = const Duration(seconds: 60),
  });

  static const String providerId = 'voicepeak';
  static const String executableKey = 'executable';
  static const String narratorKey = 'narrator';
  static const String emotionKey = 'emotion';
  static const String speedKey = 'speed';
  static const String pitchKey = 'pitch';

  /// 起子进程的入口；null = 经 [HelperProcessRegistry] 起真进程。
  final VoicepeakProcessStarter? starter;

  /// 覆盖平台判定（测试用）；null = 桌面三端可用。
  final bool? available;
  final Duration synthesisTimeout;
  final Duration listTimeout;

  /// 情感：`名=0..100`，逗号分隔（名字随旁白不同，见 `--list-emotion`）。
  static final RegExp emotionPattern = RegExp(
    r'^\s*[^=,\s]+\s*=\s*\d{1,3}\s*(,\s*[^=,\s]+\s*=\s*\d{1,3}\s*)*$',
  );

  @override
  String get id => providerId;

  @override
  bool get isAvailable =>
      available ?? (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: false,
    needsCredential: false,
    maxConcurrency: 1,
    maxInputLength: kVoicepeakMaxInputLength,
  );

  @override
  List<TtsParamSpec> get params => <TtsParamSpec>[
    TtsParamSpec(
      key: executableKey,
      kind: TtsParamKind.text,
      required: true,
      defaultValue: voicepeakDefaultExecutable(),
      affectsAudio: false,
    ),
    const TtsParamSpec(
      key: narratorKey,
      kind: TtsParamKind.voice,
      required: true,
    ),
    const TtsParamSpec(key: emotionKey, kind: TtsParamKind.text),
    const TtsParamSpec(key: speedKey, kind: TtsParamKind.text),
    const TtsParamSpec(key: pitchKey, kind: TtsParamKind.text),
  ];

  @override
  List<String> validate(TtsVoicePreset preset) {
    final List<String> problems = super.validate(preset);
    bool intIn(String key, int min, int max) {
      final String raw = preset.param(key).trim();
      if (raw.isEmpty) return true;
      final int? v = int.tryParse(raw);
      return v != null && v >= min && v <= max;
    }

    if (!intIn(speedKey, 50, 200)) problems.add(speedKey);
    if (!intIn(pitchKey, -300, 300)) problems.add(pitchKey);
    final String emotion = preset.param(emotionKey).trim();
    if (emotion.isNotEmpty && !voicepeakEmotionValid(emotion)) {
      problems.add(emotionKey);
    }
    return problems;
  }

  /// 情感串合法：格式对、每个值 0..100。
  static bool voicepeakEmotionValid(String raw) {
    if (!emotionPattern.hasMatch(raw)) return false;
    for (final String part in raw.split(',')) {
      final int? v = int.tryParse(part.split('=').last.trim());
      if (v == null || v < 0 || v > 100) return false;
    }
    return true;
  }

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) =>
      VoicepeakTtsProvider(
        executable: preset.param(
          executableKey,
          fallback: voicepeakDefaultExecutable(),
        ),
        narrator: preset.param(narratorKey),
        emotion: preset.param(emotionKey),
        speed: preset.param(speedKey),
        pitch: preset.param(pitchKey),
        starter: starter ?? _registryStart,
        synthesisTimeout: synthesisTimeout,
        listTimeout: listTimeout,
        log: host.log,
      );
}

class VoicepeakTtsProvider extends TtsProvider {
  VoicepeakTtsProvider({
    required String executable,
    required String narrator,
    required String emotion,
    required String speed,
    required String pitch,
    required VoicepeakProcessStarter starter,
    this.synthesisTimeout = const Duration(minutes: 2),
    this.listTimeout = const Duration(seconds: 60),
    void Function(String message)? log,
  }) : executable = executable.trim(),
       narrator = narrator.trim(),
       emotion = emotion.trim(),
       speed = speed.trim(),
       pitch = pitch.trim(),
       _start = starter,
       _log = log;

  final String executable;
  final String narrator;
  final String emotion;
  final String speed;
  final String pitch;
  final Duration synthesisTimeout;
  final Duration listTimeout;
  final VoicepeakProcessStarter _start;
  final void Function(String message)? _log;

  /// 本进程内所有 VOICEPEAK 调用排成一队（CLI 不能并发）。
  static Future<void> _queue = Future<void>.value();

  @override
  TtsCapabilities get capabilities =>
      const VoicepeakTtsDescriptor().capabilities;

  /// 合成用的命令行（纯函数，测试直接调）。换行 / 控制字符换成空格；以 `-` 开头的
  /// 文本前补一个空格，免得被 CLI 当成选项。
  List<String> synthesisArguments(String text, String outputPath) {
    String say = text.replaceAll(RegExp(r'[\u0000-\u001f\u007f]+'), ' ').trim();
    if (say.startsWith('-')) say = ' $say';
    return <String>[
      '-s',
      say,
      '-n',
      narrator,
      '-o',
      outputPath,
      if (emotion.isNotEmpty) ...<String>['-e', emotion.replaceAll(' ', '')],
      if (speed.isNotEmpty) ...<String>['--speed', speed],
      if (pitch.isNotEmpty) ...<String>['--pitch', pitch],
    ];
  }

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    if (executable.isEmpty || narrator.isEmpty) {
      throw const TtsFailure(TtsFailureCode.notConfigured);
    }
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const TtsFailure(TtsFailureCode.rejected, 'empty');
    }
    if (trimmed.length > kVoicepeakMaxInputLength) {
      throw const TtsFailure(TtsFailureCode.rejected, 'too long');
    }
    cancel.throwIfCancelled();
    await _serialized(cancel, () async {
      final File out = File(outputPath);
      try {
        if (out.existsSync()) out.deleteSync();
      } on FileSystemException {
        // 删不掉就让 CLI 覆盖；下面按产物长度判成败。
      }
      await _run(
        synthesisArguments(trimmed, outputPath),
        cancel: cancel,
        timeout: synthesisTimeout,
      );
      final int length = out.existsSync() ? out.lengthSync() : 0;
      if (length == 0) {
        throw const TtsFailure.withRetry(
          TtsFailureCode.badResponse,
          detail: 'no output',
          transient: true,
        );
      }
    });
    return const TtsResult(format: TtsAudioFormat.wav);
  }

  @override
  Future<List<TtsVoice>> listVoices({TtsCancelToken? cancel}) async {
    if (executable.isEmpty) {
      throw const TtsFailure(TtsFailureCode.notConfigured);
    }
    final String output = await _serialized(
      cancel,
      () => _run(
        const <String>['--list-narrator'],
        cancel: cancel,
        timeout: listTimeout,
      ),
    );
    return <TtsVoice>[
      for (final String name in parseVoicepeakList(output))
        TtsVoice(id: name, displayName: name, locale: 'ja-JP'),
    ];
  }

  /// [narrator] 的可选情感名（`--list-emotion`）。
  Future<List<String>> listEmotions(
    String narrator, {
    TtsCancelToken? cancel,
  }) async {
    if (executable.isEmpty) {
      throw const TtsFailure(TtsFailureCode.notConfigured);
    }
    final String output = await _serialized(
      cancel,
      () => _run(
        <String>['--list-emotion', narrator.trim()],
        cancel: cancel,
        timeout: listTimeout,
      ),
    );
    return parseVoicepeakList(output);
  }

  /// 排队拿锁后跑 [body]。排队期间取消立刻抛 cancelled，但队尾仍等前一个跑完才放行
  /// 后来者（不能因为某个等待者取消就让两个 CLI 同时跑）。
  static Future<T> _serialized<T>(
    TtsCancelToken? cancel,
    Future<T> Function() body,
  ) async {
    final Future<void> previous = _queue;
    final Completer<void> mine = Completer<void>();
    _queue = mine.future;
    bool acquired = false;
    try {
      if (cancel == null) {
        await previous;
      } else {
        final Completer<void> cancelled = Completer<void>();
        final void Function() unregister = cancel.onCancel(() {
          if (!cancelled.isCompleted) cancelled.complete();
        });
        try {
          await Future.any(<Future<void>>[previous, cancelled.future]);
        } finally {
          unregister();
        }
        cancel.throwIfCancelled();
      }
      acquired = true;
      return await body();
    } finally {
      if (acquired) {
        mine.complete();
      } else {
        unawaited(previous.whenComplete(mine.complete));
      }
    }
  }

  /// 跑一次 CLI，返回 stdout。失败映射：起不来 → notConfigured；取消 → cancelled
  /// （杀进程）；超时 → timeout（杀进程）；非零退出 → badResponse（CLI 偶发启动失败，
  /// 按临时失败交给重试层）。
  Future<String> _run(
    List<String> arguments, {
    required TtsCancelToken? cancel,
    required Duration timeout,
  }) async {
    cancel?.throwIfCancelled();
    final Process process;
    try {
      process = await _start(executable, arguments);
    } on ProcessException catch (e) {
      _log?.call('VOICEPEAK spawn failed: ${e.errorCode}');
      throw const TtsFailure(TtsFailureCode.notConfigured, 'spawn');
    }
    final StringBuffer stdout = StringBuffer();
    final StringBuffer stderr = StringBuffer();
    final Future<void> outDone = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((String s) {
          if (stdout.length < 256 * 1024) stdout.write(s);
        })
        .asFuture<void>()
        .catchError((Object _) {});
    final Future<void> errDone = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((String s) {
          if (stderr.length < 16 * 1024) stderr.write(s);
        })
        .asFuture<void>()
        .catchError((Object _) {});
    final Completer<String> stop = Completer<String>();
    final void Function()? unregister = cancel?.onCancel(() {
      if (!stop.isCompleted) stop.complete('cancelled');
    });
    final Timer timer = Timer(timeout, () {
      if (!stop.isCompleted) stop.complete('timeout');
    });
    try {
      final Object outcome = await Future.any<Object>(<Future<Object>>[
        process.exitCode,
        stop.future,
      ]);
      if (outcome is String) {
        process.kill();
        // 等它真退出（Windows 上句柄回收前输出文件还被占着），但不无限等。
        await process.exitCode
            .timeout(const Duration(seconds: 5))
            .catchError((Object _) => -1);
        throw outcome == 'cancelled'
            ? const TtsFailure(TtsFailureCode.cancelled)
            : const TtsFailure(TtsFailureCode.timeout);
      }
      final int code = outcome as int;
      await Future.wait(<Future<void>>[
        outDone,
        errDone,
      ]).timeout(const Duration(seconds: 5), onTimeout: () => <void>[]);
      if (code != 0) {
        _log?.call('VOICEPEAK exited with $code');
        throw TtsFailure.withRetry(
          TtsFailureCode.badResponse,
          detail: 'exit $code',
          transient: true,
        );
      }
      return stdout.toString();
    } finally {
      timer.cancel();
      unregister?.call();
    }
  }
}

/// `--list-narrator` / `--list-emotion` 的输出：一行一个名字（去空白、去空行）。
List<String> parseVoicepeakList(String output) => <String>[
  for (final String line in const LineSplitter().convert(output))
    if (line.trim().isNotEmpty) line.trim(),
];
