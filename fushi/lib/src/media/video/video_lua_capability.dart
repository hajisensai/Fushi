/// 随包 libmpv 有没有编入 Lua 解释器（BUG-2032）。
///
/// 这是**二进制事实**，按平台随包固定：Windows 用 zhongfly 全量构建
/// （`-Dlua=enabled`，luajit）；Android 用 media-kit 派生的 `full-*.jar`，实测
/// `libmpv.so` 的 configuration 字串是 `-Dlua=disabled`——`load-script` 命令表项
/// 仍在、命令"成功"返回，但没有后端能执行 `.lua`，脚本永远不会跑。iOS / macOS
/// 随包未验证。
///
/// 判定只认 mpv 自己的 `mpv-configuration` 属性（meson 构建参数原文），不按
/// `Platform.isXxx` 硬编码：jar 一旦重编带 Lua，这里自动翻绿，不需要改代码。
enum MpvLuaCapability {
  /// 尚未探测 / 构建串里没有 `-Dlua=`（老 waf 构建或 meson<1.1 的占位串）。
  /// 门控上按"可能可用"处理——不能拿不知道当不可用。
  unknown,

  /// `-Dlua=enabled|lua|lua52|lua51|luajit`：脚本能跑。
  available,

  /// `-Dlua=disabled`：脚本在本平台无法运行。
  unavailable;

  /// 由持久化的 [name] 还原；未知字面量按 [unknown]（老版本 / 脏值不致崩）。
  static MpvLuaCapability fromName(String? name) {
    for (final MpvLuaCapability value in values) {
      if (value.name == name) return value;
    }
    return unknown;
  }
}

final RegExp _luaFlag = RegExp(r'-Dlua=([A-Za-z0-9_]+)');

/// 从 libmpv `mpv-configuration` 属性值解析 Lua 能力。纯函数。
///
/// meson 的 `lua` 是 combo 选项：`auto` / `enabled` / `disabled` / `luajit` /
/// `lua52` / `lua51` / `lua`。只有 `disabled` 是确定的"没有"；`auto` 取决于
/// 构建机有没有装 Lua，构建串看不出结果，归 [MpvLuaCapability.unknown]；其余
/// 都是显式要求编入，归 [MpvLuaCapability.available]。
MpvLuaCapability parseMpvLuaCapability(String mpvConfiguration) {
  final RegExpMatch? match = _luaFlag.firstMatch(mpvConfiguration);
  if (match == null) return MpvLuaCapability.unknown;
  switch (match.group(1)) {
    case 'disabled':
      return MpvLuaCapability.unavailable;
    case 'auto':
      return MpvLuaCapability.unknown;
    default:
      return MpvLuaCapability.available;
  }
}
