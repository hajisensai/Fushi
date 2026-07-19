import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/mining/external_window_mining.dart';
import 'package:hibiki/src/mining/galgame_audio_encode.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/galgame_library.dart';
import 'package:hibiki/src/mining/galgame_window_gif.dart';
import 'package:hibiki/src/mining/immersion_mining_engine.dart';
import 'package:hibiki/src/mining/immersion_mining_request.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/utils/misc/swipe_dismiss_wrapper.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/utils.dart';

/// 独立 texthooker tab：实时展示 WebSocket 收到的文本行，逐词查词 + 挖词。
///
/// 订阅单例 [TexthookerService]（ChangeNotifier）实时刷新文本行；每行经日语分词
/// 成可点 span，点击后经 [DictionaryPageMixin.pushNestedPopup] 弹查词浮层，挖词
/// 复用 mixin 的 Anki 逻辑。
class TexthookerPage extends ConsumerStatefulWidget {
  const TexthookerPage({super.key, this.autoLaunchGame});

  /// 从游戏库（[GamesLibraryPage]）点击某个游戏进入时携带的待启动条目：非 null 时
  /// 页面挂载后自动走引擎-hook launch 路径拉起该游戏并注入（等价于用户手点「拉起
  /// galgame」并选中这个 exe），随后文本 hook 喂进 texthooker、用户点词制卡。作为
  /// 首页 texthooker tab 使用时为 null（`const TexthookerPage()`），行为不变。
  final GalgameEntry? autoLaunchGame;

  @override
  ConsumerState<TexthookerPage> createState() => _TexthookerPageState();
}

class _TexthookerPageState extends ConsumerState<TexthookerPage>
    with DictionaryPageMixin {
  final DictionaryPopupController _popup = DictionaryPopupController(
    lowMemory: false,
    onLookupStackDepthChanged: recordLookupStackDepth,
  );
  final ScrollController _scroll = ScrollController();

  /// TODO-1162 外部窗口挖矿模式（仅 Windows）：开启后制卡额外截绑定窗口当前帧作封面。
  bool _externalWindowMode = false;

  /// 已绑定的目标外部窗口（null = 未绑定；未绑定时制卡回落普通逐词制卡）。
  ExternalWindowInfo? _boundWindow;

  /// galgame 一键制卡（docs/specs/galgame-mining）：外部窗口模式下抓「最近一段」音频的采集源。
  /// 引擎-hook（干净语音）优先、不可用回退 loopback（系统混音）；都不可用 / 非 Windows 时为
  /// null（退化为纯截图卡，Never break）。外部模式打开且绑定窗口时启动（环形缓冲持续累积），
  /// 关闭 / 解绑 / 换窗口 / dispose 时停止。
  GalAudioSource? _galAudioSource;

  /// 引擎-hook 源（launch 模式成功时 = [_galAudioSource]）：额外能 pollText 抓台词、grabClipNear
  /// 按句取语音。loopback 源没有这俩能力，故单独持有引擎源引用。
  EngineHookGalAudioSource? _engineSource;

  /// 文本 hook 轮询定时器 + 游标（已喂到 texthooker 的行序号）+ 最近一句台词的 hook 时间戳。
  Timer? _textPollTimer;
  int _lastTextSeq = 0;
  int _lastHookedLineTs = 0;

  /// **句子↔语音「出现即锁定」缓存**（抗快进/环形覆盖）：每条台词行一出现（轮询到），就立刻按
  /// 它的 hook 时间戳抓好对应语音 clip 存这里（key=台词文本）。制卡时直接取缓存,而非制卡那刻再
  /// 抓——用户快进/多行飞过后再挖某句,它的语音在出现那刻就锁好了、不会因环形覆盖或播放被切而丢。
  /// LRU 上限 [_voiceCacheMax]，最旧的先淘汰。
  final Map<String, GalAudioSlice> _lineVoiceCache = <String, GalAudioSlice>{};

  /// 句子↔hook 时间戳缓存：纯人声 OGG 配对按**这句**的时间戳取语音（而非最近一句），故需
  /// 记每行文本对应的 hook 时间戳。与 [_lineVoiceCache] 同 LRU 上限、同步淘汰/清空。
  final Map<String, int> _lineTsCache = <String, int>{};
  static const int _voiceCacheMax = 200;

  /// 热键那一刻从环形缓冲回看的时长（毫秒）：引擎-hook 拿不到按句 clip 时的兜底取最近这么久。
  static const int _galAudioBackMs = 8000;

  /// 缓存的 [AppModel] 引用（`appProvider` 为单例，实例不变）。在 [initState] 一次性
  /// 读取：浮层层在 `LayoutBuilder` 回调里访问 `mixinAppModel`，widget 失活后再
  /// `ref.read` 会抛「deactivated widget's ancestor」（与视频页同源），缓存实例规避。
  late final AppModel _appModel = ref.read(appProvider);

  @override
  AppModel get mixinAppModel => _appModel;

  @override
  ThemeData get mixinTheme => Theme.of(context);

  @override
  void initState() {
    super.initState();
    TexthookerService.instance.addListener(_onLines);
    // TODO-1204：接线查词计数（每次查词 +1 → lookup_mining_counters）。
    attachLookupCounter(_popup);
    // 从游戏库点进来（携带 autoLaunchGame）时：挂载后自动拉起该游戏并注入。放到首帧
    // 之后跑，避免在 initState 里 toast / 用 context。
    final GalgameEntry? game = widget.autoLaunchGame;
    if (game != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_launchGalgameFromExe(game.exePath));
        }
      });
    }
  }

  @override
  void dispose() {
    TexthookerService.instance.removeListener(_onLines);
    unawaited(_stopGalAudio());
    _popup.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// TODO-1162：外部窗口挖矿模式下覆写制卡——先截绑定窗口当前帧作封面，再连同当前句
  /// 走 [ImmersionMiningEngine]（与 Netflix 后台捕获同形状）。未开启 / 未绑定 / 非
  /// Windows 时回落 [DictionaryPageMixin.onMineEntry] 的普通逐词制卡（Never break）。
  @override
  Future<MinePopupResult> onMineEntry(Map<String, String> fields) async {
    final ExternalWindowInfo? bound = _boundWindow;
    if (!_externalWindowMode || bound == null || !Platform.isWindows) {
      return super.onMineEntry(fields);
    }
    HibikiToast.showMine(
      msg: t.card_mining_pending,
      status: MineToastStatus.pending,
    );
    // 画面默认出 GIF 短动图（抓角色口型/眨眼）：先试多帧 GIF；不成（帧不足 / 无
    // ffmpeg / 编码失败）回退单帧 PNG。GIF 成时 [coverName]=.gif 让引擎按动图封面处理，
    // 单帧回退不传 coverName（=png）。两者都失败才报错中止（fail-open，不产出空壳卡）。
    final Uint8List? gifBytes = await captureWindowGifBytes(hwnd: bound.hwnd);
    Uint8List? coverBytes = gifBytes;
    String? coverName = gifBytes != null ? 'external_window.gif' : null;
    if (coverBytes == null) {
      final WindowCaptureResult cap =
          await WindowCaptureChannel.captureWindow(bound.hwnd);
      if (!cap.ok) {
        // 单帧也失败：明确报错，不产出空壳卡（fail-open，不静默假成功）。
        HibikiToast.showMine(
          msg: cap.error != null
              ? '${t.external_window_capture_failed}：${cap.error}'
              : t.external_window_capture_failed,
          status: MineToastStatus.failed,
        );
        return const MinePopupResult();
      }
      coverBytes = cap.pngBytes;
    }
    // galgame 一键制卡：若音频源已开，抓最近一段 → 波形选区 → 帧对齐切片 → 编码成 AAC/m4a
    // 容器字节。任一步不成（无源/无数据/用户取消/切空/编码失败）→ audioBytes 保持 null，
    // 退化为纯截图卡（Never break：截图卡本就无声，不因无音频中止）。
    final Uint8List? audioBytes =
        await _captureGalAudioBytes(fields['sentence'] ?? '');

    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    final MiningMediaCompression compression = MiningMediaCompression.resolve(
      imageTier: mixinAppModel.miningImageQuality,
      audioTier: mixinAppModel.miningAudioQuality,
    );
    final ImmersionMiningResult res = await ImmersionMiningEngine().mine(
      buildExternalWindowRequest(
        fields: fields,
        sentence: fields['sentence'] ?? '',
        screenshotBytes: coverBytes,
        coverName: coverName,
        audioBytes: audioBytes,
        documentTitle: bound.title.isEmpty ? 'External window' : bound.title,
      ),
      compression: compression,
      tempDir: Directory.systemTemp.path,
      repo: repo,
    );
    if (res.aborted) {
      HibikiToast.showMine(
        msg: res.abortReason != null
            ? '${t.external_window_capture_failed}：${res.abortReason}'
            : t.external_window_capture_failed,
        status: MineToastStatus.failed,
      );
      return const MinePopupResult();
    }
    final MineOutcome outcome = res.outcome! as MineOutcome;
    final String deckName = outcome.result == MineResult.success
        ? (await repo.loadSettings()).selectedDeckName ?? ''
        : '';
    final described = describeMineOutcome(outcome, deckName: deckName);
    if (described.record) {
      unawaited(recordMined());
      unawaited(recordMinedSentence(fields, outcome.noteId));
    }
    HibikiToast.showMine(msg: described.message, status: described.status);
    if (described.success) {
      return MinePopupResult(ankiConnect: true, noteId: outcome.noteId);
    }
    return const MinePopupResult();
  }

  /// 切换外部窗口挖矿模式；首次开启且未绑定窗口时直接拉起窗口选择器。
  void _toggleExternalWindowMode() {
    final bool next = !_externalWindowMode;
    setState(() => _externalWindowMode = next);
    if (next) {
      final ExternalWindowInfo? bound = _boundWindow;
      if (bound == null) {
        _pickExternalWindow(); // 绑定成功后由 _pickExternalWindow 启动音频源
      } else {
        unawaited(_startGalAudio(bound));
      }
    } else {
      unawaited(_stopGalAudio());
    }
  }

  /// 拉起窗口选择器：列 native 返回的可捕获顶层窗口，选一个绑定。native 不可用 /
  /// 无窗口 / 非 Windows 时以 toast 明确提示（不静默）。
  Future<void> _pickExternalWindow() async {
    if (!Platform.isWindows) {
      HibikiToast.show(msg: t.external_window_unsupported);
      return;
    }
    final List<ExternalWindowInfo> windows =
        await WindowCaptureChannel.listWindows();
    if (windows.isEmpty) {
      HibikiToast.show(msg: t.external_window_no_windows);
      return;
    }
    if (!context.mounted) return;
    final ExternalWindowInfo? picked = await showDialog<ExternalWindowInfo>(
      context: context,
      builder: (BuildContext ctx) => SimpleDialog(
        title: Text(t.external_window_select),
        children: <Widget>[
          for (final ExternalWindowInfo w in windows)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(w),
              child: Text(
                w.title.isEmpty ? '#${w.hwnd}' : w.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
    if (picked != null && mounted) {
      setState(() => _boundWindow = picked);
      // 换/新绑窗口：按新 PID 重启音频源（引擎-hook 需对准新进程）。
      if (_externalWindowMode) {
        unawaited(_startGalAudio(picked));
      }
    }
  }

  /// galgame 一键制卡：为绑定窗口 [bound] 启动音频采集源。引擎-hook（干净语音）优先——有隔离
  /// 注入器 + 有效 PID 才试，其 [EngineHookGalAudioSource.start] 会拉起 injector 子进程注入并
  /// 等 hook 就绪；不可用（无注入器 / 无该引擎 / 超时）自动回退 loopback（系统混音）；两者都
  /// 起不来时 [_galAudioSource] 保持 null（纯截图卡）。先停旧源（换窗口 / 换 PID）。
  Future<void> _startGalAudio(ExternalWindowInfo bound) async {
    await _stopGalAudio();
    if (!Platform.isWindows) {
      return;
    }
    // 按目标进程位数选注入器（DLL 位数必须匹配目标：KiriKiri 多为 32 位→x86，否则 x64）。
    // 查不到位数时默认 x64（hibiki 本体 arch）；不匹配时注入失败会自动回退 loopback。
    final bool? wow64 = await EngineHookGalAudioSource.targetIsWow64(bound.pid);
    final String? injector = _resolveGalInjectorPath(is32Bit: wow64 ?? false);
    if (injector != null && bound.pid > 0) {
      final EngineHookGalAudioSource eng = EngineHookGalAudioSource(
        targetPid: bound.pid,
        injectorPath: injector,
      );
      if (await eng.start() != null) {
        _galAudioSource = eng; // 引擎-hook 就绪：干净语音
        _onEngineHookReady(eng); // 接上文本 hook 轮询（喂 texthooker）
        return;
      }
      await eng.stop();
    }
    final LoopbackGalAudioSource loopback = LoopbackGalAudioSource();
    if (await loopback.start() != null) {
      _galAudioSource = loopback; // 回退：系统混音
      return;
    }
    await loopback.stop();
    _galAudioSource = null;
  }

  /// 停止并释放当前音频采集源（幂等）+ 停文本 hook 轮询。
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
    await src?.stop();
  }

  /// 引擎-hook 就绪后：记住引擎源 + 起定时器轮询我们文本 hook 抓到的台词，喂进 Hibiki
  /// texthooker（真句子来源，非 OCR）。约 400ms 一轮。
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

  /// 轮询文本 hook 的新台词行 → 喂 texthooker + 记最近一句的 hook 时间戳（供按句取语音配对）。
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
      TexthookerService.instance.appendLine(line.text);
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

  /// 把台词行 [text] 的语音 clip [clip] 存进「出现即锁定」LRU 缓存（同文本更新为最新，超上限淘汰
  /// 最旧）。
  void _cacheLineVoice(String text, GalAudioSlice clip) {
    _lineVoiceCache.remove(text);
    _lineVoiceCache[text] = clip;
    while (_lineVoiceCache.length > _voiceCacheMax) {
      _lineVoiceCache.remove(_lineVoiceCache.keys.first);
    }
  }

  /// 记这句台词 [text] 的 hook 时间戳 [ts]（LRU，与 [_cacheLineVoice] 同上限）。供制卡时按
  /// **这句**的时间戳做纯人声 OGG 配对，而非只用最近一句时间戳。
  void _cacheLineTs(String text, int ts) {
    _lineTsCache.remove(text);
    _lineTsCache[text] = ts;
    while (_lineTsCache.length > _voiceCacheMax) {
      _lineTsCache.remove(_lineTsCache.keys.first);
    }
  }

  /// 解析 galgame 引擎-hook 注入器（隔离 helper 组件）绝对路径：约定放在 app 可执行文件同级
  /// `voice_hook/<arch>/hibiki_voice_injector.exe`（随包分发 / 按需下载，报毒代码不进本体）。
  /// [is32Bit] 决定 arch 目录（目标 32 位→`x86`，否则→`x64`；注入 DLL 位数必须匹配目标）。
  /// 非 Windows / 不存在返回 null（引擎-hook 不可用，回退 loopback）。
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

  /// galgame 引擎-hook（launch 模式）：选游戏 exe → 按其位数选 x86/x64 注入器 → Hibiki **拉起
  /// 游戏并早注入**（CREATE_SUSPENDED；KiriKiriZ 等「启动即建音频设备」的引擎必须走此路，attach
  /// 会漏）→ 就绪后以引擎-hook 为音频源，并按游戏 PID 找主窗口绑定（制卡截图用）。任一步失败
  /// 明确 toast、不静默（起不来时保持原状，用户仍可用「绑定窗口 + loopback」路径）。
  Future<void> _launchGalgameEngineHook() async {
    if (!Platform.isWindows) {
      HibikiToast.show(msg: t.external_window_unsupported);
      return;
    }
    final FilePickerResult? picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['exe'],
    );
    final String? exe = (picked != null && picked.files.isNotEmpty)
        ? picked.files.first.path
        : null;
    if (exe == null) {
      return; // 用户取消
    }
    await _launchGalgameFromExe(exe);
  }

  /// [_launchGalgameEngineHook] 的核心：给定游戏 exe 路径，按其位数选 x86/x64 注入器 →
  /// Hibiki 拉起游戏并早注入 → 就绪后以引擎-hook 为音频源 + 接文本 hook + 按 PID 找主
  /// 窗口绑定（截图用）。游戏库点击进入（[TexthookerPage.autoLaunchGame]）与页头「拉起
  /// galgame」按钮共用此方法，避免重复 launch 逻辑。非 Windows / 各步失败均明确 toast、
  /// 不静默（起不来时保持原状，用户仍可用「绑定窗口 + loopback」路径）。
  Future<void> _launchGalgameFromExe(String exe) async {
    if (!Platform.isWindows) {
      HibikiToast.show(msg: t.external_window_unsupported);
      return;
    }
    final bool? is32 = await EngineHookGalAudioSource.exeIs32Bit(exe);
    final String? injector = _resolveGalInjectorPath(is32Bit: is32 ?? false);
    if (injector == null) {
      HibikiToast.show(
        msg:
            'galgame 引擎-hook 注入器缺失（voice_hook/${(is32 ?? false) ? 'x86' : 'x64'}）',
      );
      return;
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
    if (!mounted) {
      return;
    }
    setState(() {
      _externalWindowMode = true;
      if (win != null) {
        _boundWindow = win;
      }
    });
    HibikiToast.show(
      msg: win != null
          ? 'galgame 引擎-hook 就绪（${fmt.sampleRate}Hz/${fmt.channels}ch）'
          : 'galgame 引擎-hook 就绪；未找到游戏窗口，截图暂不可用',
    );
  }

  /// 从当前音频源抓最近一段 → 波形选区对话框 → 帧对齐切片 → 编码成 AAC/m4a 容器字节。
  /// 无源 / 无数据 / 用户取消 / 切空 / 编码失败任一步 → 返回 null（调用方退化为纯截图卡）。
  Future<Uint8List?> _captureGalAudioBytes(String sentence) async {
    final GalAudioSource? src = _galAudioSource;
    if (src == null) {
      return null;
    }
    final EngineHookGalAudioSource? eng = _engineSource;
    // ⓪ 最优先：引擎级**纯人声**——按这句台词的 hook 时间戳，在 injector hook DLL dump 的语音
    //    OGG 里配对出这句对应的原始语音（混音前、无 BGM/SE），转码成 aac 直接作
    //    providedAudioBytes。句子文本命中 ts 缓存用**该行**时间戳，否则退回最近一句时间戳。
    //    仅 KiriKiri 等有引擎-hook dump 的引擎命中；其它引擎/loopback 落到下面的采集链。
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
    // ① 这句台词**出现那刻就锁定**的语音（`_lineVoiceCache`）——抗快进/环形覆盖。挖的句子
    //    （fields['sentence']）与文本 hook 的行文本一致时命中。
    final GalAudioSlice? cached = _lineVoiceCache[sentence];
    if (cached != null && !cached.isEmpty) {
      slice = cached;
    }
    // ② 缓存未命中（该句在接线前出现/文本不完全一致）：按最近台词时间戳现抓该句 clip。
    if ((slice == null || slice.isEmpty) &&
        eng != null &&
        _lastHookedLineTs > 0) {
      slice = await eng.grabUtterance(_lastHookedLineTs) ??
          await eng.grabClipNear(_lastHookedLineTs);
    }
    // ③ 兜底（loopback / 无 clip）：取最近 N 秒（仍全自动、不弹波形选区）。
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

  /// 外部窗口挖矿模式条：展示已绑定窗口标题 + 重选/解绑；未绑定时点击选窗口。
  Widget _buildExternalWindowBar(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final ExternalWindowInfo? bound = _boundWindow;
    return Material(
      // 走共享设计 token 的语义 overlay 面（顶层容器面调性），不在页面里直接引原始
      // ColorScheme 面 token（MD3 守卫要求 ordinary chrome 走共享组件）。
      color: HibikiDesignTokens.of(context).surfaces.overlay,
      child: InkWell(
        onTap: _pickExternalWindow,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: <Widget>[
              Icon(Icons.crop_free, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  bound == null
                      ? t.external_window_none
                      : (bound.title.isEmpty ? '#${bound.hwnd}' : bound.title),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              if (bound != null)
                IconButton(
                  tooltip: t.external_window_unbind,
                  icon: const Icon(Icons.link_off, size: 18),
                  onPressed: () {
                    setState(() => _boundWindow = null);
                    unawaited(_stopGalAudio()); // 解绑：停音频源（无目标）
                  },
                ),
              IconButton(
                tooltip: t.external_window_refresh,
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: _pickExternalWindow,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _onLines() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  /// TODO-1052：查词浮层 barrier 上「桌面水平拖过阈关一层」的纯状态追踪器（与
  /// reader/audiobook、video、home_dictionary 共用 [BarrierSwipeDismissTracker]）。
  final BarrierSwipeDismissTracker _barrierSwipe = BarrierSwipeDismissTracker();

  /// texthooker 每次点词 `replaceStack: true`，可见栈至多一层（+ 隐藏热槽）；关一层
  /// 即收起当前查词。逐层关索引取最后可见层（无可见层回退 0，与 barrier 只在有可见层
  /// 时才渲染一致）。
  int get _topVisiblePopupIndex {
    final int i = _popup.lastVisibleIndex;
    return i < 0 ? 0 : i;
  }

  void _onBarrierHorizontalDragStart(DragStartDetails details) {
    _barrierSwipe.begin();
  }

  void _onBarrierHorizontalDragUpdate(DragUpdateDetails details) {
    _barrierSwipe.update(details.delta.dx);
  }

  void _onBarrierHorizontalDragEnd(DragEndDetails details) {
    if (_barrierSwipe.end(
      sensitivity: ReaderHibikiSource.instance.dismissSwipeSensitivity,
    )) {
      popNestedPopupAt(_topVisiblePopupIndex, _popup);
    }
  }

  void _onWordTap(String word, Rect rect) {
    pushNestedPopup(
      query: word,
      selectionRect: rect,
      controller: _popup,
      replaceStack: true,
      autoRead: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<String> lines = TexthookerService.instance.lines;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.texthooker),
        actions: <Widget>[
          if (Platform.isWindows)
            IconButton(
              tooltip: t.external_window_mining,
              icon: Icon(
                Icons.crop_free,
                color: _externalWindowMode
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              onPressed: _toggleExternalWindowMode,
            ),
          if (Platform.isWindows)
            IconButton(
              // galgame 引擎-hook：Hibiki 拉起游戏 exe 并早注入（KiriKiriZ 等启动即建音频
              // 设备的引擎必须走此路，见 docs/specs/galgame-mining）。文案暂用中文占位。
              tooltip: '拉起 galgame（引擎-hook 音频）',
              icon: const Icon(Icons.rocket_launch_outlined),
              onPressed: _launchGalgameEngineHook,
            ),
          IconButton(
            tooltip: t.clear,
            icon: const Icon(Icons.delete_outline),
            onPressed: TexthookerService.instance.clear,
          ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          Column(
            children: <Widget>[
              _buildExperimentalBanner(context),
              if (_externalWindowMode) _buildExternalWindowBar(context),
              Expanded(
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: lines.length,
                  itemBuilder: (BuildContext context, int i) =>
                      _TexthookerLine(text: lines[i], onWordTap: _onWordTap),
                ),
              ),
            ],
          ),
          ..._buildPopups(context),
        ],
      ),
    );
  }

  /// texthooker 为实验性功能：页头下方常驻一条提示横幅，复用视频 tab
  /// （[HomeVideoPage]）同款 secondaryContainer 调性与 textTheme，不抢内容焦点。
  Widget _buildExperimentalBanner(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: colors.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.science_outlined,
            size: 18,
            color: colors.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t.texthooker_experimental_banner,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSecondaryContainer,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildPopups(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    return <Widget>[
      // TODO-1052：查词浮层显示（或搜索中）时叠一层全屏 dismiss barrier——点真空白关一层
      // （逐层关，与其它表面同语义），桌面开滑动关闭时水平拖过阈亦关一层。texthooker 原
      // 先无 barrier（点外面关不掉浮层）；本层是附加的关闭手势，不改逐词查词点击本身。
      if (_popup.hasVisiblePopup || _popup.isSearchingUi)
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => popNestedPopupAt(_topVisiblePopupIndex, _popup),
            onHorizontalDragStart:
                ReaderHibikiSource.instance.enableSwipeToClose
                    ? _onBarrierHorizontalDragStart
                    : null,
            onHorizontalDragUpdate:
                ReaderHibikiSource.instance.enableSwipeToClose
                    ? _onBarrierHorizontalDragUpdate
                    : null,
            onHorizontalDragEnd: ReaderHibikiSource.instance.enableSwipeToClose
                ? _onBarrierHorizontalDragEnd
                : null,
            child: const ColoredBox(color: Colors.transparent),
          ),
        ),
      // 搜索期加载占位卡（搜索→就绪才显示，与首页查词同观感）。
      if (_popup.isSearchingUi && _popup.pendingRect != null)
        buildPopupLoadingPlaceholder(
          rect: _popup.pendingRect!,
          screen: screen,
        ),
      for (int i = 0; i < _popup.entries.length; i++)
        buildNestedPopupLayer(
          index: i,
          screen: screen,
          controller: _popup,
          onPush: (String text, Rect rect) => pushNestedPopup(
            query: text,
            selectionRect: rect,
            controller: _popup,
          ),
          onPop: (int index) => popNestedPopupAt(index, _popup),
        ),
    ];
  }
}

/// 一行文本：日语分词成可点 span（引擎未初始化时按字符降级，widget 测试不崩）。
class _TexthookerLine extends StatelessWidget {
  const _TexthookerLine({required this.text, required this.onWordTap});

  final String text;
  final void Function(String word, Rect rect) onWordTap;

  @override
  Widget build(BuildContext context) {
    final List<String> words = JapaneseLanguage.instance.textToWords(text);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        children: <Widget>[
          for (final String w in words) _WordSpan(word: w, onTap: onWordTap),
        ],
      ),
    );
  }
}

/// 单个可点词 span：点击时上报全局选区矩形供浮层定位。
class _WordSpan extends StatelessWidget {
  const _WordSpan({required this.word, required this.onTap});

  final String word;
  final void Function(String word, Rect rect) onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapUp: (TapUpDetails details) {
        final RenderBox box = context.findRenderObject()! as RenderBox;
        final Offset topLeft = box.localToGlobal(Offset.zero);
        onTap(word, topLeft & box.size);
      },
      child: Text(
        word,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.6),
      ),
    );
  }
}
