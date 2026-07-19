import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:hibiki/src/mining/galgame_audio_encode.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/galgame_helper_installer.dart';
import 'package:hibiki/src/mining/galgame_library.dart';
import 'package:hibiki/src/mining/galgame_window_gif.dart';
import 'package:hibiki/src/mining/immersion_mining_request.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/utils.dart';

/// 制卡富化用「窗口封面」结果：字节 + 供 buildExternalWindowRequest 区分动图/静图的
/// 文件名（.gif = 动图，null = 单帧 PNG）。
typedef GalgameWindowCover = ({Uint8List bytes, String? name});

/// galgame 制卡会话的单例控制器（app 级 ChangeNotifier）：把原先散在被删的 TexthookerPage
/// 里的 galgame 启动+注入、文本 hook 轮询、句子↔语音配对缓存、游戏窗口绑定+封面截取逻辑收口
/// 在这里，与任何一个页面的生命周期解耦。
///
/// 与旧 texthooker tab 的关键差异（用户 UX 统一）：文本 hook 抓到的每条新台词行不再喂给
/// TexthookerService（独立文本列表页），而是走 DesktopLookupService.submitText —— 与剪贴板
/// 查词同一条去向路由，默认落到悬浮查词面板。用户在面板里点词查词/制卡，制卡出口
/// （HomeDictionaryPage.onMineEntry）在存在活跃会话时额外带该句配对语音 + 游戏窗口封面
/// （captureVoiceBytes / captureWindowCover）。
///
/// 仅 Windows 桌面有注入/窗口捕获能力；非 Windows 时 launch 优雅 toast 提示不支持，会话不
/// 激活，制卡链路行为与非 galgame 时完全一致（Never break）。
class GalgameSessionController extends ChangeNotifier {
  GalgameSessionController._();

  static final GalgameSessionController instance = GalgameSessionController._();

  /// 当前音频采集源（引擎-hook 干净语音 / loopback 系统混音）；null = 无会话。
  GalAudioSource? _galAudioSource;

  /// 引擎-hook 源（launch 模式成功时 == _galAudioSource）：额外能 pollText 抓台词、
  /// grabUtterance/grabClipNear 按句取语音、grabPairedVoiceBytes 取纯人声。loopback 源没有
  /// 这些能力，故单独持有引擎源引用。
  EngineHookGalAudioSource? _engineSource;

  /// 已绑定的游戏主窗口（制卡截图/封面用）；null = 未绑定。
  ExternalWindowInfo? _boundWindow;

  /// 文本 hook 轮询定时器 + 游标（已喂出的行序号）+ 最近一句台词的 hook 时间戳。
  Timer? _textPollTimer;
  int _lastTextSeq = 0;
  int _lastHookedLineTs = 0;

  /// 句子↔语音「出现即锁定」缓存（抗快进/环形覆盖）：每条台词行一出现（轮询到）就立刻按它的
  /// hook 时间戳抓好对应语音 clip 存这里（key = 台词文本）。制卡时直接取缓存，而非制卡那刻再
  /// 抓——用户快进/多行飞过后再挖某句，它的语音在出现那刻就锁好了、不会因环形覆盖或播放被切
  /// 而丢。LRU 上限 _voiceCacheMax，最旧的先淘汰。
  final Map<String, GalAudioSlice> _lineVoiceCache = <String, GalAudioSlice>{};

  /// 句子↔hook 时间戳缓存：纯人声 OGG 配对按这句的时间戳取语音（而非最近一句），故需记每行
  /// 文本对应的 hook 时间戳。与 _lineVoiceCache 同 LRU 上限、同步淘汰/清空。
  final Map<String, int> _lineTsCache = <String, int>{};
  static const int _voiceCacheMax = 200;

  /// 引擎-hook 拿不到按句 clip 时的兜底：从环形缓冲回看的时长（毫秒）。
  static const int _galAudioBackMs = 8000;

  /// 当前是否存在活跃 galgame 会话（已拉起音频源或已绑定窗口）。制卡富化据此门控——无会话时
  /// 制卡链路行为与非 galgame 时完全一致（Never break）。
  bool get hasActiveSession => _galAudioSource != null || _boundWindow != null;

  /// 是否可为制卡富化「窗口封面」（Windows 且已绑定游戏窗口）。
  bool get canCaptureWindowCover => Platform.isWindows && _boundWindow != null;

  /// 已绑定游戏窗口（供制卡 request 的 documentTitle / 封面 hwnd）；null = 未绑定。
  ExternalWindowInfo? get boundWindow => _boundWindow;

  /// 从游戏库点击一个游戏进入制卡：按其位数选 x86/x64 注入器 → Hibiki 拉起游戏并早注入
  /// （CREATE_SUSPENDED；KiriKiriZ 等「启动即建音频设备」的引擎必须走此路，attach 会漏）→
  /// 就绪后以引擎-hook 为音频源 + 接文本 hook 轮询（台词自动进悬浮查词面板）+ 按游戏 PID 找主
  /// 窗口绑定（制卡截图用）。非 Windows / 各步失败均明确 toast、不静默（起不来时保持原状）。
  Future<void> launch(GalgameEntry game, {required BuildContext context}) =>
      launchFromExe(game.exePath, context: context);

  /// launch 的核心：给定游戏 exe 路径完成上述启动 + 注入 + 接线 + 绑定窗口。
  Future<void> launchFromExe(String exe,
      {required BuildContext context}) async {
    if (!Platform.isWindows) {
      HibikiToast.show(msg: t.external_window_unsupported);
      return;
    }
    final bool? is32 = await EngineHookGalAudioSource.exeIs32Bit(exe);
    final bool is32Bit = is32 ?? false;
    String? injector = _resolveGalInjectorPath(is32Bit: is32Bit);
    if (injector == null) {
      // 注入器缺失（隔离 helper 未随包分发）：按需下载（方案 B）——弹确认对话框（标大小）
      // → 用户确认→下载对应架构 zip→sha256 校验→解压到 voice_hook/<arch>/。用户取消或
      // 下载失败则中止启动（已给提示，Never break）。
      if (!context.mounted) return;
      final bool installed = await GalgameHelperInstaller().ensureInjector(
        is32Bit: is32Bit,
        context: context,
      );
      if (!installed) return;
      injector = _resolveGalInjectorPath(is32Bit: is32Bit);
      if (injector == null) {
        HibikiToast.show(msg: t.galgame_helper_install_incomplete);
        return;
      }
    }
    HibikiToast.show(msg: '正在拉起游戏并注入引擎-hook…');
    final EngineHookGalAudioSource src = EngineHookGalAudioSource(
      launchExe: exe,
      injectorPath: injector,
    );
    final PcmFormat? fmt = await src.start();
    if (fmt == null) {
      await src.stop();
      HibikiToast.show(msg: 'galgame 引擎-hook 启动/注入失败');
      return;
    }
    // 引擎-hook 就绪：切成当前音频源 + 接上文本 hook 轮询。
    await _stopGalAudio();
    _galAudioSource = src;
    _onEngineHookReady(src);
    // 按游戏 PID 找主窗口绑定（制卡截图用）；窗口可能稍后才出现，轮询几次。
    final int? gpid = src.gamePid;
    ExternalWindowInfo? win;
    if (gpid != null) {
      for (int i = 0; i < 20 && win == null; i++) {
        for (final ExternalWindowInfo w
            in await WindowCaptureChannel.listWindows()) {
          if (w.pid == gpid) {
            win = w;
            break;
          }
        }
        if (win == null) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
    }
    _boundWindow = win;
    notifyListeners();
    HibikiToast.show(
      msg: win != null
          ? 'galgame 已启动，台词将进查词弹窗（${fmt.sampleRate}Hz/${fmt.channels}ch）'
          : 'galgame 已启动，台词将进查词弹窗；未找到游戏窗口，制卡封面暂不可用',
    );
  }

  /// 停止并释放当前会话（音频源 + 文本轮询 + 缓存 + 窗口绑定，幂等）。
  Future<void> stop() => _stopGalAudio();

  Future<void> _stopGalAudio() async {
    _textPollTimer?.cancel();
    _textPollTimer = null;
    _engineSource = null;
    _lastTextSeq = 0;
    _lastHookedLineTs = 0;
    _lineVoiceCache.clear();
    _lineTsCache.clear();
    final GalAudioSource? src = _galAudioSource;
    _galAudioSource = null;
    final bool hadSession = _boundWindow != null || src != null;
    _boundWindow = null;
    await src?.stop();
    if (hadSession) notifyListeners();
  }

  /// 引擎-hook 就绪后：记住引擎源 + 起定时器轮询我们文本 hook 抓到的台词，喂进悬浮查词面板
  /// （真句子来源，非 OCR）。约 400ms 一轮。
  void _onEngineHookReady(EngineHookGalAudioSource eng) {
    _engineSource = eng;
    _lastTextSeq = 0;
    _lastHookedLineTs = 0;
    // 清上一局残留的语音 dump（本会话新 dump 都留着），避免跨会话无限增长撑爆磁盘。
    unawaited(eng.pruneVoiceDump());
    _textPollTimer?.cancel();
    _textPollTimer = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => unawaited(_pollHookedText()),
    );
  }

  /// 轮询文本 hook 的新台词行 → 喂进悬浮查词面板（DesktopLookupService.submitText，与剪贴板
  /// 查词同一去向路由）+ 记这句的 hook 时间戳并「出现即锁定」它的语音（供按句取语音配对）。
  Future<void> _pollHookedText() async {
    final EngineHookGalAudioSource? eng = _engineSource;
    if (eng == null) {
      return;
    }
    final GalTextPoll? poll = await eng.pollText(_lastTextSeq);
    if (poll == null || _engineSource == null) {
      return;
    }
    for (final GalHookedLine line in poll.lines) {
      // 台词进悬浮查词面板（与剪贴板文本同去向；destination 默认空串 → panel）。
      DesktopLookupService.instance.submitText(line.text);
      _lastHookedLineTs = line.timestampMs;
      _cacheLineTs(line.text, line.timestampMs);
      // 出现即锁定该行语音（抗快进/环形覆盖）：立刻按 hook 时间戳抓好缓存起来。整句优先
      // （grabUtterance 拼同源整段，含用户手动选轨），失败退回单 clip（grabClipNear）。
      final GalAudioSlice? clip = await eng.grabUtterance(line.timestampMs) ??
          await eng.grabClipNear(line.timestampMs);
      if (clip != null && !clip.isEmpty) {
        _cacheLineVoice(line.text, clip);
      }
    }
    if (poll.count > _lastTextSeq) {
      _lastTextSeq = poll.count;
    }
  }

  /// 把台词行 text 的语音 clip 存进「出现即锁定」LRU 缓存（同文本更新为最新，超上限淘汰最旧）。
  void _cacheLineVoice(String text, GalAudioSlice clip) {
    _lineVoiceCache.remove(text);
    _lineVoiceCache[text] = clip;
    while (_lineVoiceCache.length > _voiceCacheMax) {
      _lineVoiceCache.remove(_lineVoiceCache.keys.first);
    }
  }

  /// 记这句台词 text 的 hook 时间戳 ts（LRU，与 _cacheLineVoice 同上限）。供制卡时按这句的
  /// 时间戳做纯人声 OGG 配对，而非只用最近一句时间戳。
  void _cacheLineTs(String text, int ts) {
    _lineTsCache.remove(text);
    _lineTsCache[text] = ts;
    while (_lineTsCache.length > _voiceCacheMax) {
      _lineTsCache.remove(_lineTsCache.keys.first);
    }
  }

  /// 解析 galgame 引擎-hook 注入器（隔离 helper 组件）绝对路径：约定放在 app 可执行文件同级
  /// voice_hook/<arch>/hibiki_voice_injector.exe（随包分发/按需下载，报毒代码不进本体）。
  /// is32Bit 决定 arch 目录（目标 32 位→x86，否则→x64；注入 DLL 位数必须匹配目标）。非 Windows
  /// / 不存在返回 null（引擎-hook 不可用）。
  String? _resolveGalInjectorPath({required bool is32Bit}) {
    if (!Platform.isWindows) {
      return null;
    }
    try {
      final String dir = File(Platform.resolvedExecutable).parent.path;
      final String arch = is32Bit ? 'x86' : 'x64';
      final String path = '$dir\\voice_hook\\$arch\\hibiki_voice_injector.exe';
      return File(path).existsSync() ? path : null;
    } catch (_) {
      return null;
    }
  }

  /// 制卡富化用「游戏窗口封面」：默认出 GIF 短动图（抓角色口型/眨眼）——先试多帧 GIF；不成
  /// （帧不足/无 ffmpeg/编码失败）回退单帧 PNG；单帧也失败返回 null（调用方退化为无封面卡）。
  /// 无绑定窗口/非 Windows 返回 null。
  Future<GalgameWindowCover?> captureWindowCover() async {
    final ExternalWindowInfo? bound = _boundWindow;
    if (bound == null || !Platform.isWindows) {
      return null;
    }
    final Uint8List? gifBytes = await captureWindowGifBytes(hwnd: bound.hwnd);
    if (gifBytes != null && gifBytes.isNotEmpty) {
      return (bytes: gifBytes, name: 'external_window.gif');
    }
    final WindowCaptureResult cap =
        await WindowCaptureChannel.captureWindow(bound.hwnd);
    if (cap.ok) {
      return (bytes: cap.pngBytes!, name: null);
    }
    return null;
  }

  /// 制卡富化用「该句配对语音」：从当前音频源为句子 sentence 抓语音并编码成 AAC/m4a 容器字节。
  /// 无源/无数据/切空/编码失败任一步 → 返回 null（调用方退化为纯截图卡，Never break）。
  Future<Uint8List?> captureVoiceBytes(String sentence) async {
    final GalAudioSource? src = _galAudioSource;
    if (src == null) {
      return null;
    }
    final EngineHookGalAudioSource? eng = _engineSource;
    // 最优先：引擎级纯人声——按这句台词的 hook 时间戳，在 injector hook DLL dump 的语音 OGG 里
    // 配对出这句对应的原始语音（混音前、无 BGM/SE），转码成 aac 直接作 providedAudioBytes。句子
    // 文本命中 ts 缓存用该行时间戳，否则退回最近一句时间戳。仅 KiriKiri 等有引擎-hook dump 的
    // 引擎命中；其它引擎/loopback 落到下面的采集链。
    if (eng != null && Platform.isWindows) {
      final int ts = _lineTsCache[sentence] ?? _lastHookedLineTs;
      if (ts > 0) {
        final Uint8List? voice = await eng.grabPairedVoiceBytes(
          ts,
          outputExtension: immersionMiningAudioExtension(),
        );
        if (voice != null && voice.isNotEmpty) {
          return voice;
        }
      }
    }
    // 以下为 PCM 采集链回退（loopback / 非 KiriKiri 引擎 / 无 dump / 配对失败）。
    GalAudioSlice? slice;
    // 这句台词出现那刻就锁定的语音（_lineVoiceCache）——抗快进/环形覆盖。挖的句子与文本 hook 的
    // 行文本一致时命中。
    final GalAudioSlice? cached = _lineVoiceCache[sentence];
    if (cached != null && !cached.isEmpty) {
      slice = cached;
    }
    // 缓存未命中（该句在接线前出现/文本不完全一致）：按最近台词时间戳现抓该句 clip。
    if ((slice == null || slice.isEmpty) &&
        eng != null &&
        _lastHookedLineTs > 0) {
      slice = await eng.grabUtterance(_lastHookedLineTs) ??
          await eng.grabClipNear(_lastHookedLineTs);
    }
    // 兜底（loopback / 无 clip）：取最近 N 秒（仍全自动、不弹波形选区）。
    slice ??= await src.grabRecent(_galAudioBackMs);
    if (slice == null || slice.isEmpty) {
      return null;
    }
    return pcmSliceToAacBytes(
      pcm: slice.pcm,
      format: slice.format,
      tempDir: Directory.systemTemp.path,
      outputExtension: immersionMiningAudioExtension(),
    );
  }
}
