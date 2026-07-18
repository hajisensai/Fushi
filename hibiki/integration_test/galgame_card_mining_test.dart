// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/src/mining/galgame_audio_encode.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';

/// galgame 一键制卡端到端真机集成测试（docs/specs/galgame-mining）。
///
/// 在真实 hibiki.exe 测试宿主里（能用 native 通道），对每个游戏逐个跑通整条路径：
///   拉起游戏（injector --launch CREATE_SUSPENDED 早注入，命中启动即建 DirectSound 的引擎）
///   到 引擎-hook 抓混音前干净语音（app.hibiki.reader/voice_hook channel），抓不到 / 全静音
///   则回退 WASAPI loopback 系统混音（[LoopbackGalAudioSource]），保证每个游戏都有音频
///   到 截游戏窗口（[WindowCaptureChannel]，失败不致命）
///   到 把 WAV + 可选 PNG + meta JSON **dump 到 GALTEST_OUT 目录**（外层脚本再经
///     AnkiConnect storeMediaFile + addNote 推卡——runner 隔离环境里 Dart HttpClient 调
///     AnkiConnect 不稳，故拆成「宿主内抓+dump」与「外层推卡」两段，各自可靠）。
///
/// 不初始化 AppModel / 不打开 Drift DB（只 pump 平凡 widget 让 runner 的 native 通道就绪），
/// 故绝不碰生产库——避免开发版 app 开生产 DB 触发 schema 降级的红线。
///
/// 需要环境变量指到本机素材（缺任一必需项则 skip、不误报失败，CI/无游戏机器上自动跳过）：
///   - GALTEST_INJECTOR_X86 / GALTEST_INJECTOR_X64：两个位数的 injector 路径。
///   - GALTEST_GAMES：分号分隔的游戏 exe 绝对路径列表。
///   - GALTEST_OUT：dump 输出目录（缺省 systemTemp）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 引擎-hook 读侧通道：直接用裸 MethodChannel（不经 EngineHookGalAudioSource——那会自己
  // 拉起 injector + 超时杀游戏，本测试要自己掌控每个游戏的生命周期）。
  const MethodChannel voiceChannel =
      MethodChannel('app.hibiki.reader/voice_hook');

  testWidgets('逐个 galgame 抓真实音频并经 AnkiConnect 推带音频卡',
      (WidgetTester tester) async {
    // 只 pump 平凡 widget：让 runner 起来注册 native 通道，但不碰 AppModel/DB。
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump(const Duration(milliseconds: 200));

    final Map<String, String> env = Platform.environment;
    final String? injectorX86 = env['GALTEST_INJECTOR_X86'];
    final String? injectorX64 = env['GALTEST_INJECTOR_X64'];
    final String? gamesRaw = env['GALTEST_GAMES'];
    // 抓到的音频/截图/元数据 dump 到这个目录，由外层 bash 经 AnkiConnect 推卡
    // （runner 隔离环境里 Dart HttpClient 调 AnkiConnect 不稳，故拆成 dump + 外层推）。
    final String outDir = env['GALTEST_OUT'] ?? Directory.systemTemp.path;

    if (injectorX86 == null || injectorX64 == null || gamesRaw == null) {
      print('GALCARD SKIP: 缺 GALTEST_INJECTOR_X86/INJECTOR_X64/GAMES 之一');
      return; // 配置缺失：跳过（非失败）
    }
    Directory(outDir).createSync(recursive: true);

    final List<String> games = gamesRaw
        .split(';')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    if (games.isEmpty) {
      print('GALCARD SKIP: GALTEST_GAMES 为空');
      return;
    }

    int created = 0;
    for (int idx = 0; idx < games.length; idx++) {
      // 顺序不并发：loopback 是单例、且一次只让一个游戏出声。
      final String exe = games[idx];
      final String gameName = _basename(exe);
      // 媒体文件名清洗成 ASCII（去非字母数字）避免中文媒体名问题；idx 前缀保证唯一。
      final String asciiName = _asciiSafe(_basenameWithoutExtension(exe));
      final String mediaBase =
          'galcard_${idx}_${asciiName.isEmpty ? 'game' : asciiName}';

      if (!File(exe).existsSync()) {
        print('GALCARD RESULT game=$gameName source=skip-missing-exe '
            'engineHook=false pcmBytes=0 note=null fmt=na');
        continue;
      }
      // 读 PE 头选注入器：32 位到 x86，64 位到 x64，未知到默认 x86（多数 KiriKiri 32 位）。
      final bool? is32 = await EngineHookGalAudioSource.exeIs32Bit(exe);
      final String injector = (is32 == false) ? injectorX64 : injectorX86;
      if (!File(injector).existsSync()) {
        print('GALCARD RESULT game=$gameName source=skip-missing-injector '
            'engineHook=false pcmBytes=0 note=null fmt=na');
        continue;
      }

      final LoopbackGalAudioSource loopback = LoopbackGalAudioSource();
      Process? injectorProc;
      StreamSubscription<String>? stdoutSub;
      int? childPid;
      String source = 'none';
      bool engineHook = false;
      int pcmBytes = 0;
      Object? noteId;
      String fmtLabel = 'na';

      try {
        // b. loopback 系统混音兜底先开起来（保证即使引擎-hook 空也有音频）。
        await loopback.start();

        // c. 拉起游戏：injector --launch exe --hold，从 stdout 等 OK hooked pid。
        injectorProc = await Process.start(
          injector,
          <String>['--launch', exe, '--hold'],
        );
        final Completer<int?> pidCompleter = Completer<int?>();
        final StringBuffer stdoutBuf = StringBuffer();
        stdoutSub = injectorProc.stdout
            .transform(const SystemEncoding().decoder)
            .listen(
          (String chunk) {
            stdoutBuf.write(chunk);
            final int? pid = parseInjectorHookedPid(stdoutBuf.toString());
            if (pid != null && !pidCompleter.isCompleted) {
              pidCompleter.complete(pid);
            }
          },
          onDone: () {
            if (!pidCompleter.isCompleted) {
              pidCompleter
                  .complete(parseInjectorHookedPid(stdoutBuf.toString()));
            }
          },
          onError: (Object _) {
            if (!pidCompleter.isCompleted) {
              pidCompleter.complete(null);
            }
          },
        );
        childPid = await pidCompleter.future
            .timeout(const Duration(seconds: 25), onTimeout: () => null);

        // 拿到子进程 PID 则 open 共享内存（injector 已建），引擎-hook 读侧就绪。
        if (childPid != null) {
          try {
            await voiceChannel
                .invokeMethod<void>('open', <String, Object?>{'pid': childPid});
          } on PlatformException {
            // open 失败：本轮走 loopback 兜底，不致命。
          } on MissingPluginException {
            // native 缺失（非 Windows / 未构建）：走 loopback 兜底。
          }
        }

        // d. 等游戏加载 + 出声。
        await Future<void>.delayed(const Duration(seconds: 8));

        // e. 引擎-hook 抓最近 4s（混音前干净语音）。
        final GalAudioSlice? engineSlice =
            await _grabEngineHook(voiceChannel, 4000);

        // f. loopback 抓最近 4s（系统混音兜底）。
        final GalAudioSlice? loopSlice = await loopback.grabRecent(4000);

        // g. 选源：引擎-hook 非空且非全静音优先，否则 loopback，否则无音频。
        final bool engineHasSound = engineSlice != null &&
            !engineSlice.isEmpty &&
            engineSlice.pcm.any((int b) => b != 0);
        GalAudioSlice? chosen;
        if (engineHasSound) {
          chosen = engineSlice;
          source = 'engine-hook';
          engineHook = true;
        } else if (loopSlice != null && !loopSlice.isEmpty) {
          chosen = loopSlice;
          source = 'loopback';
        } else {
          chosen = null;
          source = 'none';
        }

        if (chosen != null) {
          pcmBytes = chosen.pcm.length;
          final PcmFormat fmt = chosen.format;
          fmtLabel = '${fmt.sampleRate}/${fmt.channels}/${fmt.bitsPerSample}';

          // h. 取前 3s，拼 44 字节头 WAV（Anki 直接播 .wav，无需 ffmpeg）。
          final Uint8List sub = slicePcmByMs(chosen.pcm, fmt, 0, 3000);
          final Uint8List wav = buildWavBytes(sub, fmt);

          // i. 截图（可选，失败不致命）：优先 pid 命中，找不到用首个有标题窗口。
          final Uint8List? png = await _captureGameWindow(childPid);

          // j. dump wav + 可选 png + meta json 到 outDir（外层 bash 经 AnkiConnect 推卡）。
          final String wavPath = '$outDir/$mediaBase.wav';
          File(wavPath).writeAsBytesSync(wav);
          final bool hasPng = png != null && png.isNotEmpty;
          String? pngPath;
          if (hasPng) {
            pngPath = '$outDir/$mediaBase.png';
            File(pngPath).writeAsBytesSync(png);
          }
          final String metaPath = '$outDir/$mediaBase.json';
          File(metaPath).writeAsStringSync(jsonEncode(<String, Object?>{
            'mediaBase': mediaBase,
            'game': gameName,
            'source': source,
            'fmt': fmtLabel,
            'pcmBytes': pcmBytes,
            'wav': '$mediaBase.wav',
            'png': hasPng ? '$mediaBase.png' : null,
          }));
          noteId = metaPath;
          created++;
          print('GALCARD FILE $mediaBase wav=$wavPath '
              'png=${pngPath ?? "none"} source=$source');
        }
      } catch (e) {
        // 单个游戏失败不中断整批：记录后继续。
        print('GALCARD ERROR game=$gameName err=$e');
      } finally {
        // k. 清理：关通道 + 杀 injector + 收游戏尸 + 停 loopback。
        try {
          await voiceChannel.invokeMethod<void>('close');
        } on PlatformException {
          // ignore：关不掉不该影响清理
        } on MissingPluginException {
          // ignore：native 缺失，本就没开
        }
        await stdoutSub?.cancel();
        injectorProc?.kill();
        if (childPid != null) {
          try {
            Process.killPid(childPid); // injector 拉起的游戏是孤儿，显式收尸
          } catch (_) {}
        }
        try {
          await loopback.stop();
        } catch (_) {}
      }

      // l. 逐游戏结果行（无论成败）。
      print('GALCARD RESULT game=$gameName source=$source '
          'engineHook=$engineHook pcmBytes=$pcmBytes note=${noteId ?? 'null'} '
          'fmt=$fmtLabel');
    }

    print('GALCARD DONE created=$created/${games.length}');
    expect(created, greaterThan(0), reason: '一张卡都没制成');
  }, timeout: const Timeout(Duration(minutes: 8)));
}

/// 经 app.hibiki.reader/voice_hook 的 grabRecent 抓最近 [backMs] 毫秒引擎-hook PCM。
/// 用 [parseGalPcmFormat] 解格式；native 缺失 / error / 无数据返回 null（降级 loopback）。
Future<GalAudioSlice?> _grabEngineHook(
    MethodChannel channel, int backMs) async {
  try {
    final Map<Object?, Object?>? r =
        await channel.invokeMethod<Map<Object?, Object?>>(
      'grabRecent',
      <String, Object?>{'backMs': backMs},
    );
    if (r == null || r['error'] != null) {
      return null;
    }
    final Uint8List? pcm = r['pcm'] as Uint8List?;
    final PcmFormat? fmt = parseGalPcmFormat(r);
    if (pcm == null || pcm.isEmpty || fmt == null) {
      return null;
    }
    return GalAudioSlice(pcm: pcm, format: fmt);
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// 截游戏窗口：优先 pid==[childPid] 的窗口，找不到用首个非空标题窗口；截图失败返回 null。
Future<Uint8List?> _captureGameWindow(int? childPid) async {
  try {
    final List<ExternalWindowInfo> wins =
        await WindowCaptureChannel.listWindows();
    ExternalWindowInfo? target;
    if (childPid != null) {
      for (final ExternalWindowInfo w in wins) {
        if (w.pid == childPid) {
          target = w;
          break;
        }
      }
    }
    if (target == null) {
      for (final ExternalWindowInfo w in wins) {
        if (w.title.isNotEmpty) {
          target = w;
          break;
        }
      }
    }
    if (target == null) {
      return null;
    }
    final WindowCaptureResult res =
        await WindowCaptureChannel.captureWindow(target.hwnd).timeout(
            const Duration(seconds: 6),
            onTimeout: () =>
                const WindowCaptureResult(error: 'capture timeout'));
    return res.ok ? res.pngBytes : null;
  } catch (_) {
    return null; // 截图任何失败都不致命
  }
}

/// 取路径 [path] 的文件名（含扩展名），兼容 Windows(`\`) 与 POSIX(`/`) 分隔符。
String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

/// 取路径 [path] 的文件名（去扩展名）。
String _basenameWithoutExtension(String path) {
  final String name = _basename(path);
  final int dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// 把字符串清洗成纯 ASCII 字母数字（去掉其它字符，含中文/日文/符号）。
String _asciiSafe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
