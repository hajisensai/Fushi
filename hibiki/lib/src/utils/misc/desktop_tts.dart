import 'dart:convert';
import 'dart:io';

import 'package:hibiki/src/utils/misc/error_log_service.dart';

/// Best-effort desktop TTS-to-file fallback for term audio.
///
/// Android synthesises via the native `TextToSpeech`; off Android we shell out
/// to the OS speech engine: macOS `say` (AIFF) and Windows System.Speech / SAPI
/// (WAV). Linux has no dependable Japanese engine, so it returns null.
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
  } catch (e, stack) {
    ErrorLogService.instance.log('ttsToFileDesktop', e, stack);
  }
  return null; // Linux / unsupported
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
