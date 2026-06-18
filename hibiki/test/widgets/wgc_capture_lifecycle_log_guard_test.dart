import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _readTextureBridgeSource() {
  final File? file = <String>[
    'packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
    '../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
  ].map(File.new).cast<File?>().firstWhere(
        (File? f) => f != null && f.existsSync(),
        orElse: () => null,
      );
  expect(file, isNotNull, reason: 'texture_bridge.cc not found');
  return file!.readAsStringSync();
}

String _methodBody(String src, String signature, String nextMarker) {
  final int start = src.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: '$signature not found');
  final int end = src.indexOf(nextMarker, start + signature.length);
  expect(end, greaterThan(start),
      reason: '$signature must be bounded by $nextMarker');
  return src.substring(start, end);
}

final RegExp _eventPattern = RegExp(r'\bevt=([^\s]+)');
final RegExp _poolPattern = RegExp(r'\bpool=([^\s]+)');
final RegExp _generationPattern = RegExp(r'\bgeneration=(\d+)');

const Set<String> _bannedLifecycleEvents = <String>{
  'retire-defer-fail',
  'remove-before-close-fail',
  'remove-before-close-closed-unexpected',
  'retire-remove-closed',
  'remove-before-close-start',
  'remove-before-close-done',
  'handler-release-done',
};

const List<String> _requiredClosureEvents = <String>[
  'pump-stop-start',
  'pump-remove-tick-done',
  'pump-stop-done',
  'session-close-done',
  'pool-close-done',
  'retire-register-done',
];

class _PoolClosure {
  _PoolClosure(this.pool, this.generation);

  final String pool;
  final String generation;
  final Map<String, int> eventIndexes = <String, int>{};
}

bool _isValidWgcLifecycleLog(String log) {
  final Map<String, _PoolClosure> closures = <String, _PoolClosure>{};
  final List<String> lines = log
      .split(RegExp(r'\r?\n'))
      .map((String line) => line.trim())
      .where((String line) => line.isNotEmpty)
      .toList();

  for (int i = 0; i < lines.length; i += 1) {
    final String line = lines[i];
    final String? event = _eventPattern.firstMatch(line)?.group(1);
    if (event == null) {
      continue;
    }
    if (_bannedLifecycleEvents.contains(event) ||
        line.contains('defer_enqueue=0')) {
      return false;
    }

    if (!_requiredClosureEvents.contains(event)) {
      continue;
    }
    final String? pool = _poolPattern.firstMatch(line)?.group(1);
    final String? generation = _generationPattern.firstMatch(line)?.group(1);
    if (pool == null || generation == null) {
      return false;
    }
    final String key = '$pool#$generation';
    closures
        .putIfAbsent(key, () => _PoolClosure(pool, generation))
        .eventIndexes[event] = i;
  }

  if (closures.isEmpty) {
    return false;
  }
  for (final _PoolClosure closure in closures.values) {
    int previous = -1;
    for (final String event in _requiredClosureEvents) {
      final int? index = closure.eventIndexes[event];
      if (index == null || index <= previous) {
        return false;
      }
      previous = index;
    }
  }
  return true;
}

void main() {
  test(
      'TODO-506 active WGC pool logs carry enough attribution to explain skips',
      () {
    final String src = _readTextureBridgeSource();

    for (final String event in <String>[
      'start-skip-running',
      'surface-size-changed',
      'frame-first-success',
      'frame-needs-update',
      'frame-noop',
      'pump-start',
      'pump-stop-start',
      'pump-remove-tick-done',
      'pump-stop-done',
      'recreate-skip-samesize',
    ]) {
      expect(src.contains('WgcLog::Write("$event"'), isTrue,
          reason: 'TODO-506 must make $event visible in WGC.captureLog');
    }

    final String startBody = _methodBody(
      src,
      'bool TextureBridge::Start()',
      'bool TextureBridge::CreateAndStartFramePoolLocked()',
    );
    expect(startBody.contains('BridgeStateDetail'), isTrue,
        reason:
            'start/start-skip-running must use the shared attribution detail builder');
    for (final String field in <String>[
      'GenerationDetail',
      'pool_size',
      'capture_item_size',
      'needs_update',
      'bridge',
    ]) {
      expect(src.contains(field), isTrue,
          reason: 'start/start-skip-running log must include $field');
    }

    final String recreateBody = _methodBody(
      src,
      'void TextureBridge::RecreateFramePoolLocked()',
      'void TextureBridge::Stop()',
    );
    expect(recreateBody.contains('current_size'), isTrue,
        reason: 'recreate-skip-samesize must log current capture item size');
    expect(recreateBody.contains('lifetime_size'), isTrue,
        reason:
            'recreate-skip-samesize must log existing frame-pool lifetime size');

    final String frameBody = src.substring(
      src.indexOf('void TextureBridge::PumpFrameLocked('),
      src.indexOf('bool TextureBridge::ShouldDropFrame()'),
    );
    expect(frameBody.contains('FrameHandlerDetail'), isTrue,
        reason:
            'PumpFrameLocked must use the shared frame attribution detail builder');
    for (final String field in <String>[
      'GenerationDetail',
      'in_handler',
      'retiring',
      'has_frame',
      'needs_update',
    ]) {
      expect(src.contains(field), isTrue,
          reason: 'PumpFrameLocked low-frequency logs must include $field');
    }
  });

  test('timer-pump WGC retire removes Tick before closing capture resources',
      () {
    final String src = _readTextureBridgeSource();
    final String retireBody = _methodBody(
      src,
      'void TextureBridge::RetireFramePoolLocked(',
      'void FinalizeFramePoolLifetime(',
    );

    expect(retireBody.contains('StopPumpLocked(lifetime, reason)'), isTrue,
        reason: 'retire must stop/remove the timer pump before finalizing');
    expect(retireBody.contains('TryEnqueue'), isFalse,
        reason:
            'FrameArrived handler-stack defer is not part of the default timer pump path');
    expect(src.contains('add_FrameArrived'), isFalse,
        reason: 'default WGC path must not subscribe to FrameArrived');
    expect(src.contains('WgcLog::Write("retire-defer-fail"'), isFalse,
        reason: 'retire-defer-fail belongs to the removed handler-stack path');
    expect(src.contains('defer_enqueue=0'), isFalse,
        reason: 'timer pump path must not use handler-stack enqueue fallback');
  });

  test('WGC lifecycle log fixture rejects old event-driven negative events',
      () {
    const String userFailureLog = '''
2026-06-17T11:00:00.000Z tid=42 evt=create-pool pool=0xABC generation=9
2026-06-17T11:00:00.100Z tid=42 evt=retire pool=0xABC reason=recreate
2026-06-17T11:00:00.101Z tid=42 evt=remove-before-close-start pool=0xABC generation=9
2026-06-17T11:00:00.102Z tid=42 evt=handler-release-done pool=0xABC generation=9
2026-06-17T11:00:00.104Z tid=42 evt=session-close-done pool=0xABC generation=9
2026-06-17T11:00:00.105Z tid=42 evt=pool-close-done pool=0xABC generation=9
2026-06-17T11:00:00.106Z tid=42 evt=retire-register-done pool=0xABC generation=9
''';

    expect(_isValidWgcLifecycleLog(userFailureLog), isFalse);
  });

  test('WGC lifecycle log fixture accepts per-pool successful closure', () {
    const String successLog = '''
2026-06-17T11:00:00.000Z tid=42 evt=create-pool pool=0xABC generation=9
2026-06-17T11:00:00.100Z tid=42 evt=retire pool=0xABC reason=recreate
2026-06-17T11:00:00.101Z tid=42 evt=pump-stop-start pool=0xABC generation=9
2026-06-17T11:00:00.102Z tid=42 evt=pump-remove-tick-done pool=0xABC generation=9 hr=0x00000000
2026-06-17T11:00:00.103Z tid=42 evt=pump-stop-done pool=0xABC generation=9
2026-06-17T11:00:00.104Z tid=42 evt=session-close-done pool=0xABC generation=9 hr=0x00000000
2026-06-17T11:00:00.105Z tid=42 evt=pool-close-done pool=0xABC generation=9 hr=0x00000000
2026-06-17T11:00:00.106Z tid=42 evt=retire-register-done pool=0xABC generation=9
''';

    expect(_isValidWgcLifecycleLog(successLog), isTrue);
  });
}
