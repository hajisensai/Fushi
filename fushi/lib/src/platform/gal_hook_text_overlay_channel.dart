import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/platform/floating_overlay_channel.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

@immutable
class GalHookTextWindowRect {
  const GalHookTextWindowRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final int left;
  final int top;
  final int width;
  final int height;

  bool get isValid => width > 0 && height > 0;

  Map<String, Object?> toMap() => <String, Object?>{
        'left': left,
        'top': top,
        'width': width,
        'height': height,
      };

  static GalHookTextWindowRect? fromMap(Map<Object?, Object?> map) {
    int? value(String key) => (map[key] as num?)?.toInt();
    final GalHookTextWindowRect rect = GalHookTextWindowRect(
      left: value('left') ?? 0,
      top: value('top') ?? 0,
      width: value('width') ?? 0,
      height: value('height') ?? 0,
    );
    return rect.isValid ? rect : null;
  }
}

typedef GalHookTextLookupHandler = FutureOr<void> Function(
  String lineId,
  String text,
  int index,
  Rect? wordRect,
);
typedef GalHookTextEventHandler = FutureOr<void> Function();
typedef GalHookTextLockHandler = FutureOr<void> Function(bool locked);

/// 游戏内查词（KiriKiri in-game lookup）：注入进游戏的 hook 报上来的一次命中。
///
/// 坐标全部在**游戏 primaryLayer 像素**域（不是 Windows 屏幕逻辑/物理 px）——卡片
/// 位图是逐像素 memcpy 进游戏 Layer 的，所以定位只能在这个域里算，Dart 侧绝不乘 dpr。
/// [charIndex] / [charCount] 是 UTF-16 code unit 下标，与 [line] 的 Dart String 下标
/// 同坐标系（native 侧以 UTF-16 计数，见 voice_hook_ipc.h 的 LookupHitSlot）。
@immutable
class GalLookupHit {
  const GalLookupHit({
    required this.seq,
    required this.line,
    required this.charIndex,
    required this.charCount,
    required this.glyphX,
    required this.glyphY,
    required this.glyphW,
    required this.glyphH,
    required this.viewW,
    required this.viewH,
    required this.submit,
  });

  /// hook 侧单调递增的命中序号：host 据此判新、hook 据此丢弃过期帧。
  final int seq;

  /// **整行**台词（不截断——制卡要整句）。
  final String line;

  /// 光标落在第几个字符（UTF-16 下标）。
  final int charIndex;

  /// hook 自报的本行字符数，只用于自洽校验（与 [line] 长度不符即判脏数据）。
  final int charCount;

  final int glyphX;
  final int glyphY;
  final int glyphW;
  final int glyphH;

  /// primaryLayer 尺寸：卡片定位/钳制的「屏幕」。
  final int viewW;
  final int viewH;

  /// true = 真查词（点击 / hook 侧判定的悬停即查词）；false = 纯悬停，只更新高亮。
  final bool submit;

  /// 命中字形矩形（primaryLayer px）。
  Rect get glyphRect => Rect.fromLTWH(
        glyphX.toDouble(),
        glyphY.toDouble(),
        glyphW.toDouble(),
        glyphH.toDouble(),
      );

  /// [charIndex] 是否真的指得到 [line] 里的一个字。**硬门**：指不到就丢弃，不去猜
  /// ——猜出来的下标会让高亮与查词落在完全无关的字上。
  bool get isAddressable =>
      line.isNotEmpty && charIndex >= 0 && charIndex < line.length;

  /// hook 自报的字符数与 UTF-16 长度是否一致。**软门**（只记账不丢弃）：两侧计数单位
  /// 若哪天漂了（比如 hook 改按字素簇计），硬丢会让整个功能静默死掉且日志上什么都
  /// 看不到；[isAddressable] 已经挡住了真正危险的越界。
  bool get hasConsistentCharCount => charCount == line.length;

  static GalLookupHit? fromMap(Map<Object?, Object?> map) {
    int intOf(String key) => (map[key] as num?)?.toInt() ?? 0;
    final String line = map['line']?.toString() ?? '';
    if (line.isEmpty) return null;
    return GalLookupHit(
      seq: intOf('seq'),
      line: line,
      charIndex: intOf('charIndex'),
      charCount: intOf('charCount'),
      glyphX: intOf('glyphX'),
      glyphY: intOf('glyphY'),
      glyphW: intOf('glyphW'),
      glyphH: intOf('glyphH'),
      viewW: intOf('viewW'),
      viewH: intOf('viewH'),
      submit: map['submit'] == true,
    );
  }
}

/// 游戏内查词：落在卡片矩形内、由 hook 转发过来的一次输入事件。
///
/// Dart **不解释语义**（不判断这是点了哪个词条、要不要翻页）——原样透传给 runner 的
/// popup 输入注入口，由已有的 WebView2 `SendMouseInput` 消费。坐标是**卡片本地** px
/// （hook 已减去 anchor）。
@immutable
class GalLookupInput {
  const GalLookupInput({
    required this.seq,
    required this.x,
    required this.y,
    required this.kind,
    required this.wheel,
    required this.keys,
  });

  final int seq;
  final int x;
  final int y;

  /// 0=move 1=leftDown 2=leftUp 3=wheel 4=leave。
  final int kind;
  final int wheel;
  final int keys;

  static GalLookupInput fromMap(Map<Object?, Object?> map) {
    int intOf(String key) => (map[key] as num?)?.toInt() ?? 0;
    return GalLookupInput(
      seq: intOf('seq'),
      x: intOf('x'),
      y: intOf('y'),
      kind: intOf('kind'),
      wheel: intOf('wheel'),
      keys: intOf('keys'),
    );
  }
}

typedef GalLookupHitHandler = FutureOr<void> Function(GalLookupHit hit);
typedef GalLookupInputHandler = FutureOr<void> Function(GalLookupInput input);

/// 游戏内查词 Dart→runner 调用的应答。
///
/// runner 从不抛异常，它把失败**编码成 `{error: <token>}`**（旧 helper 没有 v14 查词
/// 区、开关没开、取帧失败、卡片超预算…）。所以这些调用绝不能 fire-and-forget 成
/// 「看起来成功」——阶段证据门要求 ready / 捕获 / 投帧各算各的，吞掉 error token 等于
/// 拿前一阶段推断后一阶段。
@immutable
class GalLookupCallResult {
  const GalLookupCallResult({
    this.error,
    this.width = 0,
    this.height = 0,
    this.clamped = false,
  });

  /// 平台不支持（非 Windows）时的常量结果：不是失败，是「这条链在这个平台不存在」。
  static const GalLookupCallResult unsupported =
      GalLookupCallResult(error: 'unsupported_platform');

  /// runner 给的错误 token；null = 成功。
  final String? error;

  /// 实际写进共享内存的帧尺寸（仅 present 有值）。
  final int width;
  final int height;

  /// 卡片被裁过（源画面超维度上界，或字节超预算按行裁）——处置是「把卡片做小点」。
  final bool clamped;

  bool get ok => error == null;

  static GalLookupCallResult fromReply(Object? reply) {
    if (reply is! Map) return const GalLookupCallResult();
    final Map<Object?, Object?> map = reply.cast<Object?, Object?>();
    final Object? error = map['error'];
    return GalLookupCallResult(
      error: error is String && error.isNotEmpty ? error : null,
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      clamped: map['clamped'] == true,
    );
  }
}

/// native 侧穿透态被否决 / 变更时的回传（BUG-951）。native 建不出逃生工具条窗
/// 时会拒绝进入穿透并把自己摁回 false；Dart 必须跟着退回，否则它的标志卡在
/// true，用户下一次按 `↗` 会变成一次看不出反应的空点击。
typedef GalHookTextPassThroughHandler = FutureOr<void> Function(
  bool passThrough,
);
typedef GalHookTextBoundsHandler = FutureOr<void> Function(
  GalHookTextWindowRect rect,
);

/// Hook 台词浮窗的默认字号（逻辑 px）。
///
/// BUG-1095：以前 native 会在 hook 模式下按窗口高度对它做 0.9~2.5 倍缩放，于是
/// 「拖高浮窗」＝「放大台词」，可见行数几乎不涨，用户「放不下想拖高」永远无解。
/// 现在 native 直接用这个值（不再乘窗高比例），真值来自 `gal_hook_text_font_size`
/// 偏好；本常量只是它的默认值，等于旧公式在默认窗高（140dip）下的实际字号，
/// 所以没拖过窗的用户观感逐像素不变。
const double kGalHookTextFontSize = 30.0;

/// Windows Hook 台词浮窗的专用 MethodChannel 契约。
class GalHookTextOverlayChannel extends FloatingOverlayChannel {
  GalHookTextOverlayChannel._() : super(FushiChannels.galHookText);

  static final GalHookTextOverlayChannel _instance =
      GalHookTextOverlayChannel._();

  @visibleForTesting
  static bool? platformOverride;

  @override
  bool get isSupported => platformOverride ?? Platform.isWindows;

  static bool get supportsCurrentPlatform => _instance.isSupported;

  static GalHookTextLookupHandler? _onLookupText;
  static GalHookTextEventHandler? _onToggleFollow;
  static GalHookTextEventHandler? _onTogglePassThrough;
  static GalHookTextEventHandler? _onToggleTransparency;
  static GalHookTextEventHandler? _onOpenWorkbench;
  static GalHookTextEventHandler? _onClose;
  static GalHookTextEventHandler? _onReplayVoice;
  static GalHookTextEventHandler? _onRecaptureVoice;
  static GalHookTextLockHandler? _onLockChanged;
  static GalHookTextPassThroughHandler? _onPassThroughChanged;
  static GalHookTextBoundsHandler? _onBoundsChanged;
  static GalLookupHitHandler? _onGalLookupHit;
  static GalLookupInputHandler? _onGalLookupInput;

  static void setEventHandlers({
    GalHookTextLookupHandler? onLookupText,
    GalHookTextEventHandler? onToggleFollow,
    GalHookTextEventHandler? onTogglePassThrough,
    GalHookTextEventHandler? onToggleTransparency,
    GalHookTextEventHandler? onOpenWorkbench,
    GalHookTextEventHandler? onClose,
    GalHookTextEventHandler? onReplayVoice,
    GalHookTextEventHandler? onRecaptureVoice,
    GalHookTextLockHandler? onLockChanged,
    GalHookTextPassThroughHandler? onPassThroughChanged,
    GalHookTextBoundsHandler? onBoundsChanged,
    GalLookupHitHandler? onGalLookupHit,
    GalLookupInputHandler? onGalLookupInput,
  }) {
    _onLookupText = onLookupText;
    _onToggleFollow = onToggleFollow;
    _onTogglePassThrough = onTogglePassThrough;
    _onToggleTransparency = onToggleTransparency;
    _onOpenWorkbench = onOpenWorkbench;
    _onClose = onClose;
    _onReplayVoice = onReplayVoice;
    _onRecaptureVoice = onRecaptureVoice;
    _onLockChanged = onLockChanged;
    _onPassThroughChanged = onPassThroughChanged;
    _onBoundsChanged = onBoundsChanged;
    _onGalLookupHit = onGalLookupHit;
    _onGalLookupInput = onGalLookupInput;
    _instance.channel.setMethodCallHandler(_handleNativeCall);
  }

  static void clearEventHandlers() {
    _onLookupText = null;
    _onToggleFollow = null;
    _onTogglePassThrough = null;
    _onToggleTransparency = null;
    _onOpenWorkbench = null;
    _onClose = null;
    _onReplayVoice = null;
    _onRecaptureVoice = null;
    _onLockChanged = null;
    _onPassThroughChanged = null;
    _onBoundsChanged = null;
    _onGalLookupHit = null;
    _onGalLookupInput = null;
    _instance.channel.setMethodCallHandler(null);
  }

  static Future<void> _handleNativeCall(MethodCall call) async {
    final Object? arguments = call.arguments;
    final Map<Object?, Object?> args =
        arguments is Map ? arguments.cast<Object?, Object?>() : const {};
    switch (call.method) {
      case 'lookupText':
        final String lineId = args['lineId']?.toString() ?? '';
        final String text = args['text']?.toString() ?? '';
        final int index = (args['index'] as num?)?.toInt() ?? 0;
        if (lineId.isNotEmpty && text.trim().isNotEmpty) {
          await _onLookupText?.call(lineId, text, index, _wordRect(args));
        }
        break;
      case 'toggleFollow':
        await _onToggleFollow?.call();
        break;
      case 'togglePassThrough':
        await _onTogglePassThrough?.call();
        break;
      case 'toggleTransparency':
        await _onToggleTransparency?.call();
        break;
      case 'openWorkbench':
        await _onOpenWorkbench?.call();
        break;
      case 'replayVoice':
        await _onReplayVoice?.call();
        break;
      case 'recaptureVoice':
        await _onRecaptureVoice?.call();
        break;
      case 'close':
        await _onClose?.call();
        break;
      case 'lockChanged':
        await _onLockChanged?.call(args['locked'] == true);
        break;
      case 'passThroughChanged':
        await _onPassThroughChanged?.call(args['passThrough'] == true);
        break;
      case 'windowRectChanged':
        final GalHookTextWindowRect? rect = GalHookTextWindowRect.fromMap(args);
        if (rect != null) await _onBoundsChanged?.call(rect);
        break;
      // 游戏内查词：hook → runner → Dart。两条都在 latest-wins 语义下，处理器自己
      // 负责去抖/丢弃，channel 层只做解析与自洽校验。
      case 'onGalLookupHit':
        final GalLookupHit? hit = GalLookupHit.fromMap(args);
        if (hit != null && hit.isAddressable) {
          await _onGalLookupHit?.call(hit);
        }
        break;
      case 'onGalLookupInput':
        await _onGalLookupInput?.call(GalLookupInput.fromMap(args));
        break;
      default:
        break;
    }
  }

  /// native 回传的被点字矩形（屏幕逻辑 px）。老 native 不带这几项时返回 null，
  /// 调用方回落到原来的光标定位（Never break）。
  static Rect? _wordRect(Map<Object?, Object?> args) {
    final double? left = (args['wordLeft'] as num?)?.toDouble();
    final double? top = (args['wordTop'] as num?)?.toDouble();
    final double? width = (args['wordWidth'] as num?)?.toDouble();
    final double? height = (args['wordHeight'] as num?)?.toDouble();
    if (left == null || top == null || width == null || height == null) {
      return null;
    }
    if (width <= 0 || height <= 0) return null;
    return Rect.fromLTWH(left, top, width, height);
  }

  static Future<bool> show({
    GalHookTextWindowRect? rect,
    double fontSize = kGalHookTextFontSize,
    int textColor = 0xFFFFFFFF,
    int bgColor = 0xE0000000,
    bool following = true,
    bool passThrough = false,
    bool locked = false,
    bool hoverAutoLookup = false,
  }) {
    return _instance.showImpl(<String, Object?>{
      'fontSize': fontSize,
      'textColor': textColor,
      'bgColor': bgColor,
      'buttonTextColor': 0xFFFFFFFF,
      'buttonBgColor': 0x552D2340,
      'activeColor': 0xFFCE93D8,
      'windowWidth': 900.0,
      'windowHeight': 140.0,
      'clickLookupEnabled': true,
      // 置顶（📌 按钮）按会话复位为「开」，与 locked / passThrough / following 同
      // 规矩：上一局用户关掉置顶，不该让这一局的浮窗藏在全屏游戏后面。
      'topmost': true,
      // 「悬停即查词」：true 时浮窗上纯悬停即查词，false 时必须按住 Shift（Shift-悬停
      // 查词本身始终可用，不受此开关控制）。
      'hoverAutoLookup': hoverAutoLookup,
      'following': following,
      'passThrough': passThrough,
      'locked': locked,
      ...?rect?.toMap(),
    });
  }

  static Future<void> hide() => _instance.hideImpl();

  static Future<bool> isShowing() => _instance.isShowingImpl();

  /// [rubySpans] 是可选的注音区间（`{start, length, ruby}`，start/length 为 [text]
  /// 的 UTF-16 下标，与 native `HitTestPoint` 回传的 index 同坐标系）。不传或传空
  /// 时 native 完全走老渲染路径，逐像素与今天一致（never break userspace）。
  static Future<void> updateText({
    required String lineId,
    required String text,
    List<Map<String, Object?>>? rubySpans,
  }) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('updateText', <String, Object?>{
      'lineId': lineId,
      'text': text,
      if (rubySpans != null && rubySpans.isNotEmpty) 'rubySpans': rubySpans,
    });
  }

  static Future<void> updateStyle({
    required int bgColor,
    int textColor = 0xFFFFFFFF,
    double fontSize = kGalHookTextFontSize,
  }) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('updateStyle', <String, Object?>{
      'fontSize': fontSize,
      'bgColor': bgColor,
      'textColor': textColor,
      'buttonTextColor': 0xFFFFFFFF,
      'buttonBgColor': 0x552D2340,
      'activeColor': 0xFFCE93D8,
    });
  }

  static Future<void> setFollowing(bool following) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>(
      'setFollowing',
      <String, Object?>{'following': following},
    );
  }

  static Future<void> setPassThrough(bool enabled) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>(
      'setPassThrough',
      <String, Object?>{'enabled': enabled},
    );
  }

  /// 语音控件的可见状态（浮窗是独立窗口，用户只能在这里看到「正在试听 / 正在补录」）。
  static Future<void> setVoiceState({
    required bool replaying,
    required bool recapturing,
  }) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>(
      'setVoiceState',
      <String, Object?>{
        'replaying': replaying,
        'recapturing': recapturing,
      },
    );
  }

  /// 「悬停即查词」live 下发（设置项 `hover_auto_lookup`）：开着浮窗时改设置立刻生效，
  /// 不必等下一局游戏。关掉时浮窗退回「按住 Shift 悬停才查词」。
  static Future<void> setHoverAutoLookup(bool enabled) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>(
      'setHoverAutoLookup',
      <String, Object?>{'enabled': enabled},
    );
  }

  static Future<void> setLocked(bool locked) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>(
      'setLocked',
      <String, Object?>{'locked': locked},
    );
  }

  // ── 游戏内查词（Dart → runner）────────────────────────────────────────────
  // 三个方法都只搬运整数/布尔：**位图永远不经过 Dart**（离屏 WebView2 出帧 →
  // runner 取帧 → 共享内存 → hook memcpy 进游戏 Layer），Dart 只说「谁、放哪、
  // 高亮哪一段」。非 Windows 上全是空操作，不是崩。

  /// 总开关：runner 据此把 `lookup_enabled` 写进共享内存（hook 侧不开启就零写入），
  /// 并决定离屏 popup 是否进入「出帧给游戏」模式。
  static Future<GalLookupCallResult> galLookupSetEnabled(bool enabled) async {
    if (!_instance.isSupported) return GalLookupCallResult.unsupported;
    return GalLookupCallResult.fromReply(
      await _instance.channel.invokeMethod<Object?>(
        'galLookupSetEnabled',
        <String, Object?>{'enabled': enabled},
      ),
    );
  }

  /// 投帧：把「第 [seq] 次命中的卡片」放到 primaryLayer 的 ([anchorX], [anchorY])，
  /// 并把台词的 [highlightStart]..+[highlightLen]（UTF-16）标成命中高亮。
  ///
  /// 必须在 popup 内容**渲染完成**之后才调——早于内容就绪投帧会抓到上一帧或空白。
  /// 就绪信号见 [GlobalLookupController.onRevealed]（host 自测量上报的 union bbox）。
  static Future<GalLookupCallResult> galLookupPresent({
    required int seq,
    required int anchorX,
    required int anchorY,
    required int highlightStart,
    required int highlightLen,
  }) async {
    if (!_instance.isSupported) return GalLookupCallResult.unsupported;
    final Object? reply = await _instance.channel.invokeMethod<Object?>(
      'galLookupPresent',
      <String, Object?>{
        'seq': seq,
        'anchorX': anchorX,
        'anchorY': anchorY,
        'highlightStart': highlightStart,
        'highlightLen': highlightLen,
      },
    );
    return GalLookupCallResult.fromReply(reply);
  }

  /// 只挪高亮：**不重抓卡片画面**。
  ///
  /// 悬停换字时卡片内容一个像素都没变，而 [galLookupPresent] 每次都会走完整的
  /// 「CapturePreview → PNG 编解码 → 全卡 memcpy」——鼠标划过一行就是几十次，真机
  /// 表现为明显卡顿。高亮本来就画在游戏自己的图层上、不在卡片位图里，所以这条路
  /// 一个像素都不需要。
  static Future<GalLookupCallResult> galLookupPresentHighlight({
    required int seq,
    required int anchorX,
    required int anchorY,
    required int highlightStart,
    required int highlightLen,
  }) async {
    if (!_instance.isSupported) return GalLookupCallResult.unsupported;
    final Object? reply = await _instance.channel.invokeMethod<Object?>(
      'galLookupPresentHighlight',
      <String, Object?>{
        'seq': seq,
        'anchorX': anchorX,
        'anchorY': anchorY,
        'highlightStart': highlightStart,
        'highlightLen': highlightLen,
      },
    );
    return GalLookupCallResult.fromReply(reply);
  }

  /// 消场：换行 / 换页 / 会话结束 / 卡片被用户关掉。[seq] 是要撤掉的那次命中。
  static Future<GalLookupCallResult> galLookupDismiss(int seq) async {
    if (!_instance.isSupported) return GalLookupCallResult.unsupported;
    return GalLookupCallResult.fromReply(
      await _instance.channel.invokeMethod<Object?>(
        'galLookupDismiss',
        <String, Object?>{'seq': seq},
      ),
    );
  }

  /// 制卡截图屏障：发布一帧 capture-suppress，并等待 hook 在游戏主线程确认卡片和
  /// 字幕高亮都已经隐藏。成功回执之前调用方**不得**读取游戏窗口像素。
  ///
  /// 这不是普通 dismiss：离屏 popup、route 与 DOM 都保留，采样结束后由下一次普通
  /// [galLookupPresent] 解除 suppress 并把当时仍然最新的卡片重新投回游戏。
  static Future<GalLookupCallResult> galLookupSuspendForCapture(int seq) async {
    if (!_instance.isSupported) return GalLookupCallResult.unsupported;
    return GalLookupCallResult.fromReply(
      await _instance.channel.invokeMethod<Object?>(
        'galLookupSuspendForCapture',
        <String, Object?>{'seq': seq},
      ),
    );
  }

  /// 把 hook 转发过来的卡片内输入原样丢回 runner 的既有 popup 输入注入口
  /// （`global_lookup_window.cpp` 的 `SendMouseInput`）。Dart 不解释语义。
  ///
  /// runner 侧 `HandleLookupCall` 的第四个方法（`voice_hook_reader.cpp`）：注入是
  /// **Dart 驱动**的——泵只上报，不自己喂 WebView2，否则每个事件注入两次（点击变
  /// 双击、滚轮翻倍）。
  static Future<GalLookupCallResult> galLookupInput(
    GalLookupInput input,
  ) async {
    if (!_instance.isSupported) return GalLookupCallResult.unsupported;
    return GalLookupCallResult.fromReply(
      await _instance.channel.invokeMethod<Object?>(
        'galLookupInput',
        <String, Object?>{
          'seq': input.seq,
          'x': input.x,
          'y': input.y,
          'kind': input.kind,
          'wheel': input.wheel,
          'keys': input.keys,
        },
      ),
    );
  }
}
