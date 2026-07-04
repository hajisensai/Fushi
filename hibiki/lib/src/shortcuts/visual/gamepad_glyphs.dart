import 'package:flutter/widgets.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';

/// 手柄品牌（TODO-612 阶段 0，用户决策「手柄图按品牌分」）。
///
/// 底层永远是同一组 [GamepadButton] enum + 同一套序列化 token（"A"/"B"/...），品牌
/// 只决定**显示符号与配色**，绝不进入任何 binding 序列化。Xbox 面键 A/B/X/Y，
/// PlayStation 面键 ✕/○/□/△，Nintendo Switch 面键 B/A/Y/X（相对 Xbox **A/B、X/Y
/// 位置对调**：Switch 底键=B、右键=A、左键=Y、上键=X），但三者在持久化里都还是
/// GamepadButton.a/.b/.x/.y（[GamepadButton.serialize] 恒定），品牌与序列化完全解耦。
///
/// [token] / [fromToken] 只用于**持久化本显示偏好**（`gamepad_glyph_brand` pref），
/// 与 binding 序列化是两条互不相干的通道；未知 token 回退 [xbox]（向后兼容默认）。
enum GamepadBrand {
  xbox('xbox'),
  playstation('playstation'),
  nintendoSwitch('switch');

  const GamepadBrand(this.token);

  /// 持久化 token（只用于显示偏好，不进 binding JSON）。
  final String token;

  /// 从持久化 token 反解品牌；未知/null 回退 [xbox]。
  static GamepadBrand fromToken(String? token) {
    for (final GamepadBrand brand in values) {
      if (brand.token == token) return brand;
    }
    return GamepadBrand.xbox;
  }
}

/// 一个手柄按钮在某品牌下的显示外观：符号文本 + 可选强调色（面键的品牌色）。
@immutable
class GamepadButtonGlyph {
  const GamepadButtonGlyph({
    required this.symbol,
    this.accent,
  });

  /// 显示文本（Xbox 面键为字母 A/B/X/Y，PS 面键为 ✕○□△，肩键/方向键沿用 enum label）。
  final String symbol;

  /// 面键品牌强调色（Xbox 绿红蓝黄 / PS 蓝红粉绿）；非面键为 null。
  final Color? accent;
}

/// 品牌 → 按钮显示符号/配色映射表（只读）。
///
/// 关键不变式：本表只读 [GamepadButton] enum、只产出显示用 [GamepadButtonGlyph]，
/// **从不改写 enum 顺序、label 或序列化**。切换品牌只换 glyph，[GamepadButton.serialize]
/// （= button.label）恒定，故 binding JSON 与品牌完全解耦。
abstract final class GamepadGlyphs {
  // Xbox 面键品牌色（参照官方配色，仅做强调视觉）。
  static const Color _xboxGreen = Color(0xFF107C10);
  static const Color _xboxRed = Color(0xFFB81414);
  static const Color _xboxBlue = Color(0xFF0070C0);
  static const Color _xboxYellow = Color(0xFFE8A200);

  // PlayStation 面键品牌色。
  static const Color _psBlue = Color(0xFF2E6DB4); // ✕ Cross
  static const Color _psRed = Color(0xFFD0021B); // ○ Circle
  static const Color _psPink = Color(0xFFE94B9E); // □ Square
  static const Color _psGreen = Color(0xFF1FA774); // △ Triangle

  // Nintendo Switch 面键：官方手柄是白字深底，无 Xbox/PS 那种逐键彩色；用单一
  // Nintendo 红作品牌识别强调色（四个面键同色，仅字母位置相对 Xbox 对调）。
  static const Color _switchRed = Color(0xFFE60012);

  /// 返回 [button] 在 [brand] 下的显示外观。非面键（肩键/扳机/方向键/摇杆/start 等）
  /// 两品牌共用 enum label，无强调色。
  static GamepadButtonGlyph glyphFor(GamepadButton button, GamepadBrand brand) {
    switch (brand) {
      case GamepadBrand.xbox:
        switch (button) {
          case GamepadButton.a:
            return const GamepadButtonGlyph(symbol: 'A', accent: _xboxGreen);
          case GamepadButton.b:
            return const GamepadButtonGlyph(symbol: 'B', accent: _xboxRed);
          case GamepadButton.x:
            return const GamepadButtonGlyph(symbol: 'X', accent: _xboxBlue);
          case GamepadButton.y:
            return const GamepadButtonGlyph(symbol: 'Y', accent: _xboxYellow);
          default:
            return GamepadButtonGlyph(symbol: button.label);
        }
      case GamepadBrand.playstation:
        switch (button) {
          // PS 面键映射沿用标准布局：A→✕(下)、B→○(右)、X→□(左)、Y→△(上)。
          case GamepadButton.a:
            return const GamepadButtonGlyph(symbol: '✕', accent: _psBlue);
          case GamepadButton.b:
            return const GamepadButtonGlyph(symbol: '○', accent: _psRed);
          case GamepadButton.x:
            return const GamepadButtonGlyph(symbol: '□', accent: _psPink);
          case GamepadButton.y:
            return const GamepadButtonGlyph(symbol: '△', accent: _psGreen);
          default:
            return GamepadButtonGlyph(symbol: button.label);
        }
      case GamepadBrand.nintendoSwitch:
        // Switch 面键相对 Xbox **A/B、X/Y 位置对调**：同一物理位置上 Nintendo 印的
        // 字母与 Xbox 相反。逻辑 button（= Xbox 语义/位置）→ Switch 印字：
        //   底键 GamepadButton.a → 'B'、右键 GamepadButton.b → 'A'、
        //   左键 GamepadButton.x → 'Y'、上键 GamepadButton.y → 'X'。
        // 序列化恒为 button.label（A/B/X/Y），仅显示符号对调。
        switch (button) {
          case GamepadButton.a:
            return const GamepadButtonGlyph(symbol: 'B', accent: _switchRed);
          case GamepadButton.b:
            return const GamepadButtonGlyph(symbol: 'A', accent: _switchRed);
          case GamepadButton.x:
            return const GamepadButtonGlyph(symbol: 'Y', accent: _switchRed);
          case GamepadButton.y:
            return const GamepadButtonGlyph(symbol: 'X', accent: _switchRed);
          default:
            return GamepadButtonGlyph(symbol: button.label);
        }
    }
  }
}
