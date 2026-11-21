import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { findBareHeavyCommand, splitSegments } from './require_heavy_lease.mjs';

test('bare heavy flutter / gradle runs are caught', () => {
  for (const cmd of [
    'flutter test test/a_test.dart --no-pub',
    'cd fushi && flutter analyze --no-pub',
    '& D:\\flutter\\bin\\flutter.bat test test/x_test.dart',
    '"D:/flutter/bin/flutter" --no-color build windows',
    'fvm flutter test',
    'HTTPS_PROXY=http://x flutter test test/y_test.dart | tail -5',
    '.\\gradlew.bat :app:assembleRelease',
    'cd android; ./gradlew assembleDebug',
  ]) {
    assert.notEqual(findBareHeavyCommand(cmd), null, cmd);
  }
});

test('wrapped, self-leasing, light or unrelated commands pass', () => {
  for (const cmd of [
    'dart tool/heavy.dart -- flutter test test/a_test.dart --no-pub',
    'dart tool/pre_push_check.dart',
    'dart tool/flutter_test_failures.dart --output-dir=x',
    'flutter pub get',
    'flutter --version',
    'grep -n "flutter test" docs/agent/fast-workflow.md',
    'echo flutter test',
    'git commit -m "flutter test fix"',
    'FUSHI_HEAVY=off flutter test test/a_test.dart',
    '',
    // Quoted search patterns are arguments, not segments (2026-11-21 audit).
    'grep -n "flutter build apk\\|flutter build appbundle\\|doNotStrip" .github/workflows/*.yml | head',
    'grep -oE "FLUTTER TEST VERDICT: FAILED[^(]*" $S/o1.log; echo done',
    "grep -n 'gradlew assembleRelease|flutter test' docs/agent/build.md",
    'git log -1 --format="%H; flutter test" origin/develop',
    // Heredoc bodies are data written to a file, not commands.
    "cat > x.py <<'EOF'\nimport subprocess\n# flutter test test/a_test.dart\nEOF\npython -I x.py",
  ]) {
    assert.equal(findBareHeavyCommand(cmd), null, cmd);
  }
});

test('real runs after quotes or heredocs are still caught', () => {
  for (const cmd of [
    'grep -c "x|y" a.txt; flutter test test/a_test.dart',
    "cat > x.txt <<'EOF'\nhello\nEOF\nflutter analyze --no-pub",
    '"C:/Program Files/flutter/bin/flutter" test test/a_test.dart',
    'echo "a;b" && ./gradlew assembleDebug',
  ]) {
    assert.notEqual(findBareHeavyCommand(cmd), null, cmd);
  }
});

test('splitSegments keeps quoted separators inside their segment', () => {
  assert.deepEqual(splitSegments('a "b|c" && d \'e;f\' ; g'), ['a "b|c"', "d 'e;f'", 'g']);
  assert.deepEqual(splitSegments("cat <<EOF\nx | y\nEOF\nz"), ['cat <<EOF', 'z']);
});

test('the hook answers deny JSON on stdin input, nothing otherwise', () => {
  const hook = fileURLToPath(new URL('./require_heavy_lease.mjs', import.meta.url));
  const run = (command) =>
    spawnSync(process.execPath, [hook], {
      input: JSON.stringify({ tool_name: 'Bash', tool_input: { command } }),
      encoding: 'utf8',
    });
  const denied = run('flutter test test/a_test.dart');
  assert.equal(denied.status, 0);
  const out = JSON.parse(denied.stdout);
  assert.equal(out.hookSpecificOutput.permissionDecision, 'deny');
  assert.match(out.hookSpecificOutput.permissionDecisionReason, /heavy\.dart/);
  const allowed = run('dart tool/heavy.dart -- flutter test');
  assert.equal(allowed.status, 0);
  assert.equal(allowed.stdout, '');
});
