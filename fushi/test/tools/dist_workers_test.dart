// Contract of the dist_test worker config and the ssh hardening every
// connection carries (docs/specs/2026-10-24-distributed-unit-tests.md §7.1).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/dist_plan.dart';
import '../../tool/test_flow/dist_workers.dart';

void main() {
  test('every ssh call turns off agent / X11 / port forwarding', () {
    final String joined = kDistSshOptions.join(' ');
    for (final String option in <String>[
      'ForwardAgent=no',
      'ForwardX11=no',
      'ClearAllForwardings=yes',
      'PermitLocalCommand=no',
      'BatchMode=yes',
    ]) {
      expect(joined, contains('-o $option'));
    }
  });

  test('the checked-in example config parses', () {
    final List<DistWorkerConfig> workers = readDistWorkers(
      File('tool/dist_test/workers.example.json').readAsStringSync(),
    );
    expect(
      workers.map((DistWorkerConfig w) => w.kind),
      containsAll(DistWorkerKind.values),
    );
    final DistWorkerConfig mac = workers.firstWhere(
      (DistWorkerConfig w) => w.kind != DistWorkerKind.local,
    );
    expect(mac.platform, DistPlatform.macos);
    expect(mac.workdir, 'fushi-dist/work');
  });

  group('rejects', () {
    void rejects(String json) => expect(
      () => readDistWorkers(json),
      throwsA(isA<DistConfigError>()),
      reason: json,
    );

    test('bad names, kinds, hosts, paths, env keys, duplicates', () {
      rejects(
        '{"workers": [{"name": "a b", "kind": "local", "os": "windows"}]}',
      );
      rejects('{"workers": [{"name": "a", "kind": "rdp", "os": "windows"}]}');
      rejects(
        '{"workers": [{"name": "a", "kind": "ssh-trusted", '
        '"os": "macos", "host": "host-without-user"}]}',
      );
      rejects(
        '{"workers": [{"name": "a", "kind": "ssh-trusted", '
        '"os": "macos", "host": "u@h", "workdir": "../escape"}]}',
      );
      rejects(
        '{"workers": [{"name": "a", "kind": "ssh-trusted", '
        '"os": "macos", "host": "u@h", "path": ["\$(evil)"]}]}',
      );
      rejects(
        '{"workers": [{"name": "a", "kind": "ssh-trusted", '
        '"os": "macos", "host": "u@h", "prepareEnv": {"a;b": "x"}}]}',
      );
      rejects(
        '{"workers": [{"name": "a", "kind": "local", "os": "windows"}, '
        '{"name": "a", "kind": "local", "os": "windows"}]}',
      );
      rejects(
        '{"workers": [{"name": "a", "kind": "local", "os": "windows"}, '
        '{"name": "b", "kind": "local", "os": "windows"}]}',
      );
    });
  });

  test('shellQuote survives single quotes', () {
    expect(shellQuote("it's"), r"'it'\''s'");
    expect(shellQuote(r'$HOME'), r"'$HOME'");
  });
}
