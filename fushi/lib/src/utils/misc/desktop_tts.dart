import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/system_tts.dart';
import 'package:fushi/src/utils/misc/system_tts_voices.dart';
import 'package:fushi/src/utils/misc/windows_speech_worker.dart';
import 'package:fushi_engine/tts/tts_types.dart';

/// Desktop TTS-to-file (the system voice: read-aloud presets and the term-audio
/// fallback).
///
/// Android / iOS synthesise natively; off those we drive the OS speech engine:
/// - macOS `say` straight to 16-bit WAV (`--file-format=WAVE`), so the cache /
///   probe / Anki all see a plain RIFF file;
/// - Windows WinRT `Windows.Media.SpeechSynthesis` (OneCore voices) plus SAPI 5
///   through one long-lived PowerShell worker ([WindowsSpeechWorker]);
/// - Linux Open JTalk (WAV, reads kanji) with espeak-ng as a kana-only fallback
///   (its Japanese voice cannot read kanji, so kanji text is never handed to it).
///
/// [voice] is a voice id from [listDesktopTtsVoices] (null / empty = pick one by
/// [languageTag]); a voice that is no longer installed is
/// [SystemTtsFailureReason.voiceUnavailable], never silently swapped for another.
/// [languageTag] is the language to speak (see `resolveSystemTtsLanguageTag`);
/// null = the engine's default voice. Every failure throws [SystemTtsFailure];
/// nothing returns null silently (BUG-3669).
Future<String> ttsToFileDesktop({
  required String text,
  required String outputPath,
  String? languageTag,
  String? voice,
}) async {
  if (text.trim().isEmpty) {
    throw SystemTtsFailure(
      SystemTtsFailureReason.synthesisFailed,
      languageTag: languageTag,
    );
  }
  final String? chosen = (voice == null || voice.trim().isEmpty)
      ? null
      : voice.trim();
  if (Platform.isMacOS) return _sayMacOS(text, outputPath, languageTag, chosen);
  if (Platform.isWindows) {
    return synthesizeWindowsSpeech(
      worker: WindowsSpeechWorker.instance,
      text: text,
      outputPath: outputPath,
      languageTag: languageTag,
      voice: chosen,
    );
  }
  if (Platform.isLinux) {
    return synthesizeLinuxTtsForLanguage(
      text: text,
      outputPath: outputPath,
      languageTag: languageTag,
      openJTalk: resolveSystemOpenJTalkAssets(),
      voice: chosen,
    );
  }
  throw SystemTtsFailure(
    SystemTtsFailureReason.engineUnavailable,
    languageTag: languageTag,
  );
}

/// 本机系统语音可选的声音（桌面三端）。列不出来（引擎没装 / 进程失败）返回空表。
Future<List<TtsVoice>> listDesktopTtsVoices() async {
  try {
    if (Platform.isMacOS) {
      final ProcessResult r = await Process.run('say', <String>['-v', '?']);
      return r.exitCode == 0
          ? parseMacOSSayVoices('${r.stdout}')
          : const <TtsVoice>[];
    }
    if (Platform.isWindows) {
      final Map<String, Object?> reply = await WindowsSpeechWorker.instance
          .request(<String, Object?>{'op': 'voices'});
      return reply['ok'] == true
          ? mergeWindowsSpeechVoices(reply['voices'])
          : const <TtsVoice>[];
    }
    if (Platform.isLinux) return listLinuxTtsVoices();
  } on Object catch (e, stack) {
    ErrorLogService.instance.log('listDesktopTtsVoices', e, stack);
  }
  return const <TtsVoice>[];
}

/// [languageTag] 的主语言子标签，只放行 2–3 个字母（要发给系统引擎 / 与
/// `say -v ?` 的输出比对，不能把任意字符串带进去）。null / 不合法 = 不指定。
@visibleForTesting
String? desktopTtsLanguageCode(String? languageTag) {
  if (languageTag == null) return null;
  final String primary = primaryLanguageSubtag(languageTag);
  return RegExp(r'^[a-z]{2,3}$').hasMatch(primary) ? primary : null;
}

/// 从 `say -v ?` 的输出里挑第一个 [languageCode] 语言的声音名；没有返回 null。
@visibleForTesting
String? pickMacOSVoice(String sayVoiceList, String languageCode) {
  for (final TtsVoice v in parseMacOSSayVoices(sayVoiceList)) {
    if (primaryLanguageSubtag(v.locale) == languageCode) return v.id;
  }
  return null;
}

/// `say` 直接写 16-bit 小端 PCM 的 WAV（`--file-format=WAVE --data-format=LEI16@22050`，
/// Mac 实测输出 RIFF/WAVE、与扩展名无关）。以前只出 AIFF，而缓存层的格式探测只认
/// WAV / MP3，所以朗读声音体系里干脆没开放 macOS。
@visibleForTesting
List<String> sayMacOSArguments({
  required String outputPath,
  required String text,
  String? voice,
}) => <String>[
  if (voice != null) ...<String>['-v', voice],
  '--file-format=WAVE',
  '--data-format=LEI16@22050',
  '-o',
  outputPath,
  // `--` terminates options so text starting with `-` is not parsed as a flag.
  '--',
  text,
];

Future<String> _sayMacOS(
  String text,
  String outputPath,
  String? languageTag,
  String? chosenVoice,
) async {
  final File out = File(outputPath);
  out.parent.createSync(recursive: true);
  if (out.existsSync()) out.deleteSync();
  String? voice = chosenVoice;
  final String? code = desktopTtsLanguageCode(languageTag);
  try {
    if (voice == null && code != null) {
      final ProcessResult list = await Process.run('say', <String>['-v', '?']);
      voice = list.exitCode == 0
          ? pickMacOSVoice('${list.stdout}', code)
          : null;
      if (voice == null) {
        throw SystemTtsFailure(
          SystemTtsFailureReason.languageNotSupported,
          languageTag: languageTag,
        );
      }
    }
    final ProcessResult r = await Process.run(
      'say',
      sayMacOSArguments(outputPath: outputPath, text: text, voice: voice),
    );
    if (r.exitCode == 0 && out.existsSync() && out.lengthSync() > 0) {
      return outputPath;
    }
    if (chosenVoice != null) {
      // 点名的声音不在了 `say` 也是非零退出：先分清是不是这个原因。
      final ProcessResult list = await Process.run('say', <String>['-v', '?']);
      final bool installed =
          list.exitCode == 0 &&
          parseMacOSSayVoices(
            '${list.stdout}',
          ).any((TtsVoice v) => v.id == chosenVoice);
      if (!installed) {
        throw SystemTtsFailure(
          SystemTtsFailureReason.voiceUnavailable,
          languageTag: languageTag,
        );
      }
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

/// [WindowsSpeechWorker] 的 `speak` 请求体。点名的声音按 id 拆成引擎 + 键交给脚本；
/// 不认识的 id 前缀（旧数据 / 别的平台同步来的）返回 null = 声音不在。
@visibleForTesting
Map<String, Object?>? windowsSpeakRequest({
  required String text,
  required String outputPath,
  required String? languageTag,
  required String? voice,
}) {
  final Map<String, Object?> body = <String, Object?>{
    'op': 'speak',
    'text': base64Encode(utf8.encode(text)),
    'out': outputPath,
  };
  if (voice != null) {
    final ({String kind, String key})? parsed = parseWindowsVoiceId(voice);
    if (parsed == null) return null;
    body['voiceKind'] = parsed.kind;
    body['voiceKey'] = parsed.key;
  } else {
    final String? code = desktopTtsLanguageCode(languageTag);
    if (code != null) body['lang'] = code;
  }
  return body;
}

/// Windows：经常驻工作进程合成（OneCore 优先，SAPI 兜底，见
/// [kWindowsSpeechWorkerScript]）。工作进程起不来 = 没有引擎。
@visibleForTesting
Future<String> synthesizeWindowsSpeech({
  required WindowsSpeechWorker worker,
  required String text,
  required String outputPath,
  required String? languageTag,
  required String? voice,
}) async {
  final File out = File(outputPath);
  out.parent.createSync(recursive: true);
  if (out.existsSync()) out.deleteSync();
  final Map<String, Object?>? body = windowsSpeakRequest(
    text: text,
    outputPath: outputPath,
    languageTag: languageTag,
    voice: voice,
  );
  if (body == null) {
    throw SystemTtsFailure(
      SystemTtsFailureReason.voiceUnavailable,
      languageTag: languageTag,
    );
  }
  final Map<String, Object?> reply;
  try {
    reply = await worker.request(body);
  } on WindowsSpeechWorkerUnavailable catch (e, stack) {
    ErrorLogService.instance.log('ttsToFileDesktop.windows', e, stack);
    throw SystemTtsFailure(
      SystemTtsFailureReason.engineUnavailable,
      languageTag: languageTag,
    );
  }
  if (reply['ok'] == true && out.existsSync() && out.lengthSync() > 0) {
    return outputPath;
  }
  final Object? code = reply['code'];
  if (code != 'VOICE_UNAVAILABLE' && code != 'LANGUAGE_NOT_SUPPORTED') {
    ErrorLogService.instance.log(
      'ttsToFileDesktop.windows',
      'speech worker: $code ${reply['message'] ?? ''}',
      StackTrace.current,
    );
  }
  throw SystemTtsFailure.fromPlatformCode(
    code is String ? code : 'SYNTHESIS_FAILED',
    languageTag,
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

/// Linux 可选声音：Open JTalk 的 `.htsvoice`（装了辞书才列）+ espeak-ng 的声音表。
/// 进程 / 目录读取经参数注入，脱离真实系统可测。
@visibleForTesting
Future<List<TtsVoice>> listLinuxTtsVoicesWith({
  required OpenJTalkAssets? openJTalk,
  required List<String> Function() listOpenJTalkVoiceFiles,
  required Future<String?> Function() espeakVoiceList,
}) async {
  final String? espeak = await espeakVoiceList();
  return <TtsVoice>[
    if (openJTalk != null)
      ...openJTalkVoicesFromFiles(listOpenJTalkVoiceFiles()),
    if (espeak != null) ...parseEspeakNgVoices(espeak),
  ];
}

/// 本机的 Linux 声音清单（真实环境）。
Future<List<TtsVoice>> listLinuxTtsVoices() => listLinuxTtsVoicesWith(
  openJTalk: resolveSystemOpenJTalkAssets(),
  listOpenJTalkVoiceFiles: () {
    final String? override = Platform.environment['FUSHI_OPEN_JTALK_VOICE'];
    return <String>{
      if (override != null &&
          override.isNotEmpty &&
          File(override).existsSync())
        override,
      for (final String dir in kOpenJTalkVoiceDirs)
        if (Directory(dir).existsSync()) ..._listHtsVoices(dir),
    }.toList();
  },
  espeakVoiceList: () async {
    try {
      final ProcessResult r = await Process.run('espeak-ng', <String>[
        '--voices',
      ]);
      return r.exitCode == 0 ? '${r.stdout}' : null;
    } on ProcessException {
      return null; // 没装 espeak-ng。
    }
  },
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
/// 没点名声音时这两个引擎只用日语声音：请求的是别的语言就直接报
/// [SystemTtsFailureReason.languageNotSupported]，不拿日语声音去念（BUG-3669）。
/// 没出音频时，Open JTalk 资产都不在 = 没有引擎；在 = 合成失败。
///
/// 点名了 [voice]（`openjtalk:<路径>` / `espeak:<语言名>`）就只用那一个：声音文件不在
/// = [SystemTtsFailureReason.voiceUnavailable]；espeak-ng 的日语声音照样只读纯假名。
@visibleForTesting
Future<String> synthesizeLinuxTtsForLanguage({
  required String text,
  required String outputPath,
  required String? languageTag,
  required OpenJTalkAssets? openJTalk,
  String? voice,
  bool Function(String path)? fileExists,
  LinuxTtsProcessStarter startProcess = Process.start,
  Duration processTimeout = kLinuxTtsProcessTimeout,
}) async {
  if (voice != null && voice.isNotEmpty) {
    final String? written = await _synthesizeLinuxWithVoice(
      text: text,
      outputPath: outputPath,
      languageTag: languageTag,
      openJTalk: openJTalk,
      voice: voice,
      fileExists: fileExists ?? (String path) => File(path).existsSync(),
      startProcess: startProcess,
      processTimeout: processTimeout,
    );
    if (written != null) return written;
    throw SystemTtsFailure(
      SystemTtsFailureReason.synthesisFailed,
      languageTag: languageTag,
    );
  }
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

/// 按点名的声音合成；声音不在时抛 [SystemTtsFailure]，进程失败返回 null。
Future<String?> _synthesizeLinuxWithVoice({
  required String text,
  required String outputPath,
  required String? languageTag,
  required OpenJTalkAssets? openJTalk,
  required String voice,
  required bool Function(String path) fileExists,
  required LinuxTtsProcessStarter startProcess,
  required Duration processTimeout,
}) async {
  if (voice.startsWith(kLinuxOpenJTalkVoicePrefix)) {
    final String voicePath = voice.substring(kLinuxOpenJTalkVoicePrefix.length);
    if (openJTalk == null) {
      // 没有辞书就没有 Open JTalk 引擎（声音文件在也念不了）。
      throw SystemTtsFailure(
        SystemTtsFailureReason.engineUnavailable,
        languageTag: languageTag,
      );
    }
    if (!fileExists(voicePath)) {
      throw SystemTtsFailure(
        SystemTtsFailureReason.voiceUnavailable,
        languageTag: languageTag,
      );
    }
    return _runOpenJTalk(
      text: text,
      outputPath: outputPath,
      assets: (dictionaryDir: openJTalk.dictionaryDir, voicePath: voicePath),
      startProcess: startProcess,
      timeout: processTimeout,
    );
  }
  if (voice.startsWith(kLinuxEspeakVoicePrefix)) {
    final String name = voice.substring(kLinuxEspeakVoicePrefix.length);
    // 只放行 espeak-ng 语言名的字符（会作为 `-v` 参数传给进程）。
    if (!RegExp(r'^[A-Za-z0-9_+\-/]+$').hasMatch(name)) {
      throw SystemTtsFailure(
        SystemTtsFailureReason.voiceUnavailable,
        languageTag: languageTag,
      );
    }
    if (primaryLanguageSubtag(name) == 'ja' && !isKanaOnlyText(text)) {
      // espeak-ng 的日语声音念不了汉字（BUG-3092），宁可不出音频。
      return null;
    }
    return _runEspeakNg(
      text: text,
      outputPath: outputPath,
      voiceName: name,
      startProcess: startProcess,
      timeout: processTimeout,
    );
  }
  throw SystemTtsFailure(
    SystemTtsFailureReason.voiceUnavailable,
    languageTag: languageTag,
  );
}

Future<String?> _runOpenJTalk({
  required String text,
  required String outputPath,
  required OpenJTalkAssets assets,
  required LinuxTtsProcessStarter startProcess,
  required Duration timeout,
}) => runLinuxTtsProcess(
  executable: 'open_jtalk',
  // 不给输入文件参数时 open_jtalk 从 stdin 读一行行文本。
  arguments: <String>[
    '-x',
    assets.dictionaryDir,
    '-m',
    assets.voicePath,
    '-ow',
    outputPath,
  ],
  // open_jtalk 按行合成；把换行压成空格，保证一次调用只出一段音频。
  text: '${text.replaceAll(RegExp(r'[\r\n]+'), ' ')}\n',
  outputPath: outputPath,
  logTag: 'ttsToFileDesktop.openJTalk',
  startProcess: startProcess,
  timeout: timeout,
);

Future<String?> _runEspeakNg({
  required String text,
  required String outputPath,
  required String voiceName,
  required LinuxTtsProcessStarter startProcess,
  required Duration timeout,
}) => runLinuxTtsProcess(
  executable: 'espeak-ng',
  // `--stdin` 读文本；`-b 1` = 输入是 UTF-8。
  arguments: <String>['-v', voiceName, '-b', '1', '-w', outputPath, '--stdin'],
  text: text,
  outputPath: outputPath,
  logTag: 'ttsToFileDesktop.espeakNg',
  startProcess: startProcess,
  timeout: timeout,
);

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
    final String? viaOpenJTalk = await _runOpenJTalk(
      text: text,
      outputPath: outputPath,
      assets: openJTalk,
      startProcess: startProcess,
      timeout: processTimeout,
    );
    if (viaOpenJTalk != null) return viaOpenJTalk;
  }
  if (!isKanaOnlyText(text)) return null;
  return _runEspeakNg(
    text: text,
    outputPath: outputPath,
    voiceName: 'ja',
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
