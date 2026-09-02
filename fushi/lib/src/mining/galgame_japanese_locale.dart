/// 每游戏「日语区域（转区）」档位（BUG-1477）。
///
/// 为什么是**每游戏**而不是全局开关：同一个库里日文原版和汉化版并存，全局开关两边
/// 都不对。这不是偏好，是本仓已经为同形问题定过案的结论——[[BUG-1191]] 把窗口超分
/// 从全局偏好改成每游戏一列，理由写在 `preferences_repository.dart`：
/// 「该不该开完全取决于**这个游戏**，全局值无法映射成『每个游戏各自开不开』」。
///
/// 存储与 `galgames.upscaling_mode` 同型：TEXT 列，空串 = 未设置 = [auto]。
library;

import 'dart:ffi';
import 'dart:io';

/// 宿主机的 ANSI 代码页（`GetACP()`）；非 Windows 或取不到返回 null。
///
/// 用纯 Dart FFI 直接问 kernel32，不新开 MethodChannel——`galgame_play_tracker.dart`
/// 里已经是同一套做法（`DynamicLibrary.open('kernel32.dll')`）。
///
/// 为什么需要它：系统 ACP 已经是 932 说明用户机器本就日文区，此时再套一层
/// Locale Emulator 纯属有害无益（多一层 loader、多一个失败面），却什么都不解决。
int? readSystemAnsiCodePage() {
  if (!Platform.isWindows) return null;
  try {
    final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
    final int Function() getAcp =
        kernel32.lookupFunction<Uint32 Function(), int Function()>('GetACP');
    final int acp = getAcp();
    return acp > 0 ? acp : null;
  } catch (_) {
    return null;
  }
}

enum GalJapaneseLocaleMode {
  /// 自动判定（默认）。判据见 [resolveJapaneseLocale]。
  auto,

  /// 始终转区（launch 模式下）。不看位数——将来 Locale Emulator 有 x64 版时自然生效。
  on,

  /// 永不转区。**汉化版选这个**：它们恰好是 32 位（老引擎），但字符串已是
  /// GBK/UTF-8，套 CP932 会让游戏 `MultiByteToWideChar(CP_ACP, ...)` 解出非法序列，
  /// 字体/字表索引越界直接闪退。
  off,
}

const GalJapaneseLocaleMode kGalDefaultJapaneseLocaleMode =
    GalJapaneseLocaleMode.auto;

/// 持久化 key ⇄ 枚举。**不用 `enum.name` / `enum.index`**：那会让重命名或调整顺序
/// 悄悄改变已落库的值（与 `magpie_upscaling.dart` 同纪律）。
String galJapaneseLocaleModeToKey(GalJapaneseLocaleMode mode) {
  switch (mode) {
    case GalJapaneseLocaleMode.auto:
      return 'auto';
    case GalJapaneseLocaleMode.on:
      return 'on';
    case GalJapaneseLocaleMode.off:
      return 'off';
  }
}

/// 空串 / 未知值一律回落 [kGalDefaultJapaneseLocaleMode]——老数据行是空串，
/// 必须映射成「和以前一样自动」，而不是莫名关掉一个用户一直在用的功能。
GalJapaneseLocaleMode galJapaneseLocaleModeFromKey(String? key) {
  switch (key) {
    case 'on':
      return GalJapaneseLocaleMode.on;
    case 'off':
      return GalJapaneseLocaleMode.off;
    case 'auto':
      return GalJapaneseLocaleMode.auto;
    default:
      return kGalDefaultJapaneseLocaleMode;
  }
}

/// 「这个游戏需不需要 CP932 环境」的三态结论（BUG-2047）。
///
/// 这才是 `auto` 该回答的**语义**问题；系统 ACP 与目标位数只是随后的工程门。
enum GalJapaneseLocaleNeed {
  /// 有证据说明文本是 Shift-JIS / 引擎按 CP932 解字符串。
  needed,

  /// 有证据说明文本不是 Shift-JIS（汉化 / 多语言 / Unicode 引擎）。转了会闪退或乱码。
  notNeeded,

  /// 一条证据都没有。`auto` 下**不转区**：这是「自动判断是否需要」的字面含义，
  /// 也是「而非全转区」的要求；证据空白的日文原版会先乱码，用户看到会话卡上的
  /// 「未转区 · 证据不足」后改 [GalJapaneseLocaleMode.on]。
  unknown,
}

/// 判定所依据的证据源。探测器（`galgame_japanese_locale_probe.dart`）负责产出，
/// [judgeJapaneseLocaleNeed] 负责裁决，UI 直接把触发了的证据列给用户看。
enum GalJapaneseLocaleEvidence {
  /// `GalgameEntry.language` 主子标签是 `ja`。唯一的人工真值，压过一切自动证据。
  userLanguageJapanese,

  /// 用户声明了非日语内容语言。
  userLanguageOther,

  /// exe manifest 里 `<activeCodePage>UTF-8</activeCodePage>`：进程 ACP 已被钉成
  /// UTF-8，Locale Emulator 的 CP932 对它没有意义。
  manifestUtf8CodePage,

  /// RT_VERSION 语言目录 / `VarFileInfo\Translation` = 0x0411（日语）。
  versionInfoJapanese,

  /// RT_VERSION 语言 = 0x0804 / 0x0404 / 0x0C04 / 0x1004（中文各变体）。
  versionInfoChinese,

  /// exe 非代码段的 NUL 终止串段里，「假名对 ≥ 2 且无 GB2312 对」的串段 ≥ 3 条。
  /// **只做正向**：二进制里的「GB2312 区字节对」是噪声（纯英文 charmap.exe 也有 86 条）。
  exeShiftJisStrings,

  /// 游戏目录顶层文件名含假名（U+3040–U+30FF）。
  dirFileNameJapanese,

  /// 游戏目录顶层文件名命中 `汉化|中文|简体|繁体|繁體|CHS|CHT|chinese|hanhua`。
  /// 汉化补丁常常只改脚本包不改 exe，所以负向证据主要靠目录而不是 exe。
  dirFileNameChinesePatch,

  /// 顶层无 BOM 文本文件：假名对 ≥ 20 且 GB2312 对 ≈ 0（Shift-JIS 编码的 readme）。
  dirTextShiftJis,

  /// 顶层无 BOM 文本文件：GB2312 对 ≥ 20 且假名对 ≈ 0（GBK 编码的汉化说明）。
  dirTextGbk,

  /// 顶层 UTF-8 / UTF-16 文本含 ≥ 5 个简体专用汉字且无假名。
  dirTextSimplifiedHanzi,
}

/// 负向证据：任一命中 ⇒ [GalJapaneseLocaleNeed.notNeeded]，压过所有正向证据。
///
/// 理由是代价不对称：转错 = 启动即闪退（BUG-1477），不转 = 乱码（改 `on` 即可恢复）。
bool galJapaneseLocaleEvidenceIsNegative(GalJapaneseLocaleEvidence evidence) {
  switch (evidence) {
    case GalJapaneseLocaleEvidence.manifestUtf8CodePage:
    case GalJapaneseLocaleEvidence.versionInfoChinese:
    case GalJapaneseLocaleEvidence.dirFileNameChinesePatch:
    case GalJapaneseLocaleEvidence.dirTextGbk:
    case GalJapaneseLocaleEvidence.dirTextSimplifiedHanzi:
      return true;
    case GalJapaneseLocaleEvidence.userLanguageJapanese:
    case GalJapaneseLocaleEvidence.userLanguageOther:
    case GalJapaneseLocaleEvidence.versionInfoJapanese:
    case GalJapaneseLocaleEvidence.exeShiftJisStrings:
    case GalJapaneseLocaleEvidence.dirFileNameJapanese:
    case GalJapaneseLocaleEvidence.dirTextShiftJis:
      return false;
  }
}

/// 正向证据：无负向证据时任一命中 ⇒ [GalJapaneseLocaleNeed.needed]。
bool galJapaneseLocaleEvidenceIsPositive(GalJapaneseLocaleEvidence evidence) {
  switch (evidence) {
    case GalJapaneseLocaleEvidence.versionInfoJapanese:
    case GalJapaneseLocaleEvidence.exeShiftJisStrings:
    case GalJapaneseLocaleEvidence.dirFileNameJapanese:
    case GalJapaneseLocaleEvidence.dirTextShiftJis:
      return true;
    case GalJapaneseLocaleEvidence.userLanguageJapanese:
    case GalJapaneseLocaleEvidence.userLanguageOther:
    case GalJapaneseLocaleEvidence.manifestUtf8CodePage:
    case GalJapaneseLocaleEvidence.versionInfoChinese:
    case GalJapaneseLocaleEvidence.dirFileNameChinesePatch:
    case GalJapaneseLocaleEvidence.dirTextGbk:
    case GalJapaneseLocaleEvidence.dirTextSimplifiedHanzi:
      return false;
  }
}

/// 诊断事件 / 日志用的稳定字面量。**不用 `enum.name`**：改枚举名不得改变已写出的事件。
String galJapaneseLocaleNeedToKey(GalJapaneseLocaleNeed need) {
  switch (need) {
    case GalJapaneseLocaleNeed.needed:
      return 'needed';
    case GalJapaneseLocaleNeed.notNeeded:
      return 'not_needed';
    case GalJapaneseLocaleNeed.unknown:
      return 'unknown';
  }
}

/// 同 [galJapaneseLocaleNeedToKey]，也是 i18n 键 `game_japanese_locale_evidence_<key>` 的尾巴。
String galJapaneseLocaleEvidenceToKey(GalJapaneseLocaleEvidence evidence) {
  switch (evidence) {
    case GalJapaneseLocaleEvidence.userLanguageJapanese:
      return 'user_language_japanese';
    case GalJapaneseLocaleEvidence.userLanguageOther:
      return 'user_language_other';
    case GalJapaneseLocaleEvidence.manifestUtf8CodePage:
      return 'manifest_utf8_code_page';
    case GalJapaneseLocaleEvidence.versionInfoJapanese:
      return 'version_info_japanese';
    case GalJapaneseLocaleEvidence.versionInfoChinese:
      return 'version_info_chinese';
    case GalJapaneseLocaleEvidence.exeShiftJisStrings:
      return 'exe_shift_jis_strings';
    case GalJapaneseLocaleEvidence.dirFileNameJapanese:
      return 'dir_file_name_japanese';
    case GalJapaneseLocaleEvidence.dirFileNameChinesePatch:
      return 'dir_file_name_chinese_patch';
    case GalJapaneseLocaleEvidence.dirTextShiftJis:
      return 'dir_text_shift_jis';
    case GalJapaneseLocaleEvidence.dirTextGbk:
      return 'dir_text_gbk';
    case GalJapaneseLocaleEvidence.dirTextSimplifiedHanzi:
      return 'dir_text_simplified_hanzi';
  }
}

/// 三态结论 + **裁决所依据的**证据。纯值对象，三端可单测。
///
/// [evidence] 只列真正决定了 [need] 的那一组（人工声明 / 负向 / 正向），不是探测到的
/// 全部：汉化版同时带着 0x0411 版本资源与「汉化」文件名时，给用户看「判据：文件名含
/// 汉化标记」才说得清为什么没转区；把日文证据一起列出来只会让人以为判定自相矛盾。
class GalJapaneseLocaleVerdict {
  const GalJapaneseLocaleVerdict({
    required this.need,
    this.evidence = const <GalJapaneseLocaleEvidence>[],
  });

  /// 一条证据都没有时的结论。
  static const GalJapaneseLocaleVerdict unknown =
      GalJapaneseLocaleVerdict(need: GalJapaneseLocaleNeed.unknown);

  final GalJapaneseLocaleNeed need;
  final List<GalJapaneseLocaleEvidence> evidence;

  @override
  String toString() =>
      'GalJapaneseLocaleVerdict(${galJapaneseLocaleNeedToKey(need)}, '
      '${evidence.map(galJapaneseLocaleEvidenceToKey).join(',')})';
}

/// 把探测到的证据裁决成三态结论。纯函数，顺序即优先级：
///
/// 1. 用户声明语言优先（[GalJapaneseLocaleEvidence.userLanguageJapanese] ⇒ needed，
///    [GalJapaneseLocaleEvidence.userLanguageOther] ⇒ notNeeded）。
/// 2. 任一负向证据 ⇒ notNeeded（转错闪退、不转乱码，代价不对称）。
/// 3. 任一正向证据 ⇒ needed。
/// 4. 否则 unknown。
///
/// 输入允许重复与任意顺序；输出证据去重、保持首次出现的顺序。
GalJapaneseLocaleVerdict judgeJapaneseLocaleNeed(
  Iterable<GalJapaneseLocaleEvidence> evidence,
) {
  final List<GalJapaneseLocaleEvidence> seen =
      <GalJapaneseLocaleEvidence>{...evidence}.toList(growable: false);
  if (seen.contains(GalJapaneseLocaleEvidence.userLanguageJapanese)) {
    return const GalJapaneseLocaleVerdict(
      need: GalJapaneseLocaleNeed.needed,
      evidence: <GalJapaneseLocaleEvidence>[
        GalJapaneseLocaleEvidence.userLanguageJapanese,
      ],
    );
  }
  if (seen.contains(GalJapaneseLocaleEvidence.userLanguageOther)) {
    return const GalJapaneseLocaleVerdict(
      need: GalJapaneseLocaleNeed.notNeeded,
      evidence: <GalJapaneseLocaleEvidence>[
        GalJapaneseLocaleEvidence.userLanguageOther,
      ],
    );
  }
  final List<GalJapaneseLocaleEvidence> negative =
      seen.where(galJapaneseLocaleEvidenceIsNegative).toList(growable: false);
  if (negative.isNotEmpty) {
    return GalJapaneseLocaleVerdict(
      need: GalJapaneseLocaleNeed.notNeeded,
      evidence: negative,
    );
  }
  final List<GalJapaneseLocaleEvidence> positive =
      seen.where(galJapaneseLocaleEvidenceIsPositive).toList(growable: false);
  if (positive.isNotEmpty) {
    return GalJapaneseLocaleVerdict(
      need: GalJapaneseLocaleNeed.needed,
      evidence: positive,
    );
  }
  return GalJapaneseLocaleVerdict.unknown;
}

/// 本次启动到底转不转区。纯函数，三端可单测。
///
/// [launchMode] 只有 launch（由 Hibiki 拉起游戏）才可能转区；attach 到已运行进程时
/// 进程早就建好了，转区必然短路。
/// [systemAnsiCodePage] 宿主机的 ACP（`GetACP()`）；拿不到传 null。
/// [is32Bit] 目标 exe 是否 32 位（Locale Emulator 目前只有 x86 版，这是**工程限制**）。
/// [need] 「这个游戏需不需要 CP932」的语义结论（[judgeJapaneseLocaleNeed]）；老调用
/// 不传 = [GalJapaneseLocaleNeed.unknown]。
///
/// `auto` 下先问语义、再过工程门：**只有** [GalJapaneseLocaleNeed.needed] 才转区，
/// 然后才看系统 ACP 与位数。BUG-1477 之前那句「32 位 ⇒ 日文原版」把工程限制当成了
/// 语义判据，中文系统上每一个 32 位游戏都被转区（BUG-2047）；汉化版恰好落在最坏格：
/// 32 位（老引擎）但字符串已是 GBK/UTF-8，套 CP932 反而更糟。
///
/// `unknown` **不转区**（见 [GalJapaneseLocaleNeed.unknown]）。`auto` 仍可能判错，
/// 所以两头都留了用户档位：证据空白的日文原版改 [GalJapaneseLocaleMode.on]，
/// 误判为需要的改 [GalJapaneseLocaleMode.off]；判定结果与证据会进会话状态卡。
bool resolveJapaneseLocale({
  required GalJapaneseLocaleMode mode,
  required bool launchMode,
  required bool is32Bit,
  int? systemAnsiCodePage,
  GalJapaneseLocaleNeed need = GalJapaneseLocaleNeed.unknown,
}) {
  if (!launchMode) return false;
  switch (mode) {
    case GalJapaneseLocaleMode.off:
      return false;
    case GalJapaneseLocaleMode.on:
      return true;
    case GalJapaneseLocaleMode.auto:
      // ① 语义门：没有证据说明文本是 CP932，就不转。
      if (need != GalJapaneseLocaleNeed.needed) return false;
      // ② 系统 ACP 已经是 932：用户机器本就日文区，转区纯属有害无益。
      if (systemAnsiCodePage == 932) return false;
      // ③ Locale Emulator 只有 x86 版：64 位目标转不了（工程限制，非语义判断）。
      return is32Bit;
  }
}
