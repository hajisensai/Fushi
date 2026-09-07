import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/platform/floating_overlay_channel.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

int? _finiteWireInt(Object? value) {
  if (value is! num || !value.isFinite) return null;
  final int integer = value.toInt();
  return value.toDouble() == integer.toDouble() ? integer : null;
}

int? _positiveWireInt(Object? value) {
  final int? parsed = _finiteWireInt(value);
  return parsed != null && parsed > 0 ? parsed : null;
}

/// 非负整数 wire 值；缺失、非数、负数一律归 0。
///
/// 用于「0 有确切含义（= 量不到）」的可选字段：把脏值折成 0 与把它折成 null 再
/// 作废整条消息是两种语义，这里要的是前者。
int _nonNegativeWireInt(Object? value) {
  final int? parsed = _finiteWireInt(value);
  return parsed != null && parsed > 0 ? parsed : 0;
}

bool _hasValidUtf16SourceSpan(String text, int start, int length) {
  if (text.isEmpty ||
      start < 0 ||
      length <= 0 ||
      start + length > text.length) {
    return false;
  }

  // MethodChannel payloads are untrusted. Dart strings can contain unpaired
  // UTF-16 surrogates, so a length-only check still permits a provider to
  // address half of a supplementary character. Validate the complete source
  // and require both ends of the cluster to be scalar boundaries, matching
  // the native v19 reader gate.
  for (int index = 0; index < text.length; index++) {
    final int unit = text.codeUnitAt(index);
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (index + 1 >= text.length) return false;
      final int next = text.codeUnitAt(index + 1);
      if (next < 0xDC00 || next > 0xDFFF) return false;
      index++;
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      return false;
    }
  }

  bool isBoundary(int index) =>
      index == text.length ||
      text.codeUnitAt(index) < 0xDC00 ||
      text.codeUnitAt(index) > 0xDFFF;
  return isBoundary(start) && isBoundary(start + length);
}

/// Mirrors `kLookupGeometryProductionProviderPairs` in the native v19
/// registry. A valid kind and a valid id are not sufficient independently.
bool isGalLookupProductionProviderPair(int kind, int id) {
  switch (kind) {
    case 1: // runtime_layout
      return id == 1 || id == 2 || id == 6 || id == 7 || id == 8;
    case 2: // engine_exact_layout
      return id == 3 || id == 4 || id == 5 || id == 14 || id == 15;
    case 3: // positioned_text_api
      return id == 9 || id == 10;
    default:
      return false;
  }
}

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
    int? value(String key) => _finiteWireInt(map[key]);
    final GalHookTextWindowRect rect = GalHookTextWindowRect(
      left: value('left') ?? 0,
      top: value('top') ?? 0,
      width: value('width') ?? 0,
      height: value('height') ?? 0,
    );
    return rect.isValid ? rect : null;
  }
}

typedef GalHookTextLookupHandler =
    FutureOr<void> Function(
      String lineId,
      String text,
      int index,
      Rect? wordRect,
    );
typedef GalHookTextEventHandler = FutureOr<void> Function();
typedef GalHookTextLockHandler = FutureOr<void> Function(bool locked);

/// 游戏内查词（KiriKiri in-game lookup）：注入进游戏的 hook 报上来的一次命中。
///
/// 坐标只接受两个已经闭合的像素域：client physical pixels（runner 的
/// RevealOverProcessClient 强制 view/client 1:1 后再 ClientToScreen）或游戏
/// primaryLayer pixels（in-process 位图 presenter）。Design/layout-local 在没有唯一
/// transform lineage 时 fail closed；Dart 侧不猜缩放也不乘 dpr。
/// [charIndex] / [charCount] 是 UTF-16 code unit 下标，与 [line] 的 Dart String 下标
/// 同坐标系（native 侧以 UTF-16 计数，见 voice_hook_ipc.h 的 LookupHitSlot）。
@immutable
class GalLookupHit {
  const GalLookupHit({
    required this.seq,
    required this.line,
    required this.providerKind,
    required this.providerId,
    required this.charIndex,
    required this.sourceLength,
    required this.charCount,
    required this.textGeneration,
    required this.geometryGeneration,
    required this.coordinateSpace,
    required this.writingMode,
    required this.glyphX,
    required this.glyphY,
    required this.glyphW,
    required this.glyphH,
    required this.viewW,
    required this.viewH,
    required this.submit,
    this.clientW = 0,
    this.clientH = 0,
  });

  /// hook 侧单调递增的命中序号：host 据此判新、hook 据此丢弃过期帧。
  final int seq;

  /// **整行**台词（不截断——制卡要整句）。
  final String line;

  final int providerKind;
  final int providerId;

  /// 光标落在第几个字符（UTF-16 下标）。
  final int charIndex;

  /// Length of the provider-owned source cluster, in UTF-16 code units.
  final int sourceLength;

  /// hook 自报的本行字符数，只用于自洽校验（与 [line] 长度不符即判脏数据）。
  final int charCount;

  final int textGeneration;
  final int geometryGeneration;
  final int coordinateSpace;
  final int writingMode;

  final int glyphX;
  final int glyphY;
  final int glyphW;
  final int glyphH;

  /// 与 [coordinateSpace] 同域的 view 尺寸：卡片定位/钳制的「屏幕」。
  final int viewW;
  final int viewH;

  /// 本次命中这一刻**游戏窗口客户区**的物理尺寸；`0` = runner 量不到。
  ///
  /// 与 [viewW]/[viewH] 的区别是**域**，不是精度：[coordinateSpace] == 1
  /// （ClientPhysicalPixels）时两者相等；KiriKiri（== 2，PrimaryLayer）放大运行
  /// 时 view 是引擎画布，可以远小于客户区（真机 1280x720 画布 / 1902x1069 客户区）。
  ///
  /// 卡片**尺寸**的上界只能按这一对算：卡片是屏幕空间的真实窗口，尺寸是屏幕物理
  /// 像素。拿画布像素去夹屏幕像素会把卡片系统性压小，用户把「最大高度」调多大都
  /// 不生效（BUG-2066）。**位置**则相反，仍在 view 域（见 [glyphRect]）。
  ///
  /// 随每条 hit 现量现报，所以没有会话级缓存，也就没有「本局第一次查词还不知道」
  /// 和「玩家中途全屏↔窗口化后读到旧值」这两个失效面。
  final int clientW;
  final int clientH;

  /// true = 真查词（点击 / hook 侧判定的悬停即查词）；false = 纯悬停，只更新高亮。
  final bool submit;

  /// 命中字形矩形（与 [coordinateSpace] / view 相同的物理像素域）。
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

  /// hook 自报的字符数与 UTF-16 长度是否一致。v19 production gate 会拒绝漂移，
  /// 避免把一个 provider 的源文本与另一代几何拼到一起。
  bool get hasConsistentCharCount => charCount == line.length;

  bool get isProductionSane {
    final bool productionProvider = isGalLookupProductionProviderPair(
      providerKind,
      providerId,
    );
    final bool validSourceRange = _hasValidUtf16SourceSpan(
      line,
      charIndex,
      sourceLength,
    );
    final bool validGeometry =
        glyphX >= 0 &&
        glyphY >= 0 &&
        glyphW > 0 &&
        glyphH > 0 &&
        viewW > 0 &&
        viewH > 0 &&
        glyphX + glyphW <= viewW &&
        glyphY + glyphH <= viewH;
    return seq > 0 &&
        line.isNotEmpty &&
        productionProvider &&
        validSourceRange &&
        charCount == line.length &&
        textGeneration > 0 &&
        geometryGeneration > 0 &&
        (coordinateSpace == 1 || coordinateSpace == 2) &&
        writingMode == 1 &&
        validGeometry;
  }

  static GalLookupHit? fromMap(Map<Object?, Object?> map) {
    int? intOf(String key) => _finiteWireInt(map[key]);

    final Object? rawLine = map['line'];
    if (rawLine is! String || rawLine.isEmpty || map['submit'] is! bool) {
      return null;
    }
    final List<int?> numbers = <int?>[
      intOf('seq'),
      intOf('providerKind'),
      intOf('providerId'),
      intOf('charIndex'),
      intOf('sourceLength'),
      intOf('charCount'),
      intOf('textGeneration'),
      intOf('geometryGeneration'),
      intOf('coordinateSpace'),
      intOf('writingMode'),
      intOf('glyphX'),
      intOf('glyphY'),
      intOf('glyphW'),
      intOf('glyphH'),
      intOf('viewW'),
      intOf('viewH'),
    ];
    if (numbers.any((int? value) => value == null)) return null;
    return GalLookupHit(
      seq: numbers[0]!,
      line: rawLine,
      providerKind: numbers[1]!,
      providerId: numbers[2]!,
      charIndex: numbers[3]!,
      sourceLength: numbers[4]!,
      charCount: numbers[5]!,
      textGeneration: numbers[6]!,
      geometryGeneration: numbers[7]!,
      coordinateSpace: numbers[8]!,
      writingMode: numbers[9]!,
      glyphX: numbers[10]!,
      glyphY: numbers[11]!,
      glyphW: numbers[12]!,
      glyphH: numbers[13]!,
      viewW: numbers[14]!,
      viewH: numbers[15]!,
      submit: map['submit']! as bool,
      // 缺失/脏值一律归 0 = 「量不到」，而不是让整条 hit 作废：客户区只影响卡片
      // 尺寸上界，拿不到时退回画布口径仍是一次可用的查词。
      clientW: _nonNegativeWireInt(map['clientW']),
      clientH: _nonNegativeWireInt(map['clientH']),
    );
  }
}

/// 游戏内查词：由 hook 转发过来的一次输入或弹框控制事件。
///
/// 普通卡内输入不由 Dart 解释（不判断点了哪个词条、要不要翻页），原样透传给 runner
/// 的 WebView2 `SendMouseInput`。唯一例外是 [dismissOutsideKind]：它代表注入侧已吞掉
/// 的卡外点击，由会话控制器直接关闭当前查词。普通输入坐标是**卡片本地** px。
@immutable
class GalLookupInput {
  /// 位图回退弹框外的点击已经在注入侧完整吞掉；Dart 收到后应结束当前查词，
  /// 不能再把它当 WebView2 鼠标输入转发。
  static const int dismissOutsideKind = 5;

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

  /// 0=move 1=leftDown 2=leftUp 3=wheel 4=leave 5=dismissOutside。
  final int kind;
  final int wheel;
  final int keys;

  static GalLookupInput fromMap(Map<Object?, Object?> map) {
    int intOf(String key) => _finiteWireInt(map[key]) ?? 0;
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

/// 游戏内查词**准入**：本局游戏到底能不能游戏内查词，不能的话卡在哪一步。
///
/// 与「投帧失败」（`GalLookupResult.error`）是两件事：那个回答「这一帧为什么没进去」，
/// 这个回答「这一局压根有没有资格」。协议真值是 `voice_hook_ipc.h` 的
/// `LookupAdmissionState`（v19），host 侧只做单值映射，**不做位或、不排优先级**——
/// 状态机同一时刻只有一个状态，能被表达出来的不可能状态就是 bug 的来源。
enum GalLookupAdmissionState {
  /// 还不知道：helper 还没起来、或 adapter 还没上报。
  ///
  /// 🔴 **绝不能**当成「不支持」：每局游戏启动的头几百毫秒都停在这里，混淆两者等于
  /// 每次启动都误报一次"本引擎不支持"的原因文案。
  unknown(0),

  /// 命中的引擎 adapter 压根没做查词传感器。等新版本，不是 bug。
  engineUnsupported(1),

  /// 引擎做了传感器，但当前游戏 exe 不在它的精确 SHA-256 白名单里
  /// （hash-pinned fail closed）。此时 [GalLookupAdmission.executableSha256] 有值，
  /// 必须显示给用户——那是他报版本的唯一凭据。
  identityRejected(2),

  /// 身份通过，传感器还没装上（还在等开关 / 主窗 / D3D 设备 / 字节签名等门）。
  identityAccepted(3),

  /// 传感器已装。不等于"卡片一定出得来"——几何有没有真采到是另一回事。
  sensorInstalled(4);

  const GalLookupAdmissionState(this.wireValue);

  /// 与 `voice_hook_ipc.h::LookupAdmissionState` 逐值对应的线上值。
  final int wireValue;

  /// 这个状态是否把本局的游戏内查词整个挡在门外（UI 据此换副标题说明原因、并把
  /// 「复制 exe 摘要」那一行显示出来；**开关本身不置灰**，理由见 settings_schema_game.dart）。
  ///
  /// 🔴 判据只有这一份，别在 UI 层各写一遍。尤其 [unknown] **不在其内**：每局游戏
  /// 启动的头几百毫秒都停在 unknown（helper 还没起来 / adapter 还没上报），把它算作
  /// "挡住"等于每次启动都误报一次"本引擎不支持"。[identityAccepted] 与
  /// [sensorInstalled] 同理——那是"能用/还在等其它门"，不是"没资格"。
  bool get blocksLookup =>
      this == engineUnsupported || this == identityRejected;

  /// 本构建不认识的值一律回落 [unknown]——绝不猜。新 helper 加了状态而旧 app 去
  /// 硬猜，猜错的方向恰好是"说它不支持"，那正是最伤的误报。
  static GalLookupAdmissionState fromWire(int value) {
    for (final GalLookupAdmissionState state in values) {
      if (state.wireValue == value) return state;
    }
    return unknown;
  }
}

/// 一份准入快照。值语义：内容相同即相等，免得 ValueNotifier 每拍都通知。
@immutable
class GalLookupAdmission {
  const GalLookupAdmission({
    required this.state,
    required this.executableSha256,
  });

  /// 会话开始前 / 会话结束后的复位值。
  static const GalLookupAdmission unknown = GalLookupAdmission(
    state: GalLookupAdmissionState.unknown,
    executableSha256: '',
  );

  final GalLookupAdmissionState state;

  /// 当前游戏主 exe 的小写十六进制 SHA-256；只有
  /// [GalLookupAdmissionState.identityRejected] 时保证有值，其余状态为空串。
  final String executableSha256;

  static GalLookupAdmission fromMap(Map<Object?, Object?> map) {
    return GalLookupAdmission(
      state: GalLookupAdmissionState.fromWire(
        (map['state'] as num?)?.toInt() ?? 0,
      ),
      executableSha256: map['executableSha256']?.toString() ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GalLookupAdmission &&
      other.state == state &&
      other.executableSha256 == executableSha256;

  @override
  int get hashCode => Object.hash(state, executableSha256);

  @override
  String toString() =>
      'GalLookupAdmission(${state.name}, sha=$executableSha256)';
}

typedef GalLookupHitHandler = FutureOr<void> Function(GalLookupHit hit);
typedef GalLookupInputHandler = FutureOr<void> Function(GalLookupInput input);
typedef GalLookupAdmissionHandler =
    FutureOr<void> Function(GalLookupAdmission admission);

/// v19 attached-surface identity. Every attached call and event carries both
/// epochs; callers can therefore discard delayed events after a game/window
/// switch without guessing from HWND reuse.
@immutable
class GalAttachedSurfaceTarget {
  const GalAttachedSurfaceTarget({
    required this.sessionEpoch,
    required this.surfaceEpoch,
    required this.targetPid,
    required this.targetHwnd,
  });

  final int sessionEpoch;
  final int surfaceEpoch;
  final int targetPid;
  final int targetHwnd;

  bool get isValid =>
      sessionEpoch > 0 && surfaceEpoch > 0 && targetPid > 0 && targetHwnd != 0;

  Map<String, Object?> toMap() => <String, Object?>{
    'sessionEpoch': sessionEpoch,
    'surfaceEpoch': surfaceEpoch,
    'targetPid': targetPid,
    'targetHwnd': targetHwnd,
  };

  bool matches(GalAttachedSurfaceTarget other) =>
      sessionEpoch == other.sessionEpoch &&
      surfaceEpoch == other.surfaceEpoch &&
      targetPid == other.targetPid &&
      targetHwnd == other.targetHwnd;

  static GalAttachedSurfaceTarget? fromMap(Map<Object?, Object?> map) {
    int intOf(String key) {
      final Object? value = map[key];
      if (value is num) return _finiteWireInt(value) ?? 0;
      if (value is String) {
        final String normalized = value.trim().toLowerCase();
        return int.tryParse(
              normalized.startsWith('0x')
                  ? normalized.substring(2)
                  : normalized,
              radix: normalized.startsWith('0x') ? 16 : 10,
            ) ??
            0;
      }
      return 0;
    }

    final GalAttachedSurfaceTarget target = GalAttachedSurfaceTarget(
      sessionEpoch: intOf('sessionEpoch'),
      surfaceEpoch: intOf('surfaceEpoch'),
      targetPid: intOf('targetPid'),
      targetHwnd: intOf('targetHwnd'),
    );
    return target.isValid ? target : null;
  }
}

@immutable
class GalAttachedCalibrationProbes {
  const GalAttachedCalibrationProbes({
    required this.startIndex,
    required this.middleIndex,
    required this.endIndex,
    required this.startConfirmed,
    required this.middleConfirmed,
    required this.endConfirmed,
  });

  final int startIndex;
  final int middleIndex;
  final int endIndex;
  final bool startConfirmed;
  final bool middleConfirmed;
  final bool endConfirmed;

  int get confirmationMask =>
      (startConfirmed ? 1 : 0) |
      (middleConfirmed ? 2 : 0) |
      (endConfirmed ? 4 : 0);

  bool hasValidIndicesForSourceLength(int sourceLength) =>
      startIndex >= 0 &&
      startIndex < middleIndex &&
      middleIndex < endIndex &&
      (sourceLength <= 0 || endIndex < sourceLength);

  bool isCommitReadyForSourceLength(int sourceLength) =>
      confirmationMask == 7 && hasValidIndicesForSourceLength(sourceLength);

  Map<String, Object?> toMap() => <String, Object?>{
    'probeStartIndex': startIndex,
    'probeMiddleIndex': middleIndex,
    'probeEndIndex': endIndex,
    'probeStartConfirmed': startConfirmed,
    'probeMiddleConfirmed': middleConfirmed,
    'probeEndConfirmed': endConfirmed,
  };
}

/// Input-shield conclusion published by the v19 helper.
///
/// The conclusion bits are mutually exclusive on the wire. Unknown is the
/// zero value, so older runners that omit the snapshot remain fail-open and
/// visibly unverified instead of being mistaken for a safe shield.
enum GalAttachedShieldConclusion {
  unknown,
  verified,
  partial,
  knownUncovered,
  faulted,
}

@immutable
class GalAttachedShieldStatus {
  const GalAttachedShieldStatus({
    this.available = false,
    this.requestSeq = 0,
    this.appliedSeq = 0,
    this.requiredMask = 0,
    this.readyMask = 0,
    this.observedMask = 0,
    this.faultMask = 0,
    this.statusFlags = 0,
  });

  static const int _verifiedFlag = 0x01;
  static const int _partialFlag = 0x02;
  static const int _knownUncoveredFlag = 0x04;
  static const int _faultedFlag = 0x08;
  static const int _riskAllowedFlag = 0x10;
  static const int _transactionActiveFlag = 0x20;

  final bool available;
  final int requestSeq;
  final int appliedSeq;
  final int requiredMask;
  final int readyMask;
  final int observedMask;
  final int faultMask;
  final int statusFlags;

  GalAttachedShieldConclusion get conclusion {
    if ((statusFlags & _faultedFlag) != 0) {
      return GalAttachedShieldConclusion.faulted;
    }
    if ((statusFlags & _knownUncoveredFlag) != 0) {
      return GalAttachedShieldConclusion.knownUncovered;
    }
    if ((statusFlags & _partialFlag) != 0) {
      return GalAttachedShieldConclusion.partial;
    }
    if ((statusFlags & _verifiedFlag) != 0) {
      return GalAttachedShieldConclusion.verified;
    }
    return GalAttachedShieldConclusion.unknown;
  }

  bool get riskAllowed => (statusFlags & _riskAllowedFlag) != 0;
  bool get transactionActive => (statusFlags & _transactionActiveFlag) != 0;

  static GalAttachedShieldStatus fromMap(Object? value) {
    if (value is! Map) return const GalAttachedShieldStatus();
    final Map<Object?, Object?> map = value.cast<Object?, Object?>();
    int intOf(String key) => _finiteWireInt(map[key]) ?? 0;
    return GalAttachedShieldStatus(
      available: map['available'] == true,
      requestSeq: intOf('requestSeq'),
      appliedSeq: intOf('appliedSeq'),
      requiredMask: intOf('requiredMask'),
      readyMask: intOf('readyMask'),
      observedMask: intOf('observedMask'),
      faultMask: intOf('faultMask'),
      statusFlags: intOf('statusFlags'),
    );
  }
}

/// v19 `lookupText` payload emitted by the attached DirectWrite hit layer.
/// Indices and lengths are UTF-16 code units, matching Dart String indexing.
@immutable
class GalAttachedLookupHitV19 {
  const GalAttachedLookupHitV19({
    required this.target,
    required this.sourceText,
    required this.textGeneration,
    required this.charIndex,
    required this.sourceLength,
    this.wordRect,
    this.hover = false,
  });

  static const String surface = 'attached';

  final GalAttachedSurfaceTarget target;
  final String sourceText;
  final int textGeneration;
  final int charIndex;
  final int sourceLength;
  final Rect? wordRect;

  /// True when the runner's Shift+hover timer emitted the hit instead of a
  /// completed shielded click. Both take the same lookup chain; the flag is
  /// diagnostic only. Missing on the wire (older runner) = click.
  final bool hover;

  bool get isAddressable =>
      sourceText.isNotEmpty &&
      textGeneration > 0 &&
      charIndex >= 0 &&
      charIndex < sourceText.length;

  /// [sourceLength] is the clicked DirectWrite cluster length, not the full
  /// sentence length. The complete cluster range must remain addressable.
  bool get hasConsistentSourceLength =>
      _hasValidUtf16SourceSpan(sourceText, charIndex, sourceLength);

  static GalAttachedLookupHitV19? fromMap(Map<Object?, Object?> map) {
    if (map['surface'] != surface) return null;
    final GalAttachedSurfaceTarget? target = GalAttachedSurfaceTarget.fromMap(
      map,
    );
    if (target == null) return null;
    final Object? source = map['sourceText'] ?? map['text'];
    if (source is! String) return null;
    final int? generation = _finiteWireInt(map['textGeneration']);
    final int? charIndex =
        _finiteWireInt(map['charIndex']) ?? _finiteWireInt(map['index']);
    final int? sourceLength = _finiteWireInt(map['sourceLength']);
    if (generation == null || charIndex == null || sourceLength == null) {
      return null;
    }
    final GalAttachedLookupHitV19 hit = GalAttachedLookupHitV19(
      target: target,
      sourceText: source,
      textGeneration: generation,
      charIndex: charIndex,
      sourceLength: sourceLength,
      wordRect: GalHookTextOverlayChannel._wordRect(map),
      hover: map['hover'] == true,
    );
    return hit.isAddressable && hit.hasConsistentSourceLength ? hit : null;
  }
}

@immutable
class GalAttachedSurfaceStateEvent {
  const GalAttachedSurfaceStateEvent({
    required this.target,
    required this.state,
    required this.status,
    this.reason,
    this.surfaceVisible = false,
    this.referenceClient,
    this.bodyRect,
    this.layout,
    this.shield = const GalAttachedShieldStatus(),
    this.providerKind,
    this.providerId,
    this.providerStatus,
    this.probeStartObservedIndex,
    this.probeMiddleObservedIndex,
    this.probeEndObservedIndex,
    this.calibrationProbeMask = 0,
  });

  final GalAttachedSurfaceTarget target;
  final String state;
  final String status;
  final String? reason;
  final bool surfaceVisible;
  final GalLookupReferenceClientV1? referenceClient;
  final GalLookupNormalizedRectV1? bodyRect;
  final GalLookupTextLayoutV1? layout;
  final GalAttachedShieldStatus shield;
  final int? providerKind;
  final int? providerId;
  final int? providerStatus;
  final int? probeStartObservedIndex;
  final int? probeMiddleObservedIndex;
  final int? probeEndObservedIndex;
  final int calibrationProbeMask;

  static GalAttachedSurfaceStateEvent? fromMap(Map<Object?, Object?> map) {
    final GalAttachedSurfaceTarget? target = GalAttachedSurfaceTarget.fromMap(
      map,
    );
    final Object? rawStatus = map['status'];
    final Object? rawState = map['state'];
    final Object? rawReason = map['reason'];
    if ((rawStatus != null && rawStatus is! String) ||
        (rawState != null && rawState is! String) ||
        (rawReason != null && rawReason is! String)) {
      return null;
    }
    final String status = (rawStatus as String?) ?? (rawState as String?) ?? '';
    if (target == null || status.isEmpty) return null;
    final String state = (rawState as String?) ?? '';
    final String reason = (rawReason as String?) ?? '';
    return GalAttachedSurfaceStateEvent(
      target: target,
      state: state,
      status: status,
      reason: reason.isEmpty ? null : reason,
      surfaceVisible: map['surfaceVisible'] == true,
      referenceClient: GalLookupReferenceClientV1.tryFromJson(
        map['referenceClient'],
      ),
      bodyRect: GalLookupNormalizedRectV1.tryFromJson(map['bodyRect']),
      layout: GalLookupTextLayoutV1.tryFromJson(map['layout']),
      shield: GalAttachedShieldStatus.fromMap(map['shield']),
      providerKind: _positiveWireInt(map['providerKind']),
      providerId: _positiveWireInt(map['providerId']),
      providerStatus: _finiteWireInt(map['providerStatus']),
      probeStartObservedIndex: _finiteWireInt(map['probeStartObservedIndex']),
      probeMiddleObservedIndex: _finiteWireInt(map['probeMiddleObservedIndex']),
      probeEndObservedIndex: _finiteWireInt(map['probeEndObservedIndex']),
      calibrationProbeMask: _finiteWireInt(map['calibrationProbeMask']) ?? 0,
    );
  }
}

@immutable
class GalAttachedCalibrationEvent {
  const GalAttachedCalibrationEvent({
    required this.target,
    required this.bodyRect,
    required this.referenceClient,
    this.layout,
    this.riskAccepted = false,
    this.calibrationProbeMask = 0,
  });

  final GalAttachedSurfaceTarget target;
  final GalLookupNormalizedRectV1 bodyRect;
  final GalLookupReferenceClientV1 referenceClient;
  final GalLookupTextLayoutV1? layout;
  final bool riskAccepted;
  final int calibrationProbeMask;

  static GalAttachedCalibrationEvent? fromMap(Map<Object?, Object?> map) {
    final GalAttachedSurfaceTarget? target = GalAttachedSurfaceTarget.fromMap(
      map,
    );
    final GalLookupNormalizedRectV1? rect =
        GalLookupNormalizedRectV1.tryFromJson(map['bodyRect']);
    final GalLookupReferenceClientV1? client =
        GalLookupReferenceClientV1.tryFromJson(map['referenceClient']);
    if (target == null || rect == null || client == null) return null;
    return GalAttachedCalibrationEvent(
      target: target,
      bodyRect: rect,
      referenceClient: client,
      layout: GalLookupTextLayoutV1.tryFromJson(map['layout']),
      riskAccepted: map['riskAccepted'] == true,
      calibrationProbeMask: _finiteWireInt(map['calibrationProbeMask']) ?? 0,
    );
  }
}

@immutable
class GalAttachedCalibrationCancelledEvent {
  const GalAttachedCalibrationCancelledEvent({
    required this.target,
    this.reason,
  });

  final GalAttachedSurfaceTarget target;
  final String? reason;

  static GalAttachedCalibrationCancelledEvent? fromMap(
    Map<Object?, Object?> map,
  ) {
    final GalAttachedSurfaceTarget? target = GalAttachedSurfaceTarget.fromMap(
      map,
    );
    final Object? rawReason = map['reason'];
    if (target == null || (rawReason != null && rawReason is! String)) {
      return null;
    }
    final String reason = (rawReason as String?) ?? '';
    return GalAttachedCalibrationCancelledEvent(
      target: target,
      reason: reason.isEmpty ? null : reason,
    );
  }
}

typedef GalAttachedLookupHandler =
    FutureOr<void> Function(GalAttachedLookupHitV19 hit);
typedef GalAttachedSurfaceStateHandler =
    FutureOr<void> Function(GalAttachedSurfaceStateEvent event);
typedef GalAttachedCalibrationHandler =
    FutureOr<void> Function(GalAttachedCalibrationEvent event);
typedef GalAttachedCalibrationCancelledHandler =
    FutureOr<void> Function(GalAttachedCalibrationCancelledEvent event);

@immutable
class GalAttachedCallResult {
  const GalAttachedCallResult({
    this.error,
    this.status,
    this.reason,
    this.exePath,
    this.exeSha256,
    this.surfaceVisible = false,
    this.bodyRect,
    this.referenceClient,
    this.layout,
    this.shield = const GalAttachedShieldStatus(),
    this.providerKind,
    this.providerId,
    this.providerStatus,
    this.probeStartObservedIndex,
    this.probeMiddleObservedIndex,
    this.probeEndObservedIndex,
    this.calibrationProbeMask = 0,
  });

  static const GalAttachedCallResult unsupported = GalAttachedCallResult(
    error: 'unsupported_platform',
  );

  final String? error;
  final String? status;
  final String? reason;
  final String? exePath;
  final String? exeSha256;
  final bool surfaceVisible;
  final GalLookupNormalizedRectV1? bodyRect;
  final GalLookupReferenceClientV1? referenceClient;
  final GalLookupTextLayoutV1? layout;
  final GalAttachedShieldStatus shield;
  final int? providerKind;
  final int? providerId;
  final int? providerStatus;
  final int? probeStartObservedIndex;
  final int? probeMiddleObservedIndex;
  final int? probeEndObservedIndex;
  final int calibrationProbeMask;

  bool get ok => error == null;

  static GalAttachedCallResult fromReply(Object? reply) {
    if (reply is! Map) {
      return const GalAttachedCallResult(error: 'malformed_reply');
    }
    final Map<Object?, Object?> map = reply.cast<Object?, Object?>();
    const List<String> stringKeys = <String>[
      'error',
      'status',
      'state',
      'reason',
      'exePath',
      'exeSha256',
    ];
    for (final String key in stringKeys) {
      final Object? value = map[key];
      if (value != null && value is! String) {
        return const GalAttachedCallResult(error: 'malformed_reply');
      }
    }
    String? nonEmpty(String key) {
      final String value = (map[key] as String?) ?? '';
      return value.isEmpty ? null : value;
    }

    if (nonEmpty('error') == null &&
        nonEmpty('status') == null &&
        nonEmpty('state') == null) {
      return const GalAttachedCallResult(error: 'malformed_reply');
    }

    return GalAttachedCallResult(
      error: nonEmpty('error'),
      status: nonEmpty('status') ?? nonEmpty('state'),
      reason: nonEmpty('reason'),
      exePath: nonEmpty('exePath'),
      exeSha256: nonEmpty('exeSha256'),
      surfaceVisible: map['surfaceVisible'] == true,
      bodyRect: GalLookupNormalizedRectV1.tryFromJson(map['bodyRect']),
      referenceClient: GalLookupReferenceClientV1.tryFromJson(
        map['referenceClient'],
      ),
      layout: GalLookupTextLayoutV1.tryFromJson(map['layout']),
      shield: GalAttachedShieldStatus.fromMap(map['shield']),
      providerKind: _positiveWireInt(map['providerKind']),
      providerId: _positiveWireInt(map['providerId']),
      providerStatus: _finiteWireInt(map['providerStatus']),
      probeStartObservedIndex: _finiteWireInt(map['probeStartObservedIndex']),
      probeMiddleObservedIndex: _finiteWireInt(map['probeMiddleObservedIndex']),
      probeEndObservedIndex: _finiteWireInt(map['probeEndObservedIndex']),
      calibrationProbeMask: _finiteWireInt(map['calibrationProbeMask']) ?? 0,
    );
  }
}

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
    this.explicitOk = false,
    this.width = 0,
    this.height = 0,
    this.clamped = false,
    this.directSurface = false,
    this.requestSeq = 0,
    this.appliedSeq = 0,
  });

  /// 平台不支持（非 Windows）时的常量结果：不是失败，是「这条链在这个平台不存在」。
  static const GalLookupCallResult unsupported = GalLookupCallResult(
    error: 'unsupported_platform',
  );

  /// runner 给的错误 token；null = 成功。
  final String? error;

  /// True only when the runner explicitly returned `{ok: true}`. [ok] stays
  /// backward-compatible for payload-bearing replies, while lifecycle gates
  /// use this bit (or an explicit sequence) so an empty/malformed reply cannot
  /// silently advance a provider handoff.
  final bool explicitOk;

  /// 实际写进共享内存的帧尺寸（仅 present 有值）。
  final int width;
  final int height;

  /// 卡片被裁过（源画面超维度上界，或字节超预算按行裁）——处置是「把卡片做小点」。
  final bool clamped;

  /// true = runner 已把 WebView2 composition surface 直接贴到游戏客户区；此后
  /// DOM/滚动由浏览器合成器原生刷新，不再需要 CapturePreview dirty 帧。
  final bool directSurface;

  /// Host→hook control generation and the last registry-acknowledged
  /// generation. Geometry admission may be accepted before an in-flight
  /// mouse tail lets the registry apply it, so these values need not match in
  /// the immediate MethodChannel reply.
  final int requestSeq;
  final int appliedSeq;

  bool get ok => error == null;

  static GalLookupCallResult fromReply(Object? reply) {
    if (reply is! Map) return const GalLookupCallResult();
    final Map<Object?, Object?> map = reply.cast<Object?, Object?>();
    final Object? error = map['error'];
    return GalLookupCallResult(
      error: error is String && error.isNotEmpty ? error : null,
      explicitOk: map['ok'] == true,
      width: _finiteWireInt(map['width']) ?? 0,
      height: _finiteWireInt(map['height']) ?? 0,
      clamped: map['clamped'] == true,
      directSurface: map['directSurface'] == true,
      requestSeq: _finiteWireInt(map['requestSeq']) ?? 0,
      appliedSeq: _finiteWireInt(map['appliedSeq']) ?? 0,
    );
  }
}

/// v20+ host→hook geometry ownership policy. This is intentionally separate
/// from the lookup runtime switch because attached lookup still depends on
/// the injected generic input shield.
enum GalLookupGeometryAdmissionMode {
  disabled,
  auto,
  nativeOnly,
  attachedOnly;

  int get wireValue => index;
}

/// native 侧穿透态被否决 / 变更时的回传（BUG-951）。native 建不出逃生工具条窗
/// 时会拒绝进入穿透并把自己摁回 false；Dart 必须跟着退回，否则它的标志卡在
/// true，用户下一次按 `↗` 会变成一次看不出反应的空点击。
typedef GalHookTextPassThroughHandler =
    FutureOr<void> Function(bool passThrough);
typedef GalHookTextBoundsHandler =
    FutureOr<void> Function(GalHookTextWindowRect rect);

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
  // native 的 HWND 生命周期终点（WM_NCDESTROY）。消费端的可见性镜像靠它被动
  // 复位，而不是每行台词打一次 isShowing() 往返去轮询同一件事。
  static GalHookTextEventHandler? _onOverlayDestroyed;
  static GalHookTextEventHandler? _onReplayVoice;
  static GalHookTextEventHandler? _onRecaptureVoice;
  static GalHookTextLockHandler? _onLockChanged;
  static GalHookTextPassThroughHandler? _onPassThroughChanged;
  static GalHookTextBoundsHandler? _onBoundsChanged;
  static GalLookupHitHandler? _onGalLookupHit;
  static GalLookupInputHandler? _onGalLookupInput;
  static GalAttachedLookupHandler? _onAttachedLookupText;
  static GalAttachedSurfaceStateHandler? _onAttachedSurfaceStateChanged;
  static GalAttachedCalibrationHandler? _onAttachedCalibrationCommitted;
  static GalAttachedCalibrationCancelledHandler?
  _onAttachedCalibrationCancelled;
  static GalLookupAdmissionHandler? _onGalLookupAdmission;

  static void setEventHandlers({
    GalHookTextLookupHandler? onLookupText,
    GalHookTextEventHandler? onToggleFollow,
    GalHookTextEventHandler? onTogglePassThrough,
    GalHookTextEventHandler? onToggleTransparency,
    GalHookTextEventHandler? onOpenWorkbench,
    GalHookTextEventHandler? onClose,
    GalHookTextEventHandler? onOverlayDestroyed,
    GalHookTextEventHandler? onReplayVoice,
    GalHookTextEventHandler? onRecaptureVoice,
    GalHookTextLockHandler? onLockChanged,
    GalHookTextPassThroughHandler? onPassThroughChanged,
    GalHookTextBoundsHandler? onBoundsChanged,
    GalLookupHitHandler? onGalLookupHit,
    GalLookupInputHandler? onGalLookupInput,
    GalAttachedLookupHandler? onAttachedLookupText,
    GalAttachedSurfaceStateHandler? onAttachedSurfaceStateChanged,
    GalAttachedCalibrationHandler? onAttachedCalibrationCommitted,
    GalAttachedCalibrationCancelledHandler? onAttachedCalibrationCancelled,
    GalLookupAdmissionHandler? onGalLookupAdmission,
  }) {
    _onLookupText = onLookupText;
    _onToggleFollow = onToggleFollow;
    _onTogglePassThrough = onTogglePassThrough;
    _onToggleTransparency = onToggleTransparency;
    _onOpenWorkbench = onOpenWorkbench;
    _onClose = onClose;
    _onOverlayDestroyed = onOverlayDestroyed;
    _onReplayVoice = onReplayVoice;
    _onRecaptureVoice = onRecaptureVoice;
    _onLockChanged = onLockChanged;
    _onPassThroughChanged = onPassThroughChanged;
    _onBoundsChanged = onBoundsChanged;
    _onGalLookupHit = onGalLookupHit;
    _onGalLookupInput = onGalLookupInput;
    _onAttachedLookupText = onAttachedLookupText;
    _onAttachedSurfaceStateChanged = onAttachedSurfaceStateChanged;
    _onAttachedCalibrationCommitted = onAttachedCalibrationCommitted;
    _onAttachedCalibrationCancelled = onAttachedCalibrationCancelled;
    _onGalLookupAdmission = onGalLookupAdmission;
    _instance.channel.setMethodCallHandler(_handleNativeCall);
  }

  static void clearEventHandlers() {
    _onLookupText = null;
    _onToggleFollow = null;
    _onTogglePassThrough = null;
    _onToggleTransparency = null;
    _onOpenWorkbench = null;
    _onClose = null;
    _onOverlayDestroyed = null;
    _onReplayVoice = null;
    _onRecaptureVoice = null;
    _onLockChanged = null;
    _onPassThroughChanged = null;
    _onBoundsChanged = null;
    _onGalLookupHit = null;
    _onGalLookupInput = null;
    _onAttachedLookupText = null;
    _onAttachedSurfaceStateChanged = null;
    _onAttachedCalibrationCommitted = null;
    _onAttachedCalibrationCancelled = null;
    _onGalLookupAdmission = null;
    _instance.channel.setMethodCallHandler(null);
  }

  static Future<void> _handleNativeCall(MethodCall call) async {
    final Object? arguments = call.arguments;
    final Map<Object?, Object?> args = arguments is Map
        ? arguments.cast<Object?, Object?>()
        : const {};
    switch (call.method) {
      case 'lookupText':
        if (args['surface'] == GalAttachedLookupHitV19.surface) {
          final GalAttachedLookupHitV19? hit = GalAttachedLookupHitV19.fromMap(
            args,
          );
          if (hit != null) await _onAttachedLookupText?.call(hit);
          break;
        }
        final String lineId = args['lineId']?.toString() ?? '';
        final String text = args['text']?.toString() ?? '';
        final int index = _finiteWireInt(args['index']) ?? 0;
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
      // 用户按关闭 ('close') 与窗口句柄消失 ('overlayDestroyed') 是两件事：
      // 前者表达意图（本会话别再自动弹），后者只是陈述事实（窗口没了，镜像该
      // 复位）。合成一条就会让「窗口被外部销毁」被当成用户不想要它。
      case 'overlayDestroyed':
        await _onOverlayDestroyed?.call();
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
        if (hit != null && hit.isProductionSane) {
          await _onGalLookupHit?.call(hit);
        }
        break;
      case 'onGalLookupInput':
        await _onGalLookupInput?.call(GalLookupInput.fromMap(args));
        break;
      case 'attachedSurfaceStateChanged':
        final GalAttachedSurfaceStateEvent? event =
            GalAttachedSurfaceStateEvent.fromMap(args);
        if (event != null) await _onAttachedSurfaceStateChanged?.call(event);
        break;
      case 'attachedCalibrationCommitted':
        final GalAttachedCalibrationEvent? event =
            GalAttachedCalibrationEvent.fromMap(args);
        if (event != null) await _onAttachedCalibrationCommitted?.call(event);
        break;
      case 'attachedCalibrationCancelled':
        final GalAttachedCalibrationCancelledEvent? event =
            GalAttachedCalibrationCancelledEvent.fromMap(args);
        if (event != null) await _onAttachedCalibrationCancelled?.call(event);
      // 准入快照：runner 只在 lookup_admission_seq 变过时推，且与查词开关正交
      // （开关关着照样推）。不做任何过滤——"还不知道"也是必须送达的状态。
      case 'onGalLookupAdmission':
        await _onGalLookupAdmission?.call(GalLookupAdmission.fromMap(args));
        break;
      default:
        break;
    }
  }

  /// native 回传的被点字矩形（屏幕逻辑 px）。老 native 不带这几项时返回 null，
  /// 调用方回落到原来的光标定位（Never break）。
  static Rect? _wordRect(Map<Object?, Object?> args) {
    double? number(String key) {
      final Object? value = args[key];
      return value is num && value.isFinite ? value.toDouble() : null;
    }

    final double? left = number('wordLeft');
    final double? top = number('wordTop');
    final double? width = number('wordWidth');
    final double? height = number('wordHeight');
    if (left == null || top == null || width == null || height == null) {
      return null;
    }
    if (width <= 0 || height <= 0) return null;
    return Rect.fromLTWH(left, top, width, height);
  }

  static Future<bool> show({
    GalHookTextWindowRect? rect,
    double fontSize = kGalHookTextFontSize,
    String fontFamily = '',
    String? fontPath,
    double letterSpacing = 0,
    double lineHeight = 1,
    bool bold = true,
    String textAlignment = 'center',
    String verticalAlignment = 'center',
    int textColor = 0xFFFFFFFF,
    int bgColor = 0xE0000000,
    int outlineColor = 0xE0000000,
    double outlineWidth = 1.6,
    double textPadding = 20,
    double cornerRadius = 14,
    bool following = true,
    bool passThrough = false,
    bool locked = false,
    bool hoverAutoLookup = false,
    bool clickLookupEnabled = true,
    int lookupTrigger = 0,
    bool toolbarAutoHide = true,
    bool passThroughBlocksMouse = true,
    List<String>? slotTooltips,
  }) {
    return _instance.showImpl(<String, Object?>{
      'fontSize': fontSize,
      'fontFamily': fontFamily,
      // 工具条 9 槽悬停提示，下标与 native hook_toolbar::kSlotActions 严格对齐。
      // 不传 = native 侧无提示（老 payload 行为），工具条本身照常可点。
      if (slotTooltips != null && slotTooltips.isNotEmpty)
        'slotTooltips': slotTooltips,
      if (fontPath != null) 'fontPath': fontPath,
      'letterSpacing': letterSpacing,
      'lineHeight': lineHeight,
      'bold': bold,
      'textAlignment': textAlignment == 'left' ? 1 : 0,
      // BUG-1890：0 = 垂直居中（老行为），1 = 顶部对齐。与 textAlignment 同样
      // String→int 编码，native 侧 style.vertical_alignment 消费。
      'verticalAlignment': verticalAlignment == 'top' ? 1 : 0,
      'textColor': textColor,
      'bgColor': bgColor,
      'outlineColor': outlineColor,
      'outlineWidth': outlineWidth,
      'textPadding': textPadding,
      'buttonTextColor': 0xFFFFFFFF,
      'buttonBgColor': 0x552D2340,
      'activeColor': 0xFFCE93D8,
      'windowWidth': 900.0,
      'windowHeight': 140.0,
      'cornerRadius': cornerRadius,
      // 单击查词：native 侧一直支持，Dart 侧此前**写死 true**，于是设置里根本没有
      // 这个开关。用户「至少开启穿透的时候我不是很想单击点到单词，还是习惯用侧键
      // 查」——现在由偏好决定。
      'clickLookupEnabled': clickLookupEnabled,
      // 查词触发方式：0 = 左键单击 / 1 = 中键 / 2 = 侧键。与 clickLookupEnabled
      // 正交（可以既关单击、又用侧键查）。
      'lookupTrigger': lookupTrigger,
      // 工具条自动隐藏（LunaHook 式）：平时整条隐藏，鼠标进入台词框才现身。
      'toolbarAutoHide': toolbarAutoHide,
      // 穿透时正文是否仍拦截落在文字行盒上的鼠标。false = 连字也不接，整窗对游戏
      // 彻底透明。
      'passThroughBlocksMouse': passThroughBlocksMouse,
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
    String fontFamily = '',
    String? fontPath,
    double letterSpacing = 0,
    double lineHeight = 1,
    bool bold = true,
    String textAlignment = 'center',
    String verticalAlignment = 'center',
    int outlineColor = 0xE0000000,
    double outlineWidth = 1.6,
    double textPadding = 20,
    double cornerRadius = 14,
  }) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('updateStyle', <String, Object?>{
      'fontSize': fontSize,
      'fontFamily': fontFamily,
      if (fontPath != null) 'fontPath': fontPath,
      'letterSpacing': letterSpacing,
      'lineHeight': lineHeight,
      'bold': bold,
      'textAlignment': textAlignment == 'left' ? 1 : 0,
      'verticalAlignment': verticalAlignment == 'top' ? 1 : 0,
      'bgColor': bgColor,
      'textColor': textColor,
      'outlineColor': outlineColor,
      'outlineWidth': outlineWidth,
      'textPadding': textPadding,
      'cornerRadius': cornerRadius,
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
      <String, Object?>{'replaying': replaying, 'recapturing': recapturing},
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

  /// 查词触发方式 live 下发（0 = 左键 / 1 = 中键 / 2 = 侧键）。
  static Future<void> setLookupTrigger(int trigger) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>(
      'setLookupTrigger',
      <String, Object?>{'trigger': trigger},
    );
  }

  /// 单击查词开关 live 下发。native 侧的 `setClickLookupEnabled` 一直都在，缺的是
  /// Dart 这一层包装（此前 show 载荷里写死 true）。
  static Future<void> setClickLookupEnabled(bool enabled) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>(
      'setClickLookupEnabled',
      <String, Object?>{'enabled': enabled},
    );
  }

  /// 工具条自动隐藏 live 下发。
  static Future<void> setToolbarAutoHide(bool enabled) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>(
      'setToolbarAutoHide',
      <String, Object?>{'enabled': enabled},
    );
  }

  /// 穿透时是否拦截鼠标 live 下发。
  static Future<void> setPassThroughBlocksMouse(bool enabled) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>(
      'setPassThroughBlocksMouse',
      <String, Object?>{'enabled': enabled},
    );
  }

  static Future<void> setLocked(bool locked) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('setLocked', <String, Object?>{
      'locked': locked,
    });
  }

  // ── v19 attached DirectWrite lookup surface (Dart → runner) ──────────────

  static Future<GalAttachedCallResult> _invokeAttached(
    String method,
    GalAttachedSurfaceTarget target, [
    Map<String, Object?> arguments = const <String, Object?>{},
  ]) async {
    if (!_instance.isSupported) return GalAttachedCallResult.unsupported;
    if (!target.isValid) {
      return const GalAttachedCallResult(error: 'invalid_target');
    }
    try {
      final Object? reply = await _instance.channel.invokeMethod<Object?>(
        method,
        <String, Object?>{...target.toMap(), ...arguments},
      );
      return GalAttachedCallResult.fromReply(reply);
    } on PlatformException catch (error) {
      return GalAttachedCallResult(
        error: error.code.isEmpty ? 'platform_error' : error.code,
        reason: error.message,
      );
    } on MissingPluginException {
      return const GalAttachedCallResult(error: 'attached_surface_unavailable');
    }
  }

  static Future<GalAttachedCallResult> attachedInspectTarget(
    GalAttachedSurfaceTarget target, {
    String? launchExePath,
  }) => _invokeAttached('attachedInspectTarget', target, <String, Object?>{
    if (launchExePath != null && launchExePath.trim().isNotEmpty)
      'launchExePath': launchExePath.trim(),
  });

  static Future<GalAttachedCallResult> attachedCalibrationStart({
    required GalAttachedSurfaceTarget target,
    required GalLookupNormalizedRectV1 bodyRect,
    required GalLookupReferenceClientV1 referenceClient,
    required GalLookupTextLayoutV1 layout,
    required bool riskAccepted,
  }) => _invokeAttached('attachedCalibrationStart', target, <String, Object?>{
    'bodyRect': bodyRect.toJson(),
    'referenceClient': referenceClient.toJson(),
    'layout': layout.toJson(),
    'inputMode': GalLookupSurfaceProfileV1.inputMode,
    'riskAccepted': riskAccepted,
  });

  static Future<GalAttachedCallResult> attachedCalibrationUpdate({
    required GalAttachedSurfaceTarget target,
    required GalLookupNormalizedRectV1 bodyRect,
    required GalAttachedCalibrationProbes probes,
  }) => _invokeAttached('attachedCalibrationUpdate', target, <String, Object?>{
    'bodyRect': bodyRect.toJson(),
    ...probes.toMap(),
  });

  static Future<GalAttachedCallResult> attachedCalibrationCommit({
    required GalAttachedSurfaceTarget target,
    required GalLookupNormalizedRectV1 bodyRect,
    required GalAttachedCalibrationProbes probes,
  }) => _invokeAttached('attachedCalibrationCommit', target, <String, Object?>{
    'bodyRect': bodyRect.toJson(),
    ...probes.toMap(),
  });

  static Future<GalAttachedCallResult> attachedCalibrationCancel(
    GalAttachedSurfaceTarget target,
  ) => _invokeAttached('attachedCalibrationCancel', target);

  static Future<GalAttachedCallResult> attachedConfigure({
    required GalAttachedSurfaceTarget target,
    required GalLookupSurfaceVariantV1 variant,
    required GalLookupSurfaceMode mode,
    required bool riskAccepted,
  }) => _invokeAttached('attachedConfigure', target, <String, Object?>{
    'bodyRect': variant.bodyRect.toJson(),
    'referenceClient': variant.referenceClient.toJson(),
    'layout': variant.layout.toJson(),
    'mode': mode.wireName,
    'inputMode': GalLookupSurfaceProfileV1.inputMode,
    'riskAccepted': riskAccepted,
  });

  static Future<GalAttachedCallResult> attachedUpdateText({
    required GalAttachedSurfaceTarget target,
    required String sourceText,
    required int textGeneration,
    String writingMode = GalLookupSurfaceProfileV1.writingMode,
  }) {
    if (writingMode != GalLookupSurfaceProfileV1.writingMode) {
      return Future<GalAttachedCallResult>.value(
        const GalAttachedCallResult(error: 'unsupported_writing_mode'),
      );
    }
    return _invokeAttached('attachedUpdateText', target, <String, Object?>{
      'sourceText': sourceText,
      'textGeneration': textGeneration,
      'writingMode': writingMode,
    });
  }

  static Future<GalAttachedCallResult> attachedUpdateStyle({
    required GalAttachedSurfaceTarget target,
    required GalLookupTextLayoutV1 layout,
  }) => _invokeAttached('attachedUpdateStyle', target, <String, Object?>{
    'layout': layout.toJson(),
  });

  static Future<GalAttachedCallResult> attachedSuspendForCapture({
    required GalAttachedSurfaceTarget target,
    required int textGeneration,
    required int captureGeneration,
  }) => _invokeAttached('attachedSuspendForCapture', target, <String, Object?>{
    'textGeneration': textGeneration,
    'captureGeneration': captureGeneration,
  });

  static Future<GalAttachedCallResult> attachedRestoreAfterCapture({
    required GalAttachedSurfaceTarget target,
    required int textGeneration,
    required int captureGeneration,
  }) =>
      _invokeAttached('attachedRestoreAfterCapture', target, <String, Object?>{
        'textGeneration': textGeneration,
        'captureGeneration': captureGeneration,
      });

  static Future<GalAttachedCallResult> attachedDetach(
    GalAttachedSurfaceTarget target,
  ) => _invokeAttached('attachedDetach', target);

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

  /// Updates the injected GeometryProviderRegistry admission without stopping
  /// the lookup runtime or generic shield. [attachedReady] is the host-owned
  /// calibrated fallback offer. [nativeInputAllowed] is a separate, risk-gated
  /// permission for the active native owner to consume a game click; it does
  /// not control provider discovery.
  ///
  /// 这是发布 admission 字的**唯一**通道。曾经并存的
  /// `galLookupSetNativeInputAllowed` 已删除：同一个 flags 字有两个发布入口就有
  /// 两份台账，谁后写谁赢。允许位现在由 GalIngameLookupController 单独拥有，
  /// 随 mode/attachedReady 一起在这里发布。
  static Future<GalLookupCallResult> galLookupSetGeometryAdmission({
    required GalLookupGeometryAdmissionMode mode,
    required bool attachedReady,
    required bool nativeInputAllowed,
  }) async {
    if (!_instance.isSupported) return GalLookupCallResult.unsupported;
    return GalLookupCallResult.fromReply(
      await _instance.channel.invokeMethod<Object?>(
        'galLookupSetGeometryAdmission',
        <String, Object?>{
          'mode': mode.wireValue,
          'attachedReady': attachedReady,
          'nativeInputAllowed': nativeInputAllowed,
        },
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
    required int cardWidth,
    required int cardHeight,
    required int viewWidth,
    required int viewHeight,
    required int glyphX,
    required int glyphY,
    required int glyphW,
    required int glyphH,
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
        'cardWidth': cardWidth,
        'cardHeight': cardHeight,
        'viewWidth': viewWidth,
        'viewHeight': viewHeight,
        // 直连覆盖窗按字形在屏幕上的矩形重排卡片：卡片保持自身物理像素、不随画布
        // 缩放，anchor 是按画布尺寸排出来的，放大运行时不能直接当屏幕位置用。
        'glyphX': glyphX,
        'glyphY': glyphY,
        'glyphW': glyphW,
        'glyphH': glyphH,
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
    final Object? reply = await _instance.channel
        .invokeMethod<Object?>('galLookupPresentHighlight', <String, Object?>{
          'seq': seq,
          'anchorX': anchorX,
          'anchorY': anchorY,
          'highlightStart': highlightStart,
          'highlightLen': highlightLen,
        });
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
      await _instance.channel
          .invokeMethod<Object?>('galLookupInput', <String, Object?>{
            'seq': input.seq,
            'x': input.x,
            'y': input.y,
            'kind': input.kind,
            'wheel': input.wheel,
            'keys': input.keys,
          }),
    );
  }
}
