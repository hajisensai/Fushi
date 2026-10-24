/// Workers of `tool/dist_test.dart`: the local checkout, and machines reached
/// over ssh. Config: `tool/dist_test/workers.local.json` (git-ignored; see
/// `workers.example.json` next to it).
///
/// Connections only ever go from this machine to a worker. Every ssh / git
/// call carries [kDistSshOptions], which turn off agent, X11 and port
/// forwarding: with agent forwarding on, an admin of the worker could use this
/// machine's agent to log in elsewhere as you.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dist_plan.dart';
import 'dist_snapshot.dart';
import 'flutter_sdk_executables.dart';
import 'heavy_budget.dart';
import 'heavy_lease.dart';

/// Options on every ssh connection (also used as `GIT_SSH_COMMAND` for the
/// snapshot push).
const List<String> kDistSshOptions = <String>[
  '-o', 'BatchMode=yes', //
  '-o', 'ForwardAgent=no',
  '-o', 'ForwardX11=no',
  '-o', 'ClearAllForwardings=yes',
  '-o', 'PermitLocalCommand=no',
  '-o', 'ConnectTimeout=15',
  '-o', 'ServerAliveInterval=15',
  '-o', 'ServerAliveCountMax=4',
];

/// Path characters per local `flutter test` process (cmd.exe stops at 8191).
const int kLocalMaxCommandChars = 6000;

/// The ssh client for remote commands. On Windows the system OpenSSH
/// (native Win32 pipes): Git for Windows' msys `ssh.exe`, which PATH often
/// finds first, emulates select() over the pipes Dart hands it and stalled a
/// batch mid-line (the remote run had finished; the stream never arrived).
/// `FUSHI_DIST_SSH` overrides. The snapshot push keeps git's own ssh.
String distSshExecutable([Map<String, String>? environment]) {
  final Map<String, String> env = environment ?? Platform.environment;
  final String? override = env['FUSHI_DIST_SSH'];
  if (override != null && override.isNotEmpty) return override;
  if (Platform.isWindows) {
    final String system =
        '${env['SystemRoot'] ?? r'C:\Windows'}'
        r'\System32\OpenSSH\ssh.exe';
    if (File(system).existsSync()) return system;
  }
  return 'ssh';
}

/// ssh's own exit code for connection-level failures.
const int kSshConnectionFailure = 255;

enum DistWorkerKind {
  /// This checkout, through the machine-wide heavy lease.
  local,

  /// A machine of your own reached by ssh with a normal shell.
  sshTrusted,
}

class DistConfigError implements Exception {
  DistConfigError(this.message);
  final String message;
  @override
  String toString() => message;
}

class DistWorkerConfig {
  const DistWorkerConfig({
    required this.name,
    required this.kind,
    required this.platform,
    this.host,
    this.identity,
    this.workdir = 'fushi-dist/work',
    this.seedRepo,
    this.path = const <String>[],
    this.prepareEnv = const <String, String>{},
    this.concurrency,
    this.capabilities = const <String>{},
    this.slots = 1,
    this.nativePeer,
  });

  final String name;
  final DistWorkerKind kind;
  final DistPlatform platform;

  /// `user@host` for ssh workers.
  final String? host;

  /// Private key for this worker only (`-i`, with `IdentitiesOnly=yes`).
  final String? identity;

  /// Checkout directory on the worker, relative to the remote home.
  final String workdir;

  /// Existing clone on the worker (relative to its home) whose objects seed a
  /// fresh [workdir] through `objects/info/alternates`, so the first push only
  /// sends what that clone lacks.
  final String? seedRepo;

  /// Entries prepended to the remote PATH (a non-interactive ssh shell does
  /// not read the login profile). `$HOME` is expanded remotely.
  final List<String> path;

  /// Extra environment for the prepare step only (pub get / native builds /
  /// hook downloads), e.g. a proxy. Tests run without it, as on CI.
  final Map<String, String> prepareEnv;

  /// `flutter test --concurrency`; null = flutter's default.
  final int? concurrency;
  final Set<String> capabilities;

  /// Independent checkouts on this machine, each running its own
  /// `flutter test`. One process compiles its suites one at a time (measured
  /// on the M4 Mac: ~1.4 s per suite whatever `--concurrency` is), so more
  /// processes is what uses more cores; they cannot share a checkout (they
  /// fight over build/native_assets). ssh workers only.
  final int slots;

  /// Primary slot's checkout (relative to the remote home) a secondary slot
  /// copies matching native libraries from instead of building them again.
  final String? nativePeer;

  /// Slot [index] (2..[slots]) of this machine: its own checkout next to the
  /// primary one, seeded from the primary's objects.
  DistWorkerConfig slot(int index) => DistWorkerConfig(
    name: '$name.$index',
    kind: kind,
    platform: platform,
    host: host,
    identity: identity,
    workdir: '$workdir-$index',
    seedRepo: workdir,
    path: path,
    prepareEnv: prepareEnv,
    concurrency: concurrency,
    capabilities: capabilities,
    nativePeer: workdir,
  );

  static final RegExp _name = RegExp(r'^[A-Za-z0-9_-]+$');
  static final RegExp _host = RegExp(r'^[A-Za-z0-9_.-]+@[A-Za-z0-9_.:-]+$');
  static final RegExp _relPath = RegExp(r'^[A-Za-z0-9_./-]+$');
  static final RegExp _pathEntry = RegExp(r'^[A-Za-z0-9_./$~-]+$');
  static final RegExp _envKey = RegExp(r'^[A-Z_][A-Z0-9_]*$');

  static DistWorkerConfig fromJson(Map<String, Object?> json) {
    String str(String key, {bool required = false}) {
      final Object? v = json[key];
      if (v is String) return v;
      if (required || v != null) {
        throw DistConfigError(
          'worker ${json['name']}: "$key" must be a '
          'string',
        );
      }
      return '';
    }

    final String name = str('name', required: true);
    if (!_name.hasMatch(name)) {
      throw DistConfigError('worker name "$name": use [A-Za-z0-9_-]');
    }
    final DistWorkerKind kind = switch (str('kind', required: true)) {
      'local' => DistWorkerKind.local,
      'ssh-trusted' => DistWorkerKind.sshTrusted,
      final String other => throw DistConfigError(
        'worker $name: unknown kind "$other" (local / ssh-trusted)',
      ),
    };
    final DistPlatform platform = switch (str('os', required: true)) {
      'windows' => DistPlatform.windows,
      'macos' => DistPlatform.macos,
      final String other => throw DistConfigError(
        'worker $name: unknown os "$other"',
      ),
    };
    String? host;
    if (kind != DistWorkerKind.local) {
      host = str('host', required: true);
      if (!_host.hasMatch(host)) {
        throw DistConfigError('worker $name: host must be user@host');
      }
    }
    final String workdir = json['workdir'] == null
        ? 'fushi-dist/work'
        : str('workdir');
    final String seed = str('seedRepo');
    for (final String p in <String>[workdir, if (seed.isNotEmpty) seed]) {
      if (!_relPath.hasMatch(p) || p.split('/').contains('..')) {
        throw DistConfigError(
          'worker $name: "$p" must be a plain path '
          'relative to the remote home',
        );
      }
    }
    final List<String> path = <String>[
      for (final Object? e in (json['path'] as List<Object?>?) ?? <Object?>[])
        e is String && _pathEntry.hasMatch(e)
            ? e
            : throw DistConfigError('worker $name: bad path entry "$e"'),
    ];
    final Map<String, String> prepareEnv = <String, String>{};
    final Object? env = json['prepareEnv'];
    if (env is Map<String, Object?>) {
      for (final MapEntry<String, Object?> e in env.entries) {
        if (!_envKey.hasMatch(e.key) || e.value is! String) {
          throw DistConfigError('worker $name: bad prepareEnv "${e.key}"');
        }
        prepareEnv[e.key] = e.value! as String;
      }
    }
    final Object? concurrency = json['concurrency'];
    if (concurrency != null && (concurrency is! int || concurrency < 1)) {
      throw DistConfigError('worker $name: concurrency must be >= 1');
    }
    final Object? slots = json['slots'];
    if (slots != null && (slots is! int || slots < 1 || slots > 8)) {
      throw DistConfigError('worker $name: slots must be 1..8');
    }
    if (kind == DistWorkerKind.local && slots != null && slots != 1) {
      throw DistConfigError('worker $name: a local worker has one slot');
    }
    final String identity = str('identity');
    return DistWorkerConfig(
      name: name,
      kind: kind,
      platform: platform,
      host: host,
      identity: identity.isEmpty ? null : identity,
      workdir: workdir,
      seedRepo: seed.isEmpty ? null : seed,
      path: path,
      prepareEnv: prepareEnv,
      concurrency: concurrency as int?,
      capabilities: <String>{
        for (final Object? c
            in (json['capabilities'] as List<Object?>?) ?? <Object?>[])
          if (c is String) c,
      },
      slots: (slots as int?) ?? 1,
    );
  }
}

/// Reads `{"workers": [...]}`.
List<DistWorkerConfig> readDistWorkers(String text) {
  final Object? decoded = jsonDecode(text);
  final Object? workers = decoded is Map<String, Object?>
      ? decoded['workers']
      : null;
  if (workers is! List<Object?>) {
    throw DistConfigError('expected {"workers": [...]}');
  }
  final List<DistWorkerConfig> configs = <DistWorkerConfig>[
    for (final Object? w in workers)
      w is Map<String, Object?>
          ? DistWorkerConfig.fromJson(w)
          : throw DistConfigError('worker entries must be objects'),
  ];
  final Set<String> names = <String>{};
  for (final DistWorkerConfig c in configs) {
    if (!names.add(c.name)) throw DistConfigError('duplicate worker ${c.name}');
  }
  if (configs
          .where((DistWorkerConfig c) => c.kind == DistWorkerKind.local)
          .length >
      1) {
    throw DistConfigError('at most one local worker');
  }
  return configs;
}

/// POSIX single-quote.
String shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// The raw result of one batch process.
class DistBatchRun {
  const DistBatchRun({
    required this.exitCode,
    required this.lines,
    this.infraError,
  });

  final int exitCode;
  final List<String> lines;

  /// The run did not get a fair chance (connection lost, timed out, killed);
  /// the scheduler may hand the batch to another worker.
  final String? infraError;
}

class DistWorkerError implements Exception {
  DistWorkerError(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class DistWorker {
  DistWorker(this.config);

  final DistWorkerConfig config;

  String get name => config.name;

  bool eligible(DistBatch batch) =>
      batch.eligibleFor(config.platform, config.capabilities);

  /// Gets the worker onto [snapshot] with dependencies and native libraries
  /// ready. Throws [DistWorkerError]; [log] receives the step output.
  Future<void> prepare(DistSnapshot snapshot, String runId, IOSink log);

  Future<DistBatchRun> run(
    DistBatch batch, {
    required List<String> flutterArgs,
    required IOSink stderrLog,
    required Duration timeout,
  });

  /// Kills whatever batch is in flight (Ctrl-C).
  Future<void> cancel();

  /// Drops run-scoped state (snapshot ref, lease).
  Future<void> finish(String runId);

  /// One line for `--status`.
  Future<String> status();
}

/// The workers of one config entry: one per slot.
List<DistWorker> createDistWorkers(
  DistWorkerConfig config, {
  required String repoRoot,
}) {
  switch (config.kind) {
    case DistWorkerKind.local:
      return <DistWorker>[LocalDistWorker(config, repoRoot: repoRoot)];
    case DistWorkerKind.sshTrusted:
      final SshDistWorker primary = SshDistWorker(config, repoRoot: repoRoot);
      return <DistWorker>[
        primary,
        for (int i = 2; i <= config.slots; i++)
          SshDistWorker(config.slot(i), repoRoot: repoRoot, primary: primary),
      ];
  }
}

/// Collects a child's stdout lines, mirrors its stderr into [stderrLog], and
/// enforces [timeout] by calling [kill].
Future<DistBatchRun> _drive(
  Process process, {
  required IOSink stderrLog,
  required Duration timeout,
  required Future<void> Function() kill,
  required int Function(int exitCode)? connectionFailure,
}) async {
  const Utf8Decoder decoder = Utf8Decoder(allowMalformed: true);
  final List<String> lines = <String>[];
  final Future<void> out = process.stdout
      .transform(decoder)
      .transform(const LineSplitter())
      .forEach(lines.add);
  final Future<void> err = process.stderr
      .transform(decoder)
      .forEach(stderrLog.write);
  bool timedOut = false;
  final Timer timer = Timer(timeout, () {
    timedOut = true;
    unawaited(kill());
  });
  final int exitCode = await process.exitCode;
  timer.cancel();
  await Future.wait(<Future<void>>[out, err]);
  String? infra;
  if (timedOut) {
    infra = 'timed out after ${timeout.inMinutes} min and was killed';
  } else if (connectionFailure != null &&
      connectionFailure(exitCode) == kSshConnectionFailure) {
    infra = 'ssh connection failed (exit $exitCode)';
  }
  return DistBatchRun(exitCode: exitCode, lines: lines, infraError: infra);
}

class LocalDistWorker extends DistWorker {
  LocalDistWorker(super.config, {required this.repoRoot});

  final String repoRoot;
  HeavyLease? _lease;
  Process? _process;

  String get _fushiDir => '$repoRoot/fushi';

  @override
  Future<void> prepare(DistSnapshot snapshot, String runId, IOSink log) async {
    // pub workspace: the resolution lands in the workspace root's .dart_tool.
    if (!File('$repoRoot/.dart_tool/package_config.json').existsSync() &&
        !File('$_fushiDir/.dart_tool/package_config.json').existsSync()) {
      throw DistWorkerError(
        'local checkout has no pub get yet; run '
        'tool/setup_worktree.ps1 first',
      );
    }
    if (Platform.isWindows) {
      final ProcessResult r = await Process.run('powershell', <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        '$repoRoot/tool/native_libs.ps1',
      ], workingDirectory: repoRoot);
      log
        ..write(r.stdout)
        ..write(r.stderr);
      if (r.exitCode != 0) {
        throw DistWorkerError('tool/native_libs.ps1 failed (${r.exitCode})');
      }
    }
    // One flutter test at a time in this checkout, like every other heavy
    // run on this machine; held for the whole dist run.
    _lease = await acquireHeavyLease(
      need: heavyNeedFor(HeavyKind.test),
      label: 'dist_test local worker $runId',
      worktreeRoot: repoRoot,
    );
  }

  @override
  Future<DistBatchRun> run(
    DistBatch batch, {
    required List<String> flutterArgs,
    required IOSink stderrLog,
    required Duration timeout,
  }) async {
    // cmd.exe (flutter.bat) caps a command line at 8191 characters, so a big
    // batch runs as several back-to-back processes; their event streams are
    // concatenated (each starts with its own `start` event).
    final List<String> lines = <String>[];
    final Stopwatch elapsed = Stopwatch()..start();
    int exitCode = 0;
    for (final List<String> chunk in splitByPathChars(
      batch.files,
      kLocalMaxCommandChars,
    )) {
      final Process process = await Process.start(
        FlutterSdkExecutables.current().flutter(),
        <String>[
          'test',
          '--no-pub',
          '--reporter',
          'json',
          // The heavy lease books memory for heavy.dart's default.
          '--concurrency=${config.concurrency ?? kDefaultTestConcurrency}',
          ...flutterArgs,
          ...chunk,
        ],
        workingDirectory: _fushiDir,
        runInShell: Platform.isWindows,
      );
      _process = process;
      await process.stdin.close();
      final DistBatchRun run;
      try {
        final Duration left = timeout - elapsed.elapsed;
        run = await _drive(
          process,
          stderrLog: stderrLog,
          timeout: left.isNegative ? Duration.zero : left,
          kill: () async => _killTree(process),
          connectionFailure: null,
        );
      } finally {
        _process = null;
      }
      lines.addAll(run.lines);
      if (exitCode == 0) exitCode = run.exitCode;
      if (run.infraError != null) {
        return DistBatchRun(
          exitCode: run.exitCode,
          lines: lines,
          infraError: run.infraError,
        );
      }
    }
    return DistBatchRun(exitCode: exitCode, lines: lines);
  }

  void _killTree(Process p) {
    // By exact PID, never by process name: dart.exe is also the IDE's
    // analysis server.
    if (Platform.isWindows) {
      Process.runSync('taskkill', <String>['/PID', '${p.pid}', '/T', '/F']);
    } else {
      p.kill(ProcessSignal.sigkill);
    }
  }

  @override
  Future<void> cancel() async {
    final Process? p = _process;
    if (p != null) _killTree(p);
  }

  @override
  Future<void> finish(String runId) async {
    _lease?.release();
    _lease = null;
  }

  @override
  Future<String> status() async {
    final List<HeavyHolder> holders = readHeavyHolders(
      heavyStateDir(),
      heavySlotCount(readMemorySnapshot()),
    );
    return 'local, ${Platform.numberOfProcessors} cores, '
        '${holders.length} heavy slot(s) busy';
  }
}

class SshDistWorker extends DistWorker {
  SshDistWorker(super.config, {required this.repoRoot, this.primary});

  final String repoRoot;

  /// Set on secondary slots: they prepare after the primary, so its native
  /// libraries can be copied instead of built twice in parallel.
  final SshDistWorker? primary;
  final Completer<void> _prepared = Completer<void>();
  Process? _process;

  List<String> get _sshBase => <String>[
    ...kDistSshOptions,
    if (config.identity != null) ...<String>[
      '-i',
      config.identity!,
      '-o',
      'IdentitiesOnly=yes',
    ],
    config.host!,
  ];

  /// Remote shell prefix that only sets PATH.
  String get _pathPrefix => config.path.isEmpty
      ? ''
      : 'export PATH="${config.path.join(':')}:\$PATH"; ';

  /// Remote shell prefix: PATH, then into the checkout.
  String get _prefix =>
      '${_pathPrefix}cd "\$HOME"/${shellQuote(config.workdir)} && ';

  /// `-n`: no stdin to forward, so ssh can finish as soon as the remote
  /// command does.
  Future<ProcessResult> _ssh(String remoteCommand) => Process.run(
    distSshExecutable(),
    <String>['-n', ..._sshBase, remoteCommand],
  );

  Future<void> _sshChecked(String step, String command, IOSink log) async {
    final ProcessResult r = await _ssh(command);
    log
      ..writeln('== $step (exit ${r.exitCode})')
      ..write(r.stdout)
      ..write(r.stderr);
    if (r.exitCode != 0) {
      final String tail = '${r.stderr}'.trim().split('\n').last;
      throw DistWorkerError(
        '$step failed on $name (exit ${r.exitCode}): '
        '$tail',
      );
    }
  }

  @override
  Future<void> prepare(DistSnapshot snapshot, String runId, IOSink log) async {
    await primary?._prepared.future;
    try {
      await _prepare(snapshot, runId, log);
    } finally {
      if (!_prepared.isCompleted) _prepared.complete();
    }
  }

  Future<void> _prepare(DistSnapshot snapshot, String runId, IOSink log) async {
    final String workdir = shellQuote(config.workdir);
    final String seed = config.seedRepo == null
        ? ''
        : ' && { [ -s .git/objects/info/alternates ] || '
              '[ ! -d "\$HOME"/${shellQuote(config.seedRepo!)}/.git/objects ] || '
              'echo "\$HOME"/${shellQuote(config.seedRepo!)}/.git/objects '
              '> .git/objects/info/alternates; }';
    await _sshChecked(
      'init',
      'mkdir -p "\$HOME"/$workdir && cd "\$HOME"/$workdir && '
          '{ [ -d .git ] || git init -q; }$seed && '
          '{ [ ! -f fushi/tool/dist_test/worker_kill.sh ] || '
          'bash fushi/tool/dist_test/worker_kill.sh; }',
      log,
    );

    final String sshCommand = <String>[
      'ssh',
      for (final String a in _sshBase.sublist(0, _sshBase.length - 1))
        shellQuote(a),
    ].join(' ');
    final ProcessResult push = await Process.run(
      'git',
      <String>[
        'push',
        '--quiet',
        '${config.host}:${config.workdir}',
        '${snapshot.commit}:refs/dist/$runId',
      ],
      workingDirectory: repoRoot,
      environment: <String, String>{'GIT_SSH_COMMAND': sshCommand},
    );
    log
      ..writeln('== push (exit ${push.exitCode})')
      ..write(push.stdout)
      ..write(push.stderr);
    if (push.exitCode != 0) {
      throw DistWorkerError(
        'git push to $name failed: '
        '${'${push.stderr}'.trim()}',
      );
    }

    final String env = <String>[
      for (final MapEntry<String, String> e in config.prepareEnv.entries)
        '${e.key}=${shellQuote(e.value)}',
      if (config.nativePeer != null)
        'DIST_NATIVE_PEER="\$HOME"/${shellQuote(config.nativePeer!)}',
    ].join(' ');
    await _sshChecked(
      'checkout',
      '${_prefix}git checkout -q --detach --force ${snapshot.commit} && '
          "git clean -qfd -e 'native/*/prebuilt/' -e 'native/*/target/'",
      log,
    );
    // Output goes to a file on the worker and is printed afterwards: pub /
    // cargo / flutter can leave a daemon behind that inherits stdout, and an
    // inherited ssh channel keeps the connection open forever (seen on the
    // Mac: prepare finished, ssh never returned).
    await _sshChecked(
      'prepare',
      '$_prefix${env.isEmpty ? '' : 'env $env '}'
          'bash fushi/tool/dist_test/worker_prepare.sh '
          '> .git/fushi-dist-prepare.log 2>&1 < /dev/null; rc=\$?; '
          'cat .git/fushi-dist-prepare.log; exit \$rc',
      log,
    );
  }

  @override
  Future<DistBatchRun> run(
    DistBatch batch, {
    required List<String> flutterArgs,
    required IOSink stderrLog,
    required Duration timeout,
  }) async {
    for (final String f in batch.files) {
      if (!isSafeDistTestPath(f)) {
        throw DistWorkerError('refusing to send unsafe test path "$f"');
      }
    }
    final String args = <String>[
      '${config.concurrency ?? 0}',
      ...flutterArgs.map(shellQuote),
    ].join(' ');
    final Process process = await Process.start(distSshExecutable(), <String>[
      ..._sshBase,
      '${_prefix}bash fushi/tool/dist_test/worker_run.sh $args',
    ]);
    _process = process;
    process.stdin.write('${batch.files.join('\n')}\n');
    await process.stdin.close();
    try {
      return await _drive(
        process,
        stderrLog: stderrLog,
        timeout: timeout,
        kill: _killRemote,
        connectionFailure: (int code) => code,
      );
    } finally {
      _process = null;
    }
  }

  Future<void> _killRemote() async {
    _process?.kill();
    await _ssh('${_prefix}bash fushi/tool/dist_test/worker_kill.sh');
  }

  @override
  Future<void> cancel() async {
    if (_process != null) await _killRemote();
  }

  @override
  Future<void> finish(String runId) async {
    await _ssh('${_prefix}git update-ref -d refs/dist/$runId');
  }

  @override
  Future<String> status() async {
    final ProcessResult r = await _ssh(
      '$_pathPrefix'
      r'printf "%s, " "$(flutter --version 2>/dev/null | head -1)"; '
      r'printf "%s cores, " "$(sysctl -n hw.ncpu 2>/dev/null || nproc)"; '
      r'printf "%s" "$(uptime | sed "s/.*load/load/")"',
    );
    if (r.exitCode != 0) {
      return 'unreachable (exit ${r.exitCode}): '
          '${'${r.stderr}'.trim().split('\n').last}';
    }
    return '${r.stdout}'.trim();
  }
}
