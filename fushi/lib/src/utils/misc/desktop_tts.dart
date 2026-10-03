import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// Best-effort desktop TTS-to-file fallback for term audio.
///
/// Android synthesises via the native `TextToSpeech`; off Android we shell out
/// to the OS speech engine: macOS `say` (AIFF), Windows System.Speech / SAPI
/// (WAV) and on Linux Open JTalk (WAV, reads kanji) with espeak-ng as a
/// kana-only fallback (its Japanese voice cannot read kanji, so kanji text is
/// never handed to it). Linux engines are optional distro packages; when none
/// is installed this returns null like any other failure.
///
/// This is a LAST-RESORT fallback (after the local audio DB and online
/// sources). Pronunciation quality depends entirely on the OS's installed
/// Japanese voice (macOS: Kyoko/Otoya; Windows: Haruka); with only an English
/// voice the reading will be wrong. Returns null on any failure — never throws.
Future<String?> ttsToFileDesktop({
  required String text,
  required String outputPath,
}) async {
  if (text.trim().isEmpty) return null;
  try {
    if (Platform.isMacOS) return await _sayMacOS(text, outputPath);
    if (Platform.isWindows) return await _sapiWindows(text, outputPath);
    if (Platform.isLinux) return await _ttsLinux(text, outputPath);
  } catch (e, stack) {
    ErrorLogService.instance.log('ttsToFileDesktop', e, stack);
  }
  return null; // unsupported
}

/// macOS `say` reliably writes AIFF; use a sibling `.aiff` path regardless of
/// the requested extension (Anki/mpv plays AIFF).
Future<String?> _sayMacOS(String text, String outputPath) async {
  final String aiffPath =
      '${outputPath.replaceFirst(RegExp(r'\.[^.]+$'), '')}.aiff';
  final File out = File(aiffPath);
  out.parent.createSync(recursive: true);
  // `--` terminates options so text starting with `-` is not parsed as a flag.
  final ProcessResult r =
      await Process.run('say', <String>['-o', aiffPath, '--', text]);
  if (r.exitCode == 0 && out.existsSync() && out.lengthSync() > 0) {
    return aiffPath;
  }
  ErrorLogService.instance.log(
    'ttsToFileDesktop.say',
    'say exit ${r.exitCode}: ${r.stderr}',
    StackTrace.current,
  );
  return null;
}

/// Windows System.Speech (SAPI) → WAV via PowerShell. The text is passed as
/// base64-encoded UTF-8 to survive the shell without quoting/encoding issues.
Future<String?> _sapiWindows(String text, String outputPath) async {
  final File out = File(outputPath);
  out.parent.createSync(recursive: true);
  final String b64 = base64Encode(utf8.encode(text));
  final String escapedOut = outputPath.replaceAll("'", "''");
  final String script = 'Add-Type -AssemblyName System.Speech; '
      r"$t=[System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"
      "$b64')); "
      r'$s=New-Object System.Speech.Synthesis.SpeechSynthesizer; '
      "\$s.SetOutputToWaveFile('$escapedOut'); "
      r'$s.Speak($t); $s.Dispose();';
  final ProcessResult r = await Process.run(
    'powershell',
    <String>['-NoProfile', '-NonInteractive', '-Command', script],
  );
  if (r.exitCode == 0 && out.existsSync() && out.lengthSync() > 0) {
    return outputPath;
  }
  ErrorLogService.instance.log(
    'ttsToFileDesktop.sapi',
    'powershell exit ${r.exitCode}: ${r.stderr}',
    StackTrace.current,
  );
  return null;
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

/// [text] 是否只由假名（含长音符、标点、空白）组成——espeak-ng 的日语声音只会
/// 读假名，带汉字的文本交给它会读错，宁可不出音频。
@visibleForTesting
bool isKanaOnlyText(String text) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) return false;
  bool sawKana = false;
  for (final int rune in trimmed.runes) {
    final bool kana =
        (rune >= 0x3041 && rune <= 0x309F) || // 平假名
        (rune >= 0x30A0 && rune <= 0x30FF) || // 片假名（含 ー・）
        (rune >= 0x31F0 && rune <= 0x31FF) || // 片假名音标扩展
        (rune >= 0xFF66 && rune <= 0xFF9F); // 半角片假名
    if (kana) {
      sawKana = true;
      continue;
    }
    final bool neutral =
        rune == 0x20 ||
        rune == 0x3000 || // 全角空格
        (rune >= 0x3001 && rune <= 0x3003) || // 、。〃
        rune == 0xFF01 || // ！
        rune == 0xFF1F; // ？
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

/// Linux：Open JTalk（能读汉字）优先，没装再用 espeak-ng 读纯假名文本。
Future<String?> _ttsLinux(String text, String outputPath) async {
  final OpenJTalkAssets? assets = resolveOpenJTalkAssets(
    environment: Platform.environment,
    directoryExists: (String path) => Directory(path).existsSync(),
    fileExists: (String path) => File(path).existsSync(),
    listVoiceFiles: _listHtsVoices,
  );
  if (assets != null) {
    final String? viaOpenJTalk = await _openJTalkLinux(
      text,
      outputPath,
      assets,
    );
    if (viaOpenJTalk != null) return viaOpenJTalk;
  }
  if (!isKanaOnlyText(text)) return null;
  return _espeakNgLinux(text, outputPath);
}

/// 跑一个 TTS 进程：文本经 stdin 以 UTF-8 送入（避开命令行转义与 argv 编码），
/// 退出码 0 且产出非空文件才算成功。可执行文件不存在时返回 null（未安装 ≠ 错误）。
Future<String?> _runLinuxTtsProcess({
  required String executable,
  required List<String> arguments,
  required String text,
  required String outputPath,
  required String logTag,
}) async {
  final File out = File(outputPath);
  out.parent.createSync(recursive: true);
  if (out.existsSync()) out.deleteSync();
  final Process process;
  try {
    process = await Process.start(executable, arguments);
  } on ProcessException {
    return null; // 没装这个引擎。
  }
  process.stdin.add(utf8.encode(text));
  await process.stdin.close();
  final Future<String> stderr = process.stderr.transform(utf8.decoder).join();
  await process.stdout.drain<void>();
  final int exitCode = await process.exitCode;
  if (exitCode == 0 && out.existsSync() && out.lengthSync() > 0) {
    return outputPath;
  }
  ErrorLogService.instance.log(
    logTag,
    '$executable exit $exitCode: ${await stderr}',
    StackTrace.current,
  );
  return null;
}

Future<String?> _openJTalkLinux(
  String text,
  String outputPath,
  OpenJTalkAssets assets,
) => _runLinuxTtsProcess(
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
);

Future<String?> _espeakNgLinux(String text, String outputPath) =>
    _runLinuxTtsProcess(
      executable: 'espeak-ng',
      // `--stdin` 读文本；`-b 1` = 输入是 UTF-8。
      arguments: <String>['-v', 'ja', '-b', '1', '-w', outputPath, '--stdin'],
      text: text,
      outputPath: outputPath,
      logTag: 'ttsToFileDesktop.espeakNg',
    );
