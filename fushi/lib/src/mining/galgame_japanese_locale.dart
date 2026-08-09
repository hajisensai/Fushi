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

/// 本次启动到底转不转区。纯函数，三端可单测。
///
/// [launchMode] 只有 launch（由 Hibiki 拉起游戏）才可能转区；attach 到已运行进程时
/// 进程早就建好了，转区必然短路。
/// [systemAnsiCodePage] 宿主机的 ACP（`GetACP()`）；拿不到传 null。
/// [is32Bit] 目标 exe 是否 32 位（Locale Emulator 目前只有 x86 版，这是**工程限制**）。
///
/// `auto` 下是**一道否定门 + 一道工程门**，而不是原来那一句「32 位 ⇒ 日文原版」——
/// 后者把工程限制当成了语义判据（BUG-1477）。汉化版恰好落在最坏格：32 位（老引擎）
/// 但字符串已是 GBK/UTF-8，套 CP932 反而更糟。
///
/// 注意 `auto` **不可能**在所有情况下判对：exe 位数与文本编码之间根本没有因果关系。
/// 所以真正兜底的是 [off] 这个用户可选的档位，而不是把 `auto` 越修越聪明。
bool resolveJapaneseLocale({
  required GalJapaneseLocaleMode mode,
  required bool launchMode,
  required bool is32Bit,
  int? systemAnsiCodePage,
}) {
  if (!launchMode) return false;
  switch (mode) {
    case GalJapaneseLocaleMode.off:
      return false;
    case GalJapaneseLocaleMode.on:
      return true;
    case GalJapaneseLocaleMode.auto:
      // ① 系统 ACP 已经是 932：用户机器本就日文区，转区纯属有害无益。
      if (systemAnsiCodePage == 932) return false;
      // ② Locale Emulator 只有 x86 版：64 位目标转不了（工程限制，非语义判断）。
      return is32Bit;
  }
}
