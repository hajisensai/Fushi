import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/src/mining/galgame_audio_encode.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';

/// galgame 引擎-hook **launch 模式**真机集成测试（docs/specs/galgame-mining）。
///
/// 在真实 hibiki.exe 测试宿主里跑通整条新路径：
///   `EngineHookGalAudioSource(launchExe)` → `injector --launch`(CREATE_SUSPENDED 早注入)
///   → 游戏 DirectSound `Unlock` hook → 共享内存环形 → **hibiki.exe 自己的 `voice_hook`
///   native channel** `open`/`status`/`grabRecent` → 抓到真实非静音 PCM。
///
/// **不初始化 AppModel/Drift DB**（只 pump 平凡 widget 让 runner 的 native 通道就绪），
/// 故绝不碰生产库——避免开发版 app 开生产 DB 触发 schema 降级的红线。
///
/// 需要**环境变量**指到本机素材（缺任一则 skip、不误报失败，故 CI/无游戏机器上自动跳过）：
///   - `GALTEST_GAME_EXE`：目标游戏 exe（如 32 位 KiriKiriZ `otomeki.exe`）。
///   - `GALTEST_INJECTOR`：与游戏位数匹配的 `fushi_voice_injector.exe`
///     （helper 已迁至独立仓库 hibiki-hook，本机构建落 `build/<arch>/Release/`；
///     或 app 按需下载后落在 `<app>/voice_hook/<arch>/`）。
///
/// 实测（2026-07-18，otomeki.exe 32 位 KiriKiriZ）：
///   `GALTEST OK fmt=44100/2/16 float=false pcmBytes=529200`（=3s×44100×2×2，非静音）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('launch 模式引擎-hook 抓到真实 DirectSound PCM',
      (WidgetTester tester) async {
    // 只 pump 平凡 widget：让 runner 起来注册 voice_hook 通道，但不碰 AppModel/DB。
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump(const Duration(milliseconds: 200));

    final String? gameExe = Platform.environment['GALTEST_GAME_EXE'];
    final String? injector = Platform.environment['GALTEST_INJECTOR'];
    if (gameExe == null ||
        injector == null ||
        !File(gameExe).existsSync() ||
        !File(injector).existsSync()) {
      // ignore: avoid_print
      print('GALTEST SKIP: 未设 GALTEST_GAME_EXE/GALTEST_INJECTOR 或文件不存在');
      return; // 素材缺失：跳过（非失败）
    }

    final EngineHookGalAudioSource src = EngineHookGalAudioSource(
      launchExe: gameExe,
      injectorPath: injector,
      readyTimeout: const Duration(seconds: 30),
    );

    PcmFormat? fmt;
    int? gpid;
    try {
      // start：拉起游戏 + 早注入 + 轮询 status 等 hook 拿到语音格式。
      fmt = await src.start();
      gpid = src.gamePid;
      expect(fmt, isNotNull, reason: '引擎-hook 未就绪（注入失败 / DS hook 未命中 / 超时）');
      expect(fmt!.sampleRate, greaterThan(0));
      expect(fmt.channels, greaterThan(0));

      // 让标题 BGM 多播一会，再抓最近 3s。
      await Future<void>.delayed(const Duration(seconds: 8));
      final GalAudioSlice? slice = await src.grabRecent(3000);
      expect(slice, isNotNull, reason: 'grabRecent 无数据（环形空）');
      expect(slice!.pcm.isNotEmpty, true);

      // 非全静音：16-bit PCM 静音是 0 字节，出声必有非 0（粗略但足够判「真的抓到音」）。
      final bool hasSound = slice.pcm.any((int b) => b != 0);
      expect(hasSound, true, reason: '抓到的 PCM 全是静音');

      // ignore: avoid_print
      print('GALTEST OK fmt=${fmt.sampleRate}/${fmt.channels}/'
          '${fmt.bitsPerSample} float=${fmt.isFloat} pcmBytes=${slice.pcm.length} '
          'gpid=$gpid');
    } finally {
      await src.stop(); // 关通道 + 杀 injector
      if (gpid != null) {
        try {
          Process.killPid(gpid); // injector 拉起的游戏是孤儿，显式收尸
        } catch (_) {}
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
