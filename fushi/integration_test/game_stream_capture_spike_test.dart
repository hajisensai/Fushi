import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:fushi/src/platform/game_stream_input_channel.dart';
import 'package:fushi/src/sync/game_stream_host.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_service.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shelf/shelf.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'captures a real Windows HWND through local WebRTC',
    (WidgetTester tester) async {
      Process? target;
      FushiRemoteGameStreamService? service;
      FushiGameStreamHost? host;
      RTCPeerConnection? client;
      final RTCVideoRenderer renderer = RTCVideoRenderer();
      final RTCVideoRenderer localRenderer = RTCVideoRenderer();
      bool localRendererInitialized = false;
      final Completer<void> firstFrame = Completer<void>();
      final Completer<MediaStream> remoteStream = Completer<MediaStream>();
      int hostSignalAfter = -1;
      bool remoteDescriptionSet = false;
      bool rendererInitialized = false;
      Future<void> clientSignals = Future<void>.value();
      final List<RTCIceCandidate> pendingHostCandidates = <RTCIceCandidate>[];
      final List<String> diagnostics = <String>[];
      void log(String message) {
        diagnostics.add(message);
        // ignore: avoid_print
        print('[game-stream-capture-spike] $message');
      }

      try {
        _clientSignalSequence = 0;
        target = await _startCaptureTarget(
          runnerPid: pid,
          runnerExePath: Platform.resolvedExecutable,
        );
        unawaited(
          target.stderr
              .transform(const Utf8Decoder(allowMalformed: true))
              .transform(const LineSplitter())
              .forEach((String line) => log('target stderr: $line')),
        );
        unawaited(
          target.exitCode.then(
            (int code) => log('target process exited code=$code'),
          ),
        );
        final int hwnd = await _readHwnd(
          target,
        ).timeout(const Duration(seconds: 10));
        log('target hwnd=$hwnd');
        final List<DesktopCapturerSource> preSources = await desktopCapturer
            .getSources(
              types: <SourceType>[SourceType.Window],
              thumbnailSize: ThumbnailSize(1, 1),
            );
        log('desktopCapturer window source count=${preSources.length}');
        for (final DesktopCapturerSource source in preSources) {
          final bool isTarget = int.tryParse(source.id) == hwnd;
          log(
            'desktop source target=$isTarget id=${source.id} '
            'name=${source.name} type=${source.type}',
          );
        }
        final Map<String, Object?> preInspect =
            await GameStreamInputChannel.inspect(hwnd);
        log('native inspect before start=$preInspect');

        await _awaitManualStartIfRequested(tester, log);

        service = FushiRemoteGameStreamService(
          sessionIdGenerator: () => 'capture-spike',
        );
        host = FushiGameStreamHost(service: service, onInput: (_) async {});
        host.addListener(() {
          log(
            'host started=${host!.started} starting=${host.starting} '
            'error=${host.error} state=${service!.session?.state.name} '
            'reason=${service.session?.reason}',
          );
        });
        final GameStreamSession session = await host.start(hwnd: hwnd);
        log(
          'host.start returned session=${session.sessionId} '
          'state=${session.state.name} window=${session.windowId}',
        );
        expect(host.started, isTrue);
        expect(session.windowId, 'hwnd:$hwnd');
        await localRenderer.initialize();
        localRendererInitialized = true;
        localRenderer.onFirstFrameRendered = () =>
            log('local capture first frame');
        localRenderer.srcObject = host.debugCaptureStream;
        log(
          'capture track settings=${host.debugCaptureStream?.getVideoTracks().first.getSettings()}',
        );

        final Response join = await _post(
          service,
          '/api/game-stream/join',
          <String, Object?>{
            'sessionId': session.sessionId,
            'clientId': 'local-client',
          },
        );
        expect(join.statusCode, 200);

        await renderer.initialize();
        rendererInitialized = true;
        renderer.onFirstFrameRendered = () {
          log('renderer first frame callback');
          if (!firstFrame.isCompleted) firstFrame.complete();
        };
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 320,
              height: 180,
              child: RTCVideoView(renderer),
            ),
          ),
        );

        final Map<String, dynamic> config = <String, dynamic>{
          'iceServers': <Object>[],
          'sdpSemantics': 'unified-plan',
        };
        client = await createPeerConnection(config);
        client.onConnectionState = (RTCPeerConnectionState state) {
          log('client connectionState=$state');
        };
        client.onIceConnectionState = (RTCIceConnectionState state) {
          log('client iceConnectionState=$state');
        };
        client.onIceGatheringState = (RTCIceGatheringState state) {
          log('client iceGatheringState=$state');
        };
        client.onSignalingState = (RTCSignalingState state) {
          log('client signalingState=$state');
        };

        client.onIceCandidate = (RTCIceCandidate candidate) {
          if (candidate.candidate?.isNotEmpty == true) {
            log(
              'client ice candidate mid=${candidate.sdpMid} '
              'mLine=${candidate.sdpMLineIndex}',
            );
            clientSignals = clientSignals.then(
              (_) => _sendClientSignal(
                service!,
                session.sessionId,
                GameStreamSignalType.iceCandidate,
                <String, Object?>{
                  'candidate': candidate.candidate,
                  'sdpMid': candidate.sdpMid,
                  'sdpMLineIndex': candidate.sdpMLineIndex,
                },
              ),
              onError: (_) => _sendClientSignal(
                service!,
                session.sessionId,
                GameStreamSignalType.iceCandidate,
                <String, Object?>{
                  'candidate': candidate.candidate,
                  'sdpMid': candidate.sdpMid,
                  'sdpMLineIndex': candidate.sdpMLineIndex,
                },
              ),
            );
          }
        };
        client.onTrack = (RTCTrackEvent event) {
          log(
            'client onTrack kind=${event.track.kind} streams=${event.streams.length}',
          );
          if (event.track.kind != 'video' || event.streams.isEmpty) return;
          renderer.srcObject = event.streams.first;
          log(
            'remote stream tracks video=${event.streams.first.getVideoTracks().length} '
            'audio=${event.streams.first.getAudioTracks().length}',
          );
          if (!remoteStream.isCompleted) {
            remoteStream.complete(event.streams.first);
          }
        };

        Future<void> pollHostSignals() async {
          final List<GameStreamSignal> signals = await _pollHostSignals(
            service!,
            session.sessionId,
            after: hostSignalAfter,
          );
          if (signals.isNotEmpty) {
            log(
              'polled host signals after=$hostSignalAfter '
              'types=${signals.map((GameStreamSignal s) => '${s.sequence}:${s.type.name}').join(',')}',
            );
          }
          for (final GameStreamSignal signal in signals) {
            hostSignalAfter = signal.sequence;
            if (signal.type == GameStreamSignalType.offer) {
              log('applying host offer seq=${signal.sequence}');
              await client!.setRemoteDescription(
                RTCSessionDescription(
                  signal.payload['sdp'] as String?,
                  'offer',
                ),
              );
              remoteDescriptionSet = true;
              log(
                'remote description set; flushing ${pendingHostCandidates.length} pending host ICE',
              );
              for (final RTCIceCandidate candidate in pendingHostCandidates) {
                await client.addCandidate(candidate);
              }
              pendingHostCandidates.clear();
              final RTCSessionDescription answer = await client.createAnswer();
              await client.setLocalDescription(answer);
              log('created local answer');
              clientSignals = clientSignals.then(
                (_) => _sendClientSignal(
                  service!,
                  session.sessionId,
                  GameStreamSignalType.answer,
                  <String, Object?>{'sdp': answer.sdp, 'type': 'answer'},
                ),
              );
              await clientSignals;
            } else if (signal.type == GameStreamSignalType.iceCandidate) {
              final RTCIceCandidate candidate = RTCIceCandidate(
                signal.payload['candidate'] as String?,
                signal.payload['sdpMid'] as String?,
                (signal.payload['sdpMLineIndex'] as num?)?.toInt(),
              );
              if (remoteDescriptionSet) {
                log('adding host ICE seq=${signal.sequence}');
                await client!.addCandidate(candidate);
              } else {
                log('buffering host ICE before offer seq=${signal.sequence}');
                pendingHostCandidates.add(candidate);
              }
            }
          }
        }

        await pollHostSignals();
        for (int i = 0; i < 40 && !firstFrame.isCompleted; i++) {
          await pollHostSignals();
          await tester.pump(const Duration(milliseconds: 250));
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }

        await remoteStream.future.timeout(const Duration(seconds: 15));
        log('remote stream future completed');
        await tester.pump();
        final bool hasInboundVideo = await _waitForInboundVideoFrames(
          client: client,
          host: host,
          log: log,
        );
        log(
          'frame evidence result=$hasInboundVideo '
          'rendererFirstFrame=${firstFrame.isCompleted} '
          'rendererSize=${renderer.videoWidth}x${renderer.videoHeight} '
          'hostStarted=${host.started} hostError=${host.error} '
          'sessionState=${service.session?.state.name} reason=${service.session?.reason}',
        );
        expect(
          hasInboundVideo,
          isTrue,
          reason: 'diagnostics:\n${diagnostics.join('\n')}',
        );
        bool hasAudioEnergy = false;
        for (int attempt = 0; attempt < 20 && !hasAudioEnergy; attempt++) {
          for (final StatsReport report in await client.getStats()) {
            if (report.type == 'inbound-rtp' &&
                report.values['kind'] == 'audio' &&
                ((report.values['totalAudioEnergy'] as num?) ?? 0) > 0) {
              log('received application tone: ${report.values}');
              hasAudioEnergy = true;
            }
          }
          if (!hasAudioEnergy) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
        }
        expect(
          hasAudioEnergy,
          isTrue,
          reason: 'Application audio must be non-silent',
        );

        await _minimizeWindow(hwnd);
        await Future<void>.delayed(const Duration(milliseconds: 800));
        expect(host.started, isFalse);
        expect(service.session?.reason, 'window_unavailable');
      } finally {
        try {
          renderer.onFirstFrameRendered = null;
          localRenderer.onFirstFrameRendered = null;
          if (rendererInitialized) renderer.srcObject = null;
          if (localRendererInitialized) localRenderer.srcObject = null;
          await host?.stop(reason: 'test_cleanup');
          service?.dispose();
          await client?.close();
          await client?.dispose();
          if (rendererInitialized) await renderer.dispose();
          if (localRendererInitialized) await localRenderer.dispose();
        } finally {
          await _stopProcess(target, log);
        }
      }
    },
    // 裸 `return` 会被报成「通过 +1」而不是 skipped——非 Windows 上那是假绿
    // （BUG-1157 同类形态）。与同 PR 的 game_stream_lan_host_test 同口径。
    skip: !Platform.isWindows,
  );
}

Future<void> _stopProcess(
  Process? process,
  void Function(String message) log,
) async {
  if (process == null) return;
  final Future<int> exit = process.exitCode;
  final bool signaled = process.kill();
  log('target kill signaled=$signaled pid=${process.pid}');
  try {
    final int code = await exit.timeout(const Duration(seconds: 5));
    log('target cleanup exit code=$code');
  } on TimeoutException {
    log('target cleanup timed out after kill pid=${process.pid}');
  }
}

Future<Response> _post(
  FushiRemoteGameStreamService service,
  String path,
  Map<String, Object?> body,
) {
  return service.handleRequest(
    Request('POST', Uri.parse('http://local$path'), body: jsonEncode(body)),
    'POST',
    path,
    peerIdentity: 'local-peer',
  );
}

Future<List<GameStreamSignal>> _pollHostSignals(
  FushiRemoteGameStreamService service,
  String sessionId, {
  required int after,
}) async {
  final Response response = await _post(
    service,
    '/api/game-stream/signal',
    <String, Object?>{
      'sessionId': sessionId,
      'clientId': 'local-client',
      'after': after,
    },
  );
  expect(response.statusCode, 200);
  final Map<String, dynamic> json =
      jsonDecode(await response.readAsString()) as Map<String, dynamic>;
  final Object? raw = json['signals'];
  if (raw is! List) return const <GameStreamSignal>[];
  return <GameStreamSignal>[
    for (final Object? item in raw) GameStreamSignal.fromJson(item),
  ];
}

int _clientSignalSequence = 0;

Future<void> _sendClientSignal(
  FushiRemoteGameStreamService service,
  String sessionId,
  GameStreamSignalType type,
  Map<String, Object?> payload,
) async {
  final Response response =
      await _post(service, '/api/game-stream/signal', <String, Object?>{
        'sessionId': sessionId,
        'clientId': 'local-client',
        'signal': GameStreamSignal(
          sessionId: sessionId,
          senderId: 'local-client',
          senderRole: GameStreamPeerRole.client,
          type: type,
          sequence: _clientSignalSequence++,
          payload: payload,
        ).toJson(),
      });
  expect(response.statusCode, 200);
}

Future<bool> _waitForInboundVideoFrames({
  required RTCPeerConnection client,
  required FushiGameStreamHost host,
  required void Function(String message) log,
}) async {
  for (int i = 0; i < 40; i++) {
    final List<StatsReport> reports = await client.getStats();
    final List<StatsReport> hostReports = await host.debugStats();
    final Iterable<StatsReport> interesting = reports.where(
      (StatsReport report) =>
          report.type == 'candidate-pair' ||
          report.type == 'inbound-rtp' ||
          report.type == 'outbound-rtp' ||
          report.type == 'track' ||
          report.type == 'media-source',
    );
    for (final StatsReport report in interesting) {
      log('client stats[$i] ${report.id} ${report.type} ${report.values}');
    }
    final Iterable<StatsReport> hostInteresting = hostReports.where(
      (StatsReport report) =>
          report.type == 'candidate-pair' ||
          report.type == 'inbound-rtp' ||
          report.type == 'outbound-rtp' ||
          report.type == 'track' ||
          report.type == 'media-source',
    );
    for (final StatsReport report in hostInteresting) {
      log('host stats[$i] ${report.id} ${report.type} ${report.values}');
    }
    for (final StatsReport report in reports) {
      if (report.type != 'inbound-rtp') {
        continue;
      }
      final Object? media = report.values['kind'] ?? report.values['mediaType'];
      if (media != 'video') continue;
      final int framesDecoded =
          (report.values['framesDecoded'] as num?)?.toInt() ?? 0;
      final int framesReceived =
          (report.values['framesReceived'] as num?)?.toInt() ?? 0;
      final int packetsReceived =
          (report.values['packetsReceived'] as num?)?.toInt() ?? 0;
      final int bytesReceived =
          (report.values['bytesReceived'] as num?)?.toInt() ?? 0;
      if (framesDecoded > 0) {
        return true;
      }
      log(
        'inbound video present but no frames: framesDecoded=$framesDecoded '
        'framesReceived=$framesReceived packetsReceived=$packetsReceived '
        'bytesReceived=$bytesReceived',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return false;
}

Future<void> _awaitManualStartIfRequested(
  WidgetTester tester,
  void Function(String message) log,
) async {
  const bool manualStart = bool.fromEnvironment(
    'FUSHI_CAPTURE_SPIKE_MANUAL_START',
  );
  if (!manualStart) return;

  final Completer<void> start = Completer<void>();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: GestureDetector(
          key: const ValueKey<String>('capture-spike-manual-start'),
          onTap: () {
            log('manual start button tapped');
            if (!start.isCompleted) start.complete();
          },
          child: Container(
            width: 420,
            height: 140,
            alignment: Alignment.center,
            color: const Color(0xFF1565C0),
            child: const Text(
              '开始串流捕获测试',
              textDirection: TextDirection.ltr,
              style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 28),
            ),
          ),
        ),
      ),
    ),
  );
  log('manual start button visible; waiting for local click');
  await start.future.timeout(const Duration(minutes: 3));
}

Future<Process> _startCaptureTarget({
  required int runnerPid,
  required String runnerExePath,
}) {
  const String script = r'''
$RunnerPid = [int]$env:FUSHI_SPIKE_RUNNER_PID
$RunnerExePath = $env:FUSHI_SPIKE_RUNNER_EXE
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class SpikeUser32 {
  [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(uint dwProcessId);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll", SetLastError=true)] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
}
"@
$form = New-Object System.Windows.Forms.Form
$form.Text = "Fushi Game Stream Capture Spike " + [Guid]::NewGuid().ToString("N")
$form.Width = 640
$form.Height = 360
$form.StartPosition = "Manual"
$form.Left = 80
$form.Top = 80
$form.BackColor = [System.Drawing.Color]::Red
$label = New-Object System.Windows.Forms.Label
$label.Dock = [System.Windows.Forms.DockStyle]::Fill
$label.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$label.Font = New-Object System.Drawing.Font("Segoe UI", 32)
$label.Text = "Fushi capture spike"
$form.Controls.Add($label)
$toggle = $false
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
  $script:toggle = -not $script:toggle
  if ($script:toggle) {
    $form.BackColor = [System.Drawing.Color]::Lime
    $label.Text = "Fushi capture spike A"
  } else {
    $form.BackColor = [System.Drawing.Color]::Blue
    $label.Text = "Fushi capture spike B"
  }
})
# A real PCM tone owned by this target process, rather than a system sound
# which can be played by a different Windows audio process.
$toneStream = New-Object System.IO.MemoryStream
$toneWriter = New-Object System.IO.BinaryWriter($toneStream)
$toneWriter.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
$toneWriter.Write([int]32036)
$toneWriter.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
$toneWriter.Write([int]16)
$toneWriter.Write([int16]1)
$toneWriter.Write([int16]1)
$toneWriter.Write([int]16000)
$toneWriter.Write([int]32000)
$toneWriter.Write([int16]2)
$toneWriter.Write([int16]16)
$toneWriter.Write([Text.Encoding]::ASCII.GetBytes('data'))
$toneWriter.Write([int]32000)
for ($sample = 0; $sample -lt 16000; $sample++) {
  $toneWriter.Write([int16](3000 * [Math]::Sin(2 * [Math]::PI * 440 * $sample / 16000)))
}
$toneWriter.Flush()
$toneStream.Position = 0
$audio = New-Object System.Media.SoundPlayer($toneStream)
function Get-ForegroundPid {
  $foreground = [SpikeUser32]::GetForegroundWindow()
  $foregroundPid = [uint32]0
  [SpikeUser32]::GetWindowThreadProcessId($foreground, [ref]$foregroundPid) | Out-Null
  return [int64]$foregroundPid
}
$form.Add_Shown({
  $runner = $null
  if ($RunnerPid -gt 0) {
    $runner = Get-Process -Id $RunnerPid -ErrorAction SilentlyContinue
  }
  if ($null -eq $runner -and -not [string]::IsNullOrWhiteSpace($RunnerExePath)) {
    $escapedRunnerExePath = $RunnerExePath.Replace("'", "''")
    $runnerCim = Get-CimInstance Win32_Process -Filter "ExecutablePath = '$escapedRunnerExePath'" -ErrorAction SilentlyContinue |
      Sort-Object CreationDate -Descending |
      Select-Object -First 1
    if ($null -ne $runnerCim) {
      $RunnerPid = [int]$runnerCim.ProcessId
      $runner = Get-Process -Id $RunnerPid -ErrorAction SilentlyContinue
    }
  }
  $allowResult = if ($RunnerPid -gt 0) { [SpikeUser32]::AllowSetForegroundWindow([uint32]$RunnerPid) } else { $false }
  $runnerHandle = [IntPtr]::Zero
  if ($null -ne $runner) {
    $runnerHandle = [IntPtr]$runner.MainWindowHandle
  }
  $showResult = $false
  $bringResult = $false
  $foregroundResult = $false
  $attachRunner = $false
  $attachForeground = $false
  if ($runnerHandle -ne [IntPtr]::Zero) {
    $currentThread = [SpikeUser32]::GetCurrentThreadId()
    $runnerPidFromWindow = [uint32]0
    $runnerThread = [SpikeUser32]::GetWindowThreadProcessId($runnerHandle, [ref]$runnerPidFromWindow)
    $foreground = [SpikeUser32]::GetForegroundWindow()
    $foregroundPidBefore = [uint32]0
    $foregroundThread = [SpikeUser32]::GetWindowThreadProcessId($foreground, [ref]$foregroundPidBefore)
    if ($runnerThread -ne 0 -and $runnerThread -ne $currentThread) {
      $attachRunner = [SpikeUser32]::AttachThreadInput($currentThread, $runnerThread, $true)
    }
    if ($foregroundThread -ne 0 -and $foregroundThread -ne $currentThread -and $foregroundThread -ne $runnerThread) {
      $attachForeground = [SpikeUser32]::AttachThreadInput($currentThread, $foregroundThread, $true)
    }
    $showResult = [SpikeUser32]::ShowWindow($runnerHandle, 9)
    $bringResult = [SpikeUser32]::BringWindowToTop($runnerHandle)
    $foregroundResult = [SpikeUser32]::SetForegroundWindow($runnerHandle)
    if ($attachForeground) { [SpikeUser32]::AttachThreadInput($currentThread, $foregroundThread, $false) | Out-Null }
    if ($attachRunner) { [SpikeUser32]::AttachThreadInput($currentThread, $runnerThread, $false) | Out-Null }
  }
  $foregroundPid = Get-ForegroundPid
  [Console]::Error.WriteLine("foreground-setup allow=$allowResult runnerExe=$RunnerExePath runnerHandle=$($runnerHandle.ToInt64()) show=$showResult bring=$bringResult setForeground=$foregroundResult attachRunner=$attachRunner attachForeground=$attachForeground foregroundPid=$foregroundPid runnerPid=$RunnerPid")
  [Console]::Error.Flush()
  if ($runnerHandle -eq [IntPtr]::Zero -or $foregroundPid -ne $RunnerPid) {
    [Console]::Error.WriteLine("foreground-setup-failed runnerExe=$RunnerExePath runnerHandle=$($runnerHandle.ToInt64()) foregroundPid=$foregroundPid runnerPid=$RunnerPid")
    [Console]::Error.Flush()
    $form.Close()
    return
  }
  [Console]::Out.WriteLine([int64]$form.Handle)
  [Console]::Out.Flush()
  $timer.Start()
  $audio.PlayLooping()
})
[System.Windows.Forms.Application]::Run($form)
$audio.Stop()
$audio.Dispose()
$toneWriter.Dispose()
$toneStream.Dispose()
''';
  return Process.start(
    'powershell.exe',
    <String>['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
    environment: <String, String>{
      'FUSHI_SPIKE_RUNNER_PID': runnerPid.toString(),
      'FUSHI_SPIKE_RUNNER_EXE': runnerExePath,
    },
  );
}

Future<int> _readHwnd(Process process) async {
  final Stream<String> lines = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());
  await for (final String line in lines) {
    final int? hwnd = int.tryParse(line.trim());
    if (hwnd != null && hwnd != 0) return hwnd;
  }
  throw StateError('capture target exited before publishing HWND');
}

Future<void> _minimizeWindow(int hwnd) async {
  final String script =
      '''
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class User32 {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
[User32]::ShowWindow([IntPtr]$hwnd, 6) | Out-Null
''';
  final ProcessResult result = await Process.run('powershell.exe', <String>[
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-Command',
    script,
  ]);
  if (result.exitCode != 0) {
    throw StateError('failed to minimize capture target: ${result.stderr}');
  }
}
