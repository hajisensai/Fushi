import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/system_tts.dart';

/// Desktop TTS-to-file for term audio (the system-voice fallback).
///
/// Android synthesises via the native `TextToSpeech`; off Android we shell out
/// to the OS speech engine: macOS `say` (AIFF), Windows System.Speech / SAPI
/// (WAV) and on Linux Open JTalk (WAV, reads kanji) with espeak-ng as a
/// kana-only fallback (its Japanese voice cannot read kanji, so kanji text is
/// never handed to it).
///
/// [languageTag] is the language to speak (see `resolveSystemTtsLanguageTag`);
/// null = the engine's default voice. BUG-3669: this used to ignore the
/// language entirely (Windows / macOS read everything with the default voice,
/// Linux read everything as Japanese) and returned null on any failure. Now:
/// - Windows / macOS pick an installed voice for that language, and report
///   [SystemTtsFailureReason.languageNotSupported] when there is none;
/// - Linux only has Japanese engines, so any other language is
///   [SystemTtsFailureReason.languageNotSupported] instead of being read with a
///   Japanese voice;
/// - every failure throws [SystemTtsFailure]; nothing returns null silently.
Future<String> ttsToFileDesktop({
  required String text,
  required String outputPath,
  String? languageTag,
}) async {
  if (text.trim().isEmpty) {
    throw SystemTtsFailure(
      SystemTtsFailureReason.synthesisFailed,
      languageTag: languageTag,
    );
  }
  if (Platform.isMacOS) return _sayMacOS(text, outputPath, languageTag);
  if (Platform.isWindows) return _sapiWindows(text, outputPath, languageTag);
  if (Platform.isLinux) {
    return synthesizeLinuxTtsForLanguage(
      text: text,
      outputPath: outputPath,
      languageTag: languageTag,
      openJTalk: resolveSystemOpenJTalkAssets(),
    );
  }
  throw SystemTtsFailure(
    SystemTtsFailureReason.engineUnavailable,
    languageTag: languageTag,
  );
}

/// [languageTag] 的主语言子标签，只放行 2–3 个字母（要拼进 PowerShell 脚本 /
/// 与 `say -v ?` 的输出比对，不能把任意字符串带进去）。null / 不合法 = 不指定。
@visibleForTesting
String? desktopTtsLanguageCode(String? languageTag) {
  if (languageTag == null) return null;
  final String primary = primaryLanguageSubtag(languageTag);
  return RegExp(r'^[a-z]{2,3}$').hasMatch(primary) ? primary : null;
}

/// macOS `say -v ?` 的一行：`<声音名>  <语言>_<地区>  # 示例`。声音名可能带空格
/// （`Good News`），所以按「名字 + 至少两个空格 + 语言标签」切。
final RegExp _sayVoiceLine = RegExp(r'^(.+?)\s{2,}([A-Za-z]{2,3})[_-]\S*\s+#');

/// 从 `say -v ?` 的输出里挑第一个 [languageCode] 语言的声音名；没有返回 null。
@visibleForTesting
String? pickMacOSVoice(String sayVoiceList, String languageCode) {
  for (final String line in sayVoiceList.split('\n')) {
    final RegExpMatch? m = _sayVoiceLine.firstMatch(line);
    if (m == null) continue;
    if (m.group(2)!.toLowerCase() == languageCode) return m.group(1)!.trim();
  }
  return null;
}

/// macOS `say` reliably writes AIFF; use a sibling `.aiff` path regardless of
/// the requested extension (Anki/mpv plays AIFF).
Future<String> _sayMacOS(
  String text,
  String outputPath,
  String? languageTag,
) async {
  final String aiffPath =
      '${outputPath.replaceFirst(RegExp(r'\.[^.]+$'), '')}.aiff';
  final File out = File(aiffPath);
  out.parent.createSync(recursive: true);
  final List<String> voiceArgs = <String>[];
  final String? code = desktopTtsLanguageCode(languageTag);
  try {
    if (code != null) {
      final ProcessResult list = await Process.run('say', <String>['-v', '?']);
      final String? voice = list.exitCode == 0
          ? pickMacOSVoice('${list.stdout}', code)
          : null;
      if (voice == null) {
        throw SystemTtsFailure(
          SystemTtsFailureReason.languageNotSupported,
          languageTag: languageTag,
        );
      }
      voiceArgs.addAll(<String>['-v', voice]);
    }
    // `--` terminates options so text starting with `-` is not parsed as a flag.
    final ProcessResult r = await Process.run('say', <String>[
      ...voiceArgs,
      '-o',
      aiffPath,
      '--',
      text,
    ]);
    if (r.exitCode == 0 && out.existsSync() && out.lengthSync() > 0) {
      return aiffPath;
    }
    ErrorLogService.instance.log(
      'ttsToFileDesktop.say',
      'say exit ${r.exitCode}: ${r.stderr}',
      StackTrace.current,
    );
  } on ProcessException {
    throw SystemTtsFailure(
      SystemTtsFailureReason.engineUnavailable,
      languageTag: languageTag,
    );
  }
  throw SystemTtsFailure(
    SystemTtsFailureReason.synthesisFailed,
    languageTag: languageTag,
  );
}

/// [_sapiWindows] 的 PowerShell 脚本在「没有该语言的已启用声音」时的退出码。
const int kSapiNoVoiceForLanguageExitCode = 3;

/// Windows System.Speech (SAPI) → WAV via PowerShell. The text is passed as
/// base64-encoded UTF-8 to survive the shell without quoting/encoding issues.
/// 指定了语言时先选一个该语言（`Culture.TwoLetterISOLanguageName`）的已启用
/// 声音，没有就以 [kSapiNoVoiceForLanguageExitCode] 退出。
@visibleForTesting
String sapiWindowsScript({
  required String textBase64,
  required String outputPath,
  required String? languageCode,
}) {
  final String escapedOut = outputPath.replaceAll("'", "''");
  final String selectVoice = languageCode == null
      ? ''
      : r'$v=$s.GetInstalledVoices() | Where-Object { $_.Enabled -and '
            "\$_.VoiceInfo.Culture.TwoLetterISOLanguageName -eq '$languageCode' }"
            r' | Select-Object -First 1; '
            'if (-not \$v) { \$s.Dispose(); exit $kSapiNoVoiceForLanguageExitCode }; '
            r'$s.SelectVoice($v.VoiceInfo.Name); ';
  return 'Add-Type -AssemblyName System.Speech; '
      r"$t=[System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"
      "$textBase64')); "
      r'$s=New-Object System.Speech.Synthesis.SpeechSynthesizer; '
      '$selectVoice'
      "\$s.SetOutputToWaveFile('$escapedOut'); "
      r'$s.Speak($t); $s.Dispose();';
}

Future<String> _sapiWindows(
  String text,
  String outputPath,
  String? languageTag,
) async {
  final File out = File(outputPath);
  out.parent.createSync(recursive: true);
  final String script = sapiWindowsScript(
    textBase64: base64Encode(utf8.encode(text)),
    outputPath: outputPath,
    languageCode: desktopTtsLanguageCode(languageTag),
  );
  final ProcessResult r;
  try {
    r = await Process.run('powershell', <String>[
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      script,
    ]);
  } on ProcessException {
    throw SystemTtsFailure(
      SystemTtsFailureReason.engineUnavailable,
      languageTag: languageTag,
    );
  }
  if (r.exitCode == 0 && out.existsSync() && out.lengthSync() > 0) {
    return outputPath;
  }
  if (r.exitCode == kSapiNoVoiceForLanguageExitCode) {
    throw SystemTtsFailure(
      SystemTtsFailureReason.languageNotSupported,
      languageTag: languageTag,
    );
  }
  ErrorLogService.instance.log(
    'ttsToFileDesktop.sapi',
    'powershell exit ${r.exitCode}: ${r.stderr}',
    StackTrace.current,
  );
  throw SystemTtsFailure(
    SystemTtsFailureReason.synthesisFailed,
    languageTag: languageTag,
  );
}

/// Open JTalk 的两件资产：MeCab 辞书目录（`-x`）与 HTS 声音文件（`-m`）。
typedef OpenJTalkAssets = ({String dictionaryDir, String voicePath});

/// 各发行版 Open JTalk 辞书的落点（Debian/Ubuntu `open-jtalk-mecab-naist-jdic`、
/// Arch AUR `open-jtalk`、源码 `make install` 缺省前缀）。
const List<String> kOpenJTalkDictionaryDirs = <String>[
  '/var/lib/mecab/dic/open-jtalk/naist-jdic',
  '/usr/share/open-jtalk/dic',
  '/usr/local/share/open_jtalk/dic',
  '/usr/local/lib/open_jtalk/dic',
];

/// HTS 声音的搜索目录（Debian/Ubuntu `hts-voice-nitech-jp-atr503-m001` 装在
/// `/usr/share/hts-voice/<名>/`，Arch 的 MMDAgent `mei` 声音在 `voices/`）。
const List<String> kOpenJTalkVoiceDirs = <String>[
  '/usr/share/hts-voice',
  '/usr/share/open-jtalk/voices',
  '/usr/local/share/hts-voice',
];

/// 找 Open JTalk 的辞书与声音。`FUSHI_OPEN_JTALK_DIC` / `FUSHI_OPEN_JTALK_VOICE`
/// 显式指定时优先（自编 / 非标准路径的用户用）；指定了但不存在就当没装，不再
/// 悄悄换成别的——用户点名的那份不在，换一份只会让排查更难。
@visibleForTesting
OpenJTalkAssets? resolveOpenJTalkAssets({
  required Map<String, String> environment,
  required bool Function(String path) directoryExists,
  required bool Function(String path) fileExists,
  required List<String> Function(String dir) listVoiceFiles,
}) {
  final String? dicOverride = environment['FUSHI_OPEN_JTALK_DIC'];
  final String? dic = dicOverride != null && dicOverride.isNotEmpty
      ? (directoryExists(dicOverride) ? dicOverride : null)
      : kOpenJTalkDictionaryDirs.where(directoryExists).firstOrNull;
  if (dic == null) return null;

  final String? voiceOverride = environment['FUSHI_OPEN_JTALK_VOICE'];
  String? voice;
  if (voiceOverride != null && voiceOverride.isNotEmpty) {
    voice = fileExists(voiceOverride) ? voiceOverride : null;
  } else {
    for (final String dir in kOpenJTalkVoiceDirs) {
      if (!directoryExists(dir)) continue;
      final List<String> voices = listVoiceFiles(dir)..sort();
      if (voices.isNotEmpty) {
        voice = voices.first;
        break;
      }
    }
  }
  if (voice == null) return null;
  return (dictionaryDir: dic, voicePath: voice);
}

/// [text] 是否只由假名（含长音符、读音里常见的符号、空白）组成——espeak-ng 的
/// 日语声音只会读假名，带汉字的文本交给它会读错，宁可不出音频。
///
/// 收哪些、拒哪些以 espeak-ng 1.51（`-v ja -q -x` 看音素输出）实测为准（BUG-3092）：
/// - 收：假名本体、长音 `ー`/`ｰ`、波浪长音 `〜`（读成延长）、全角 `～`、省略号
///   `…`/`‥`、括号 `「」『』`/`｢｣`、句读与空白（都只当停顿）；
/// - 拒：中点 `・`（U+30FB）与片假名音标扩展 `ㇰ`–`ㇿ`（U+31F0–31FF）——espeak-ng
///   会把它们念成英语的 "Japanese letter" / "Chinese letter"。
@visibleForTesting
bool isKanaOnlyText(String text) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) return false;
  bool sawKana = false;
  for (final int rune in trimmed.runes) {
    final bool kana =
        (rune >= 0x3041 && rune <= 0x309F) || // 平假名（含 ゛゜ゝゞ）
        (rune >= 0x30A0 && rune <= 0x30FA) || // 片假名
        (rune >= 0x30FC && rune <= 0x30FF) || // ー ヽ ヾ ヿ
        (rune >= 0xFF66 && rune <= 0xFF9F); // 半角片假名（含 ｰ）
    if (kana) {
      sawKana = true;
      continue;
    }
    final bool neutral =
        rune == 0x20 ||
        rune == 0x3000 || // 全角空格
        (rune >= 0x3001 && rune <= 0x3003) || // 、。〃
        (rune >= 0x300C && rune <= 0x300F) || // 「」『』
        rune == 0x301C || // 〜
        rune == 0x2025 || // ‥
        rune == 0x2026 || // …
        rune == 0xFF01 || // ！
        rune == 0xFF1F || // ？
        rune == 0xFF5E || // ～
        (rune >= 0xFF61 && rune <= 0xFF65); // ｡｢｣､･
    if (!neutral) return false;
  }
  return sawKana;
}

List<String> _listHtsVoices(String dir) {
  try {
    return Directory(dir)
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .map((File f) => f.path)
        .where((String path) => path.endsWith('.htsvoice'))
        .toList();
  } on FileSystemException {
    return <String>[];
  }
}

/// 本机实际可用的 Open JTalk 资产（读真实环境变量与文件系统）；缺辞书或缺声音
/// 返回 null。生产路径与真引擎测试的 skip 判据共用这一处。
OpenJTalkAssets? resolveSystemOpenJTalkAssets() => resolveOpenJTalkAssets(
  environment: Platform.environment,
  directoryExists: (String path) => Directory(path).existsSync(),
  fileExists: (String path) => File(path).existsSync(),
  listVoiceFiles: _listHtsVoices,
);

/// 启动外部 TTS 进程的函数形状（[Process.start] 的子集），测试注入假进程用。
typedef LinuxTtsProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

/// 单个 TTS 进程从写入文本到退出的上界。合成一个词条读音正常在 1 秒内；这是对
/// 外部进程（辞书损坏、声音文件异常、等不到 EOF）的硬上界，到点杀掉并按该引擎
/// 失败处理，让下一个引擎接着兜底，而不是让制卡永远等下去（BUG-3088）。
const Duration kLinuxTtsProcessTimeout = Duration(seconds: 15);

/// Linux：Open JTalk（能读汉字）优先，没装或失败再用 espeak-ng 读纯假名文本。
///
/// 这两个引擎都只装了日语声音：请求的是别的语言就直接报
/// [SystemTtsFailureReason.languageNotSupported]，不拿日语声音去念（BUG-3669）。
/// 没出音频时，Open JTalk 资产都不在 = 没有引擎；在 = 合成失败。
@visibleForTesting
Future<String> synthesizeLinuxTtsForLanguage({
  required String text,
  required String outputPath,
  required String? languageTag,
  required OpenJTalkAssets? openJTalk,
  LinuxTtsProcessStarter startProcess = Process.start,
  Duration processTimeout = kLinuxTtsProcessTimeout,
}) async {
  final String? code = desktopTtsLanguageCode(languageTag);
  if (code != null && code != 'ja') {
    throw SystemTtsFailure(
      SystemTtsFailureReason.languageNotSupported,
      languageTag: languageTag,
    );
  }
  final String? written = await synthesizeLinuxTts(
    text: text,
    outputPath: outputPath,
    openJTalk: openJTalk,
    startProcess: startProcess,
    processTimeout: processTimeout,
  );
  if (written != null) return written;
  throw SystemTtsFailure(
    openJTalk == null
        ? SystemTtsFailureReason.engineUnavailable
        : SystemTtsFailureReason.synthesisFailed,
    languageTag: languageTag,
  );
}

/// [synthesizeLinuxTtsForLanguage] 的可注入内核：引擎选择与兜底顺序脱离真实进程可测。
@visibleForTesting
Future<String?> synthesizeLinuxTts({
  required String text,
  required String outputPath,
  required OpenJTalkAssets? openJTalk,
  LinuxTtsProcessStarter startProcess = Process.start,
  Duration processTimeout = kLinuxTtsProcessTimeout,
}) async {
  if (openJTalk != null) {
    final String? viaOpenJTalk = await runLinuxTtsProcess(
      executable: 'open_jtalk',
      // 不给输入文件参数时 open_jtalk 从 stdin 读一行行文本。
      arguments: <String>[
        '-x',
        openJTalk.dictionaryDir,
        '-m',
        openJTalk.voicePath,
        '-ow',
        outputPath,
      ],
      // open_jtalk 按行合成；把换行压成空格，保证一次调用只出一段音频。
      text: '${text.replaceAll(RegExp(r'[\r\n]+'), ' ')}\n',
      outputPath: outputPath,
      logTag: 'ttsToFileDesktop.openJTalk',
      startProcess: startProcess,
      timeout: processTimeout,
    );
    if (viaOpenJTalk != null) return viaOpenJTalk;
  }
  if (!isKanaOnlyText(text)) return null;
  return runLinuxTtsProcess(
    executable: 'espeak-ng',
    // `--stdin` 读文本；`-b 1` = 输入是 UTF-8。
    arguments: <String>['-v', 'ja', '-b', '1', '-w', outputPath, '--stdin'],
    text: text,
    outputPath: outputPath,
    logTag: 'ttsToFileDesktop.espeakNg',
    startProcess: startProcess,
    timeout: processTimeout,
  );
}

/// 跑一个 TTS 进程：文本经 stdin 以 UTF-8 送入（避开命令行转义与 argv 编码），
/// 退出码 0 且产出非空文件才算成功。可执行文件不存在时返回 null（未安装 ≠ 错误）。
///
/// 以下都按「该引擎失败」处理（记日志、返回 null），调用方据此换下一个引擎：
/// - 写 / 关 stdin 失败（引擎提前退出 → EPIPE，`SocketException`）；
/// - 从写入文本到进程退出超过 [timeout]——进程被 SIGKILL。
@visibleForTesting
Future<String?> runLinuxTtsProcess({
  required String executable,
  required List<String> arguments,
  required String text,
  required String outputPath,
  required String logTag,
  LinuxTtsProcessStarter startProcess = Process.start,
  Duration timeout = kLinuxTtsProcessTimeout,
}) async {
  final File out = File(outputPath);
  out.parent.createSync(recursive: true);
  if (out.existsSync()) out.deleteSync();
  final Process process;
  try {
    process = await startProcess(executable, arguments);
  } on ProcessException {
    return null; // 没装这个引擎。
  }
  // 先挂上 stdout / stderr 的消费者再写 stdin：否则引擎写满输出管道后阻塞，
  // 我们又在等它读完 stdin，两边互等。
  final Future<String> stderr = process.stderr.transform(utf8.decoder).join();
  final Future<void> stdoutDrained = process.stdout.drain<void>();

  Future<int> interact() async {
    process.stdin.add(utf8.encode(text));
    await process.stdin.close();
    await stdoutDrained;
    return process.exitCode;
  }

  final int exitCode;
  try {
    exitCode = await interact().timeout(timeout);
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    _deletePartialOutput(out);
    ErrorLogService.instance.log(
      logTag,
      '$executable did not finish within ${timeout.inMilliseconds}ms; killed',
      StackTrace.current,
    );
    return null;
  } on IOException catch (e, stack) {
    process.kill(ProcessSignal.sigkill);
    _deletePartialOutput(out);
    ErrorLogService.instance.log(logTag, '$executable stdin failed: $e', stack);
    return null;
  }
  if (exitCode == 0 && out.existsSync() && out.lengthSync() > 0) {
    return outputPath;
  }
  _deletePartialOutput(out);
  // 进程已退出，stderr 随之 EOF；仍加同一上界，防孙进程继承了管道不放。
  final String stderrText = await stderr.timeout(
    timeout,
    onTimeout: () => '<stderr not closed>',
  );
  ErrorLogService.instance.log(
    logTag,
    '$executable exit $exitCode: $stderrText',
    StackTrace.current,
  );
  return null;
}

/// 失败的引擎可能留下半截 WAV；删掉，免得被当成产物。
void _deletePartialOutput(File out) {
  try {
    if (out.existsSync()) out.deleteSync();
  } on FileSystemException catch (e, stack) {
    ErrorLogService.instance.log('ttsToFileDesktop.cleanup', e, stack);
  }
}
