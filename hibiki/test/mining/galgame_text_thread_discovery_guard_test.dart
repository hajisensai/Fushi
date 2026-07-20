import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Luna ThreadCreate is published independently from filtered output', () {
    final String injector = File(
      '../native/galgame_voice_hook/injector/injector_main.cpp',
    ).readAsStringSync();
    final String threadCreate = _between(
      injector,
      'void LunaThreadCreate(',
      'void LunaThreadRemove(',
    );
    final String output = _between(
      injector,
      'void LunaOutput(',
      'void LunaConnect(',
    );

    expect(threadCreate, contains('LunaTextThreadId('));
    expect(threadCreate, contains('kTextEventThreadDiscovered'));
    expect(threadCreate, contains('WriteLunaTextEvent('));
    expect(threadCreate, isNot(contains('LunaShouldWriteLine(')));
    expect(output, contains('LunaShouldWriteLine('));
  });

  test('IPC v7 event kind is synchronized through the Windows channel', () {
    final String nativeHeader = File(
      '../native/galgame_voice_hook/include/voice_hook_ipc.h',
    ).readAsStringSync();
    final String runnerHeader =
        File('windows/runner/voice_hook_ipc.h').readAsStringSync();
    final String runner =
        File('windows/runner/voice_hook_reader.cpp').readAsStringSync();
    final String channel =
        File('windows/runner/flutter_window.cpp').readAsStringSync();

    for (final String header in <String>[nativeHeader, runnerHeader]) {
      expect(header, contains('kSharedVersion = 7'));
      expect(header, contains('kTextEventThreadDiscovered = 1'));
      expect(header, contains('uint32_t event_kind'));
    }
    expect(
      _structDeclarations(nativeHeader, 'TextSlot'),
      _structDeclarations(runnerHeader, 'TextSlot'),
      reason: 'injector 与 runner 的 TextSlot 字段顺序必须逐项一致',
    );
    expect(runner, contains('line.event_kind = slot->event_kind'));
    expect(channel, contains('flutter::EncodableValue("eventKind")'));
  });
}

List<String> _structDeclarations(String source, String name) {
  final String body = _between(source, 'struct $name {', '};');
  return RegExp(
    r'^\s*(?:volatile\s+)?(?:uint64_t|uint32_t|char|wchar_t)\s+'
    r'[a-zA-Z0-9_]+(?:\[[a-zA-Z0-9_]+\])?\s*;',
    multiLine: true,
  ).allMatches(body).map((Match match) {
    return match.group(0)!.replaceAll(RegExp(r'\s+'), ' ').trim();
  }).toList();
}

String _between(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
