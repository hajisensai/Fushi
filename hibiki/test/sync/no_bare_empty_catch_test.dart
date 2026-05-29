import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Anti-recurrence guard. A bare empty `catch (...) {}` silently swallows an
/// error and is exactly how this session's silent-failure bugs (HBK-AUDIT-163
/// /164/165/166) hid real failures. Every catch in the sync layer must either
/// do something (log via ErrorLogService/debugPrint, rethrow, set state) or, if
/// the failure is genuinely best-effort, document that intent with a comment
/// inside the braces — which also stops it matching this guard.
void main() {
  test('no bare empty catch blocks in lib/src/sync', () {
    final Directory dir = Directory('lib/src/sync');
    expect(dir.existsSync(), isTrue, reason: 'run from the hibiki/ package root');

    // Matches `catch (...) {}`, `catch (...) { }`, `catch (...) {\n}` — i.e. a
    // body that is only whitespace. A `{/* reason */}` body does NOT match.
    final RegExp bareCatch = RegExp(r'catch\s*\([^)]*\)\s*\{\s*\}');
    final List<String> offenders = <String>[];

    for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String content = entity.readAsStringSync();
      for (final RegExpMatch m in bareCatch.allMatches(content)) {
        final int line = '\n'.allMatches(content.substring(0, m.start)).length + 1;
        offenders.add('${entity.path}:$line');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Bare empty catch blocks swallow errors silently. Log them '
          '(ErrorLogService/debugPrint), rethrow, or document the best-effort '
          'intent with a comment inside the braces. Offenders:\n'
          '${offenders.join('\n')}',
    );
  });
}
