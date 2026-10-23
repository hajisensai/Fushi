/// Windows 系统语音的常驻工作进程：一个 Windows PowerShell 5.1 进程，同时接
/// WinRT `Windows.Media.SpeechSynthesis`（OneCore 声音：「设置 › 时间和语言 › 语音」
/// 里装的全部声音）与 `System.Speech`（SAPI 5，第三方 SAPI 声音只在这里）。
///
/// 以前每句都起一个 PowerShell 调 SAPI：看不到 OneCore 声音（Windows 10/11 新装的
/// 语言包声音大多只进 OneCore），每句还要付一次 PowerShell 冷启动（实测 0.5–1 秒，
/// 朗读时句间明显停顿）。现在进程只起一次、按行收发请求，空闲一段时间自己退出。
///
/// 为什么还是 PowerShell 而不是原生插件：WinRT 语音 API 在 PowerShell 5.1 里经
/// `System.Runtime.WindowsRuntime` 的 `AsTask` 即可等待，零新原生依赖；PowerShell 7
/// 去掉了 WinRT 投影，所以显式用 `powershell.exe`（随 Windows 自带的 5.1）。
///
/// 传输走 **127.0.0.1 上的一条 TCP 连接**，不走 stdin：实测 Dart 在 Windows 上写进
/// 子进程 stdin 的数据，只有 PowerShell 第一次阻塞读之前写的那部分能被读到，之后再写的
/// 一律读不到（`[Console]::In` 与 `OpenStandardInput()` 都一样；同一脚本用 bash 管道
/// 喂就正常）。stdout 只用来报一次「就绪 + 端口」。连上后第一行必须是启动时塞进脚本的
/// 随机口令，口令不对的连接直接断开——别的本机进程抢先连上也拿不到合成能力。
///
/// 协议：每行一个 base64(UTF-8 JSON)，两个方向都是——避开代码页与转义。
/// 就绪行（stdout）是 `{id: 0, ready, port, winrt, sapi}`；之后每个请求回同 id 的一行；
/// `{op: 'exit'}` 让它退出（空闲回收）。连接断开（宿主退出）它就退出；另外每秒查一次
/// 宿主 PID，等连接期间宿主没了也不留孤儿。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/utils/misc/helper_process_registry.dart';

/// 工作进程脚本（前面会拼上 `$fushiParentPid` 与 `$fushiToken` 两行）。请求：
/// - `{id, op: 'voices'}` → `{id, ok, voices: [{kind: winrt|sapi, id, name, lang, gender}]}`
/// - `{id, op: 'speak', text: base64(UTF-8), out, lang?, voiceKind?, voiceKey?}` →
///   `{id, ok, path, kind}` 或 `{id, ok: false, code}`；code 与 Android 原生同一套
///   （`VOICE_UNAVAILABLE` / `LANGUAGE_NOT_SUPPORTED` / `ENGINE_UNAVAILABLE` /
///   `SYNTHESIS_FAILED`）。
///
/// 不指定声音时：有 `lang` 先看 WinRT 默认声音是否该语言，再找第一个该语言的 WinRT
/// 声音，最后找 SAPI；没有 `lang` 用 WinRT 默认声音（用户在系统设置里选的），WinRT
/// 不可用才退回 SAPI 默认声音。
@visibleForTesting
const String kWindowsSpeechWorkerScript = r'''
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
function Encode($obj) { [Convert]::ToBase64String($utf8.GetBytes(($obj | ConvertTo-Json -Compress -Depth 5))) }
function Reply($obj) { $script:writer.WriteLine((Encode $obj)) }
$winrt = $false
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $null = [Windows.Media.SpeechSynthesis.SpeechSynthesizer,Windows.Media.SpeechSynthesis,ContentType=WindowsRuntime]
  $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
  $null = [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices.Count
  $winrt = $true
} catch { }
$sapi = $false
try { Add-Type -AssemblyName System.Speech; $sapi = $true } catch { }
function WinrtVoices { if (-not $winrt) { return @() }; @([Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices) }
function SapiVoices {
  if (-not $sapi) { return @() }
  $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
  try { @($s.GetInstalledVoices() | Where-Object { $_.Enabled } | ForEach-Object { $_.VoiceInfo }) } finally { $s.Dispose() }
}
function LangOf($tag) { if ($tag) { ([string]$tag).Split('-')[0].ToLowerInvariant() } else { '' } }
function SpeakWinrt($info, $text, $out) {
  $synth = New-Object Windows.Media.SpeechSynthesis.SpeechSynthesizer
  try {
    $synth.Voice = $info
    $task = $asTask.MakeGenericMethod([Windows.Media.SpeechSynthesis.SpeechSynthesisStream]).Invoke($null, @($synth.SynthesizeTextToStreamAsync($text)))
    $null = $task.Wait(-1)
    $stream = $task.Result
    $in = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($stream)
    $fs = [IO.File]::Create($out)
    try { $in.CopyTo($fs) } finally { $fs.Dispose(); $in.Dispose(); $stream.Dispose() }
  } finally { $synth.Dispose() }
}
function SpeakSapi($name, $text, $out) {
  $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
  try {
    if ($name) { $s.SelectVoice($name) }
    $s.SetOutputToWaveFile($out)
    $s.Speak($text)
    $s.SetOutputToNull()
  } finally { $s.Dispose() }
}
$parent = $null
try { if ($fushiParentPid) { $parent = [Diagnostics.Process]::GetProcessById($fushiParentPid) } } catch { exit 0 }
# 等一个异步任务，每秒看一眼宿主还在不在；$limitMs 到点返回 $null（-1 = 不限）。
function WaitTask($task, $limitMs) {
  $waited = 0
  while (-not $task.Wait(1000)) {
    if ($parent -and $parent.HasExited) { exit 0 }
    $waited += 1000
    if ($limitMs -ge 0 -and $waited -ge $limitMs) { return $null }
  }
  $task.Result
}
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
[Console]::Out.WriteLine((Encode @{ id = 0; ready = $true; port = $listener.LocalEndpoint.Port; winrt = $winrt; sapi = $sapi }))
[Console]::Out.Flush()
$client = $null; $reader = $null
while (-not $client) {
  $c = WaitTask ($listener.AcceptTcpClientAsync()) -1
  $r = New-Object System.IO.StreamReader($c.GetStream(), $utf8)
  $first = WaitTask ($r.ReadLineAsync()) 5000
  if ($first -eq $fushiToken) { $client = $c; $reader = $r } else { $c.Close() }
}
$listener.Stop()
$writer = New-Object System.IO.StreamWriter($client.GetStream(), $utf8)
$writer.NewLine = "`n"
$writer.AutoFlush = $true
while ($true) {
  $line = WaitTask ($reader.ReadLineAsync()) -1
  if ($null -eq $line) { break }
  if ($line.Trim().Length -eq 0) { continue }
  $rid = -1
  try {
    $req = $utf8.GetString([Convert]::FromBase64String($line.Trim())) | ConvertFrom-Json
    $rid = $req.id
    if ($req.op -eq 'exit') { break }
    if ($req.op -eq 'voices') {
      $list = @()
      foreach ($v in (WinrtVoices)) { $list += @{ kind = 'winrt'; id = $v.Id; name = $v.DisplayName; lang = $v.Language; gender = [string]$v.Gender } }
      foreach ($v in (SapiVoices)) { $list += @{ kind = 'sapi'; id = $v.Name; name = $v.Name; lang = $v.Culture.Name; gender = [string]$v.Gender } }
      Reply @{ id = $rid; ok = $true; voices = $list }
      continue
    }
    $text = $utf8.GetString([Convert]::FromBase64String($req.text))
    $kind = $null; $target = $null
    if ($req.voiceKind) {
      $key = [string]$req.voiceKey
      if ($req.voiceKind -eq 'onecore') {
        $target = WinrtVoices | Where-Object { $_.Id -eq $key -or $_.Id.EndsWith('\' + $key) } | Select-Object -First 1
        $kind = 'winrt'
      } elseif ($req.voiceKind -eq 'sapi') {
        $target = SapiVoices | Where-Object { $_.Name -eq $key } | Select-Object -First 1
        $kind = 'sapi'
      }
      if (-not $target) { Reply @{ id = $rid; ok = $false; code = 'VOICE_UNAVAILABLE' }; continue }
    } elseif ($req.lang) {
      $l = [string]$req.lang
      if ($winrt) {
        $def = [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::DefaultVoice
        if ($def -and (LangOf $def.Language) -eq $l) { $target = $def }
        if (-not $target) { $target = WinrtVoices | Where-Object { (LangOf $_.Language) -eq $l } | Select-Object -First 1 }
        if ($target) { $kind = 'winrt' }
      }
      if (-not $target) {
        $target = SapiVoices | Where-Object { (LangOf $_.Culture.Name) -eq $l } | Select-Object -First 1
        if ($target) { $kind = 'sapi' }
      }
      if (-not $target) { Reply @{ id = $rid; ok = $false; code = 'LANGUAGE_NOT_SUPPORTED' }; continue }
    } elseif ($winrt) {
      $kind = 'winrt'; $target = [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::DefaultVoice
    } elseif ($sapi) {
      $kind = 'sapi'
    } else {
      Reply @{ id = $rid; ok = $false; code = 'ENGINE_UNAVAILABLE' }; continue
    }
    if ($kind -eq 'winrt') { SpeakWinrt $target $text $req.out }
    else { $n = $null; if ($target) { $n = $target.Name }; SpeakSapi $n $text $req.out }
    Reply @{ id = $rid; ok = $true; path = $req.out; kind = $kind }
  } catch {
    Reply @{ id = $rid; ok = $false; code = 'SYNTHESIS_FAILED'; message = $_.Exception.Message }
  }
}
''';

/// 一行协议消息的编码（两个方向同一形态）。
@visibleForTesting
String encodeWindowsSpeechMessage(Map<String, Object?> message) =>
    base64Encode(utf8.encode(jsonEncode(message)));

/// 解一行协议消息；不是合法消息返回 null（PowerShell 偶尔往 stdout 写别的东西）。
@visibleForTesting
Map<String, Object?>? decodeWindowsSpeechMessage(String line) {
  final String trimmed = line.trim();
  if (trimmed.isEmpty) return null;
  try {
    final Object? decoded = jsonDecode(utf8.decode(base64Decode(trimmed)));
    return decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// 交给 `-EncodedCommand` 的完整脚本：宿主 PID 与连接口令两行 + [kWindowsSpeechWorkerScript]。
@visibleForTesting
String windowsSpeechWorkerCommand({
  required int parentPid,
  required String token,
}) =>
    '\$fushiParentPid = $parentPid\n'
    "\$fushiToken = '$token'\n"
    '$kWindowsSpeechWorkerScript';

/// `-EncodedCommand` 的参数值：UTF-16LE 再 base64。
@visibleForTesting
String encodePowerShellCommand(String script) {
  final List<int> bytes = <int>[];
  for (final int unit in script.codeUnits) {
    bytes
      ..add(unit & 0xFF)
      ..add(unit >> 8);
  }
  return base64Encode(bytes);
}

/// 工作进程不可用（起不来 / 中途退出 / 超时）。
class WindowsSpeechWorkerUnavailable implements Exception {
  const WindowsSpeechWorkerUnavailable(this.message);

  final String message;

  @override
  String toString() => 'WindowsSpeechWorkerUnavailable($message)';
}

/// 起进程的函数形状（测试注入假进程）。
typedef WindowsSpeechProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

Future<Process> _startRegistered(String executable, List<String> arguments) =>
    HelperProcessRegistry.instance.start(executable, arguments);

String _randomToken() {
  final Random random = Random.secure();
  return List<String>.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// 常驻工作进程的客户端：懒启动、按 id 配对应答、空闲自动退出、出错重起。
class WindowsSpeechWorker {
  WindowsSpeechWorker({
    WindowsSpeechProcessStarter startProcess = _startRegistered,
    this.idleTimeout = const Duration(minutes: 2),
    this.requestTimeout = const Duration(seconds: 45),
  }) : _startProcess = startProcess;

  static final WindowsSpeechWorker instance = WindowsSpeechWorker();

  final WindowsSpeechProcessStarter _startProcess;

  /// 最后一个请求答复后多久没有新请求就让进程退出（发 `exit`）。
  final Duration idleTimeout;

  /// 单个请求的上界（含首个请求的冷启动）。超时视为进程卡死：杀掉，下一个请求重起。
  final Duration requestTimeout;

  Process? _process;
  Socket? _socket;
  Future<void>? _ready;
  final Map<int, Completer<Map<String, Object?>>> _pending =
      <int, Completer<Map<String, Object?>>>{};
  int _nextId = 1;
  Timer? _idleTimer;

  /// 发一个请求，返回同 id 的应答。失败抛 [WindowsSpeechWorkerUnavailable]。
  Future<Map<String, Object?>> request(Map<String, Object?> body) async {
    _idleTimer?.cancel();
    try {
      await _ensureStarted().timeout(requestTimeout);
    } on TimeoutException {
      _kill('worker did not start within ${requestTimeout.inSeconds}s');
      throw const WindowsSpeechWorkerUnavailable('start timed out');
    }
    final Socket socket = _socket!;
    final int id = _nextId++;
    final Completer<Map<String, Object?>> reply =
        Completer<Map<String, Object?>>();
    _pending[id] = reply;
    try {
      socket.write(
        '${encodeWindowsSpeechMessage(<String, Object?>{...body, 'id': id})}\n',
      );
      await socket.flush();
    } on Object catch (e) {
      _pending.remove(id);
      _kill('socket write failed: $e');
      throw WindowsSpeechWorkerUnavailable('socket write failed: $e');
    }
    try {
      return await reply.future.timeout(requestTimeout);
    } on TimeoutException {
      _kill('request $id timed out');
      throw WindowsSpeechWorkerUnavailable('request $id timed out');
    } finally {
      _pending.remove(id);
      if (_pending.isEmpty) _armIdle();
    }
  }

  Future<void> _ensureStarted() {
    final Future<void>? ready = _ready;
    if (ready != null) return ready;
    final Completer<void> started = Completer<void>();
    _ready = started.future;
    // 没人等的失败（例如被 _kill 抢先）不要变成未处理的异步错误。
    started.future.ignore();
    unawaited(_start(started));
    return started.future;
  }

  Future<void> _start(Completer<void> started) async {
    final String token = _randomToken();
    final Process process;
    try {
      process = await _startProcess('powershell.exe', <String>[
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        encodePowerShellCommand(
          windowsSpeechWorkerCommand(parentPid: pid, token: token),
        ),
      ]);
    } on ProcessException catch (e) {
      _ready = null;
      started.completeError(WindowsSpeechWorkerUnavailable('$e'));
      return;
    }
    _process = process;
    void fail(String reason) {
      if (!started.isCompleted) {
        started.completeError(WindowsSpeechWorkerUnavailable(reason));
      }
    }

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
          final Map<String, Object?>? message = decodeWindowsSpeechMessage(
            line,
          );
          if (message == null ||
              message['id'] != 0 ||
              message['ready'] != true ||
              started.isCompleted) {
            return;
          }
          final Object? port = message['port'];
          if (port is! int) {
            fail('ready line without port');
            return;
          }
          unawaited(_connect(process, port, token, started));
        });
    final Future<String> stderr = process.stderr.transform(utf8.decoder).join();
    unawaited(
      process.exitCode.then((int code) async {
        final bool current = identical(_process, process);
        fail('worker exited $code before it was ready');
        if (!current) return;
        _process = null;
        _ready = null;
        _socket?.destroy();
        _socket = null;
        _idleTimer?.cancel();
        // 正常的空闲退出（code 0、没有在途请求）不记日志。
        if (code != 0 || _pending.isNotEmpty) {
          final String err = await stderr.timeout(
            const Duration(seconds: 2),
            onTimeout: () => '',
          );
          ErrorLogService.instance.log(
            'WindowsSpeechWorker',
            'exit $code: $err',
            StackTrace.current,
          );
        }
        _failPending('worker exited $code');
      }),
    );
  }

  Future<void> _connect(
    Process process,
    int port,
    String token,
    Completer<void> started,
  ) async {
    final Socket socket;
    try {
      socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    } on SocketException catch (e) {
      if (!started.isCompleted) {
        started.completeError(WindowsSpeechWorkerUnavailable('connect: $e'));
      }
      if (identical(_process, process)) _kill('connect failed');
      return;
    }
    if (!identical(_process, process)) {
      socket.destroy();
      return;
    }
    _socket = socket;
    socket.write('$token\n');
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (String line) {
            final Map<String, Object?>? message = decodeWindowsSpeechMessage(
              line,
            );
            final Object? id = message?['id'];
            if (id is int) _pending[id]?.complete(message!);
          },
          onDone: () {
            if (identical(_socket, socket)) _kill('connection closed');
          },
          onError: (Object _) {
            if (identical(_socket, socket)) _kill('connection error');
          },
        );
    if (!started.isCompleted) started.complete();
  }

  void _armIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () {
      final Socket? socket = _socket;
      if (socket == null || _pending.isNotEmpty) return;
      // 先摘掉再发 exit：之后的请求一律起新进程，不会撞上正在退出的这个。
      _socket = null;
      _process = null;
      _ready = null;
      socket.write(
        '${encodeWindowsSpeechMessage(<String, Object?>{'op': 'exit'})}\n',
      );
      unawaited(socket.close().catchError((Object _) {}));
    });
  }

  void _kill(String reason) {
    final Process? process = _process;
    final Socket? socket = _socket;
    _process = null;
    _socket = null;
    _ready = null;
    _idleTimer?.cancel();
    socket?.destroy();
    process?.kill();
    _failPending(reason);
  }

  void _failPending(String reason) {
    final WindowsSpeechWorkerUnavailable failure =
        WindowsSpeechWorkerUnavailable(reason);
    for (final Completer<Map<String, Object?>> c in _pending.values) {
      if (!c.isCompleted) c.completeError(failure);
    }
    _pending.clear();
  }
}
