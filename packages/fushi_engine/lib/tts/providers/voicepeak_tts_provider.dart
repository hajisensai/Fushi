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
///
/// 逐句语气（[TtsDirectedSynthesis]，见 [VoicepeakTtsProvider.synthesisArguments]）：
/// - 情绪原生：标注的情绪按 [kVoicepeakEmotionNames] 译成该旁白 `--list-emotion`
///   里真有的情感名，`-e 名=强度` 逐句下发；旁白没有对应情感（或情绪不在表里）就把
///   情绪按 [ttsEmotionProsody] 折成语速偏移。
/// - 语速：`--speed` 是百分比（100 = 原速，CLI 帮助写 50..200），逐句乘在预设上。
/// - 音高**不声明**：`--pitch -300..300` 的单位（音分？）CLI 与公开资料都没写，换算
///   无从核实，宁可不调也不乱调；音量 CLI 没有参数。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/cast/cast_line_direction.dart';
import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/local/local_service_support.dart'
    show LocalCommandRunner, runLocalCommand;
import 'package:fushi_engine/tts/tts_direction.dart';
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

/// `--speed` 的范围（CLI 帮助 `Speed (50 - 200)`，100 = 原速）。
const int kVoicepeakMinSpeed = 50;
const int kVoicepeakMaxSpeed = 200;
const int kVoicepeakDefaultSpeed = 100;

/// 情绪 → VOICEPEAK 情感名候选（按顺序取旁白 `--list-emotion` 里第一个有的）。只收
/// 官方标准旁白共有的四个情感名（happy 喜び / fun 楽しい / angry 怒り / sad 悲しみ）；
/// 旁白各自的特殊情感名不猜。不在表里的情绪一律折成语速。
const Map<CastEmotion, List<String>> kVoicepeakEmotionNames =
    <CastEmotion, List<String>>{
      CastEmotion.joy: <String>['happy', 'fun'],
      CastEmotion.sadness: <String>['sad'],
      CastEmotion.anger: <String>['angry'],
    };

/// [emotion] 在 [narratorEmotions]（该旁白的 `--list-emotion`）里能用的情感名；
/// 没有返回 null。
String? voicepeakEmotionNameFor(
  CastEmotion? emotion,
  List<String> narratorEmotions,
) {
  if (emotion == null) return null;
  for (final String name in kVoicepeakEmotionNames[emotion] ?? <String>[]) {
    if (narratorEmotions.contains(name)) return name;
  }
  return null;
}

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

class VoicepeakTtsProvider extends TtsProvider implements TtsDirectedSynthesis {
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

  /// 本旁白的情感名（第一次有逐句情绪时查一次；失败不缓存）。
  Future<List<String>>? _narratorEmotions;

  @override
  TtsCapabilities get capabilities =>
      const VoicepeakTtsDescriptor().capabilities;

  /// 情绪原生 + 语速（见库注释；音高单位无法核实不声明，音量 CLI 没有）。
  static const TtsDirectionSupport support = TtsDirectionSupport(
    emotion: true,
    rate: true,
  );

  @override
  TtsDirectionSupport get directionSupport => support;

  /// 合成用的命令行（纯函数，测试直接调）。换行 / 控制字符换成空格；以 `-` 开头的
  /// 文本前补一个空格，免得被 CLI 当成选项。
  ///
  /// [direction] 是这句的语气（为空时命令行与不带语气完全一样），[narratorEmotions]
  /// 是旁白的 `--list-emotion`：
  /// - 情绪能译成旁白有的情感名（[voicepeakEmotionNameFor]）→ `-e` 里该名 = 强度，
  ///   并去掉预设里 [kVoicepeakEmotionNames] 那几个情感（这句的情绪取代预设的
  ///   基调；预设里别的情感如 whisper 类照留）；
  /// - 否则情绪按 [ttsEmotionProsody] 折成语速偏移，`-e` 用预设的；
  /// - 语速：`--speed = 预设（空 = 100）×（1 + 偏移）`，取整夹到 50..200。
  List<String> synthesisArguments(
    String text,
    String outputPath, {
    TtsDirection direction = TtsDirection.none,
    List<String> narratorEmotions = const <String>[],
  }) {
    String say = text.replaceAll(RegExp(r'[\u0000-\u001f\u007f]+'), ' ').trim();
    if (say.startsWith('-')) say = ' $say';
    final CastEmotion? lineEmotion = direction.emotion;
    final String? emotionName = voicepeakEmotionNameFor(
      lineEmotion,
      narratorEmotions,
    );
    final String presetEmotion = emotion.replaceAll(' ', '');
    final String emotionArg;
    if (emotionName != null) {
      final Set<String> replaced = <String>{
        for (final List<String> names in kVoicepeakEmotionNames.values)
          ...names,
      };
      final int value = direction.effectiveIntensity.clamp(
        0,
        CastLineLimits.maxIntensity,
      );
      emotionArg = <String>[
        for (final String part in presetEmotion.split(','))
          if (part.contains('=') && !replaced.contains(part.split('=').first))
            part,
        '$emotionName=$value',
      ].join(',');
    } else {
      emotionArg = presetEmotion;
    }
    double rate = direction.rateOffset ?? 0;
    if (lineEmotion != null && emotionName == null) {
      rate += ttsEmotionProsody(lineEmotion, direction.effectiveIntensity).rate;
    }
    rate = rate
        .clamp(CastLineLimits.minRateOffset, CastLineLimits.maxRateOffset)
        .toDouble();
    final String speedArg;
    if (rate.abs() < 1e-9) {
      speedArg = speed;
    } else {
      final int base = int.tryParse(speed) ?? kVoicepeakDefaultSpeed;
      speedArg =
          '${(base * (1 + rate)).round().clamp(kVoicepeakMinSpeed, kVoicepeakMaxSpeed)}';
    }
    return <String>[
      '-s',
      say,
      '-n',
      narrator,
      '-o',
      outputPath,
      if (emotionArg.isNotEmpty) ...<String>['-e', emotionArg],
      if (speedArg.isNotEmpty) ...<String>['--speed', speedArg],
      if (pitch.isNotEmpty) ...<String>['--pitch', pitch],
    ];
  }

  /// 旁白的情感名（逐句情绪要按它校验）。查一次缓存；查失败清掉缓存再抛，交给重试层
  /// （不能退回折算：同一句会因为一次偶发失败合出与缓存键不符的声音）。共享的那次
  /// 查询不挂某一句的取消令牌（一句取消不该连累同时等它的别句），有 [listTimeout] 兜底；
  /// 取消在查完后各自检查。
  Future<List<String>> _emotionsOfNarrator(TtsCancelToken cancel) async {
    final Future<List<String>> pending = _narratorEmotions ??= listEmotions(
      narrator,
    );
    try {
      final List<String> names = await pending;
      cancel.throwIfCancelled();
      return names;
    } on TtsFailure catch (e) {
      if (e.code != TtsFailureCode.cancelled &&
          identical(_narratorEmotions, pending)) {
        _narratorEmotions = null;
      }
      rethrow;
    }
  }

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) => synthesizeDirected(
    text,
    outputPath: outputPath,
    cancel: cancel,
    direction: TtsDirection.none,
  );

  @override
  Future<TtsResult> synthesizeDirected(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
    required TtsDirection direction,
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
    final List<String> narratorEmotions = direction.emotion == null
        ? const <String>[]
        : await _emotionsOfNarrator(cancel);
    await _serialized(cancel, () async {
      final File out = File(outputPath);
      try {
        if (out.existsSync()) out.deleteSync();
      } on FileSystemException {
        // 删不掉就让 CLI 覆盖；下面按产物长度判成败。
      }
      final _VoicepeakRun run = await _run(
        synthesisArguments(
          trimmed,
          outputPath,
          direction: direction,
          narratorEmotions: narratorEmotions,
        ),
        cancel: cancel,
        timeout: synthesisTimeout,
      );
      final int length = out.existsSync() ? out.lengthSync() : 0;
      if (run.exitCode != 0 || length == 0) {
        throw await _synthesisFailure(run, cancel);
      }
    });
    return const TtsResult(format: TtsAudioFormat.wav);
  }

  /// 合成失败（非零退出 / 没出文件）的归类。仍持有 CLI 锁，诊断命令不会与别的调用并发。
  ///
  /// 永久错误不靠猜 CLI 的报错文案，而是问 CLI 自己装了什么：
  ///  - `--list-narrator` 正常退出却一个旁白都没有 → [TtsFailureCode.notConfigured]
  ///    （没装旁白 / 授权没激活，重试同一句不会好）；
  ///  - 配置的旁白不在列表里 → [TtsFailureCode.rejected]（旁白名错 / 已卸载）；
  ///  - 配置的情感名不在该旁白的 `--list-emotion` 里 → rejected。
  /// 以上都对得上才算临时失败（CLI 偶发起不来），交给重试层。诊断本身起不来 / 超时也按
  /// 临时失败报原始原因。detail 一律带上退出码与 stderr 尾巴。
  Future<TtsFailure> _synthesisFailure(
    _VoicepeakRun run,
    TtsCancelToken cancel,
  ) async {
    final String detail = voicepeakFailureDetail(
      run.exitCode != 0 ? 'exit ${run.exitCode}' : 'no output',
      run.stderr,
    );
    _log?.call('VOICEPEAK synthesis failed: $detail');
    final TtsFailure transient = TtsFailure.withRetry(
      TtsFailureCode.badResponse,
      detail: detail,
      transient: true,
    );
    final _VoicepeakRun narrators;
    try {
      narrators = await _run(
        const <String>['--list-narrator'],
        cancel: cancel,
        timeout: listTimeout,
      );
    } on TtsFailure catch (e) {
      if (e.code == TtsFailureCode.cancelled) rethrow;
      return transient;
    }
    if (narrators.exitCode != 0) return transient;
    final List<String> installed = parseVoicepeakList(narrators.stdout);
    if (installed.isEmpty) {
      return TtsFailure(
        TtsFailureCode.notConfigured,
        'no narrators available (not installed or license inactive); $detail',
      );
    }
    if (!installed.contains(narrator)) {
      return TtsFailure(
        TtsFailureCode.rejected,
        'narrator "$narrator" is not installed; $detail',
      );
    }
    if (emotion.isEmpty) return transient;
    final _VoicepeakRun emotions;
    try {
      emotions = await _run(
        <String>['--list-emotion', narrator],
        cancel: cancel,
        timeout: listTimeout,
      );
    } on TtsFailure catch (e) {
      if (e.code == TtsFailureCode.cancelled) rethrow;
      return transient;
    }
    final List<String> known = parseVoicepeakList(emotions.stdout);
    if (emotions.exitCode != 0 || known.isEmpty) return transient;
    final List<String> unknown = <String>[
      for (final String part in emotion.split(','))
        if (part.contains('=') && !known.contains(part.split('=').first.trim()))
          part.split('=').first.trim(),
    ];
    if (unknown.isNotEmpty) {
      return TtsFailure(
        TtsFailureCode.rejected,
        'emotion ${unknown.join(',')} not available for "$narrator"; $detail',
      );
    }
    return transient;
  }

  /// 列表命令：非零退出带上 stderr 报（交给调用方，列表不走合成重试层）。
  Future<String> _list(List<String> arguments, TtsCancelToken? cancel) async {
    final _VoicepeakRun run = await _run(
      arguments,
      cancel: cancel,
      timeout: listTimeout,
    );
    if (run.exitCode != 0) {
      final String detail = voicepeakFailureDetail(
        'exit ${run.exitCode}',
        run.stderr,
      );
      _log?.call('VOICEPEAK ${arguments.first} failed: $detail');
      throw TtsFailure.withRetry(
        TtsFailureCode.badResponse,
        detail: detail,
        transient: true,
      );
    }
    return run.stdout;
  }

  @override
  Future<List<TtsVoice>> listVoices({TtsCancelToken? cancel}) async {
    if (executable.isEmpty) {
      throw const TtsFailure(TtsFailureCode.notConfigured);
    }
    final String output = await _serialized(
      cancel,
      () => _list(const <String>['--list-narrator'], cancel),
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
      () => _list(<String>['--list-emotion', narrator.trim()], cancel),
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

  /// 跑一次 CLI，返回退出码、stdout 与 stderr（非零退出由调用方归类）。抛出的只有：
  /// 起不来 → notConfigured；取消 → cancelled（杀进程）；超时 → timeout（杀进程）。
  Future<_VoicepeakRun> _run(
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
      if (code != 0) _log?.call('VOICEPEAK exited with $code');
      return (
        exitCode: code,
        stdout: stdout.toString(),
        stderr: stderr.toString(),
      );
    } finally {
      timer.cancel();
      unregister?.call();
    }
  }
}

/// 一次 CLI 运行的结果。
typedef _VoicepeakRun = ({int exitCode, String stdout, String stderr});

/// 失败诊断：`<原因>: <stderr 末尾，空白压成单空格，最多 300 字>`（stderr 为空只给原因）。
/// 本机 CLI 的输出，不含密钥；截尾是因为它会进日志与错误提示。
String voicepeakFailureDetail(String reason, String stderr) {
  final String flat = stderr.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return reason;
  const int max = 300;
  final String tail = flat.length > max
      ? '…${flat.substring(flat.length - max)}'
      : flat;
  return '$reason: $tail';
}

/// `--list-narrator` / `--list-emotion` 的输出：一行一个名字（去空白、去空行）。
List<String> parseVoicepeakList(String output) => <String>[
  for (final String line in const LineSplitter().convert(output))
    if (line.trim().isNotEmpty) line.trim(),
];
