import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_glyphs.dart';

/// 手柄按钮 → 现成图标素材路径映射（TODO-942，用户决策「不要手绘，抄现成的」）。
///
/// 素材来自 **Kenney「Input Prompts」包（CC0 公共领域，无需署名）**，许可副本入库
/// `assets/licenses/kenney_input_prompts_LICENSE.txt`。三品牌各取一套正经的整机
/// 按钮图标（Xbox 彩色 ABXY、PlayStation ✕○□△ 彩色面键、Switch 黑底 ABXY），映射
/// 到 app 现有 17 个 [GamepadButton] 语义。
///
/// **可插拔素材层**：本表只把「逻辑按钮 + 品牌」翻译成一个 asset 路径，渲染层
/// （[GamepadButtonWidget]）负责贴图 + 高亮联动，二者解耦。品牌绝不进入 binding
/// 序列化（[GamepadButton.serialize] 恒定），素材只影响显示。
///
/// [assetFor] 返回 null 表示该品牌该按钮**无对应素材**（如 PlayStation 无独立的
/// PS/Guide 键图标），此时渲染层回退到 [GamepadGlyphs] 的绘制符号占位，永不缺图。
abstract final class GamepadButtonAssets {
  /// 素材根目录（已在 `pubspec.yaml` 的 `flutter/assets` 注册三个品牌子目录）。
  static const String xboxDir = 'assets/gamepad/xbox';
  static const String playstationDir = 'assets/gamepad/playstation';
  static const String switchDir = 'assets/gamepad/switch';

  /// 返回 [button] 在 [brand] 下的素材图路径；无对应素材返回 null（回退绘制符号）。
  static String? assetFor(GamepadButton button, GamepadBrand brand) {
    switch (brand) {
      case GamepadBrand.xbox:
        return _xbox[button];
      case GamepadBrand.playstation:
        return _playstation[button];
      case GamepadBrand.nintendoSwitch:
        return _switch[button];
    }
  }

  // Xbox Series（Kenney）：彩色 ABXY 保留品牌识别度，肩键/扳机/方向键/摇杆/系统键
  // 用官方风格图标。
  static const Map<GamepadButton, String> _xbox = <GamepadButton, String>{
    GamepadButton.a: '$xboxDir/xbox_button_color_a.png',
    GamepadButton.b: '$xboxDir/xbox_button_color_b.png',
    GamepadButton.x: '$xboxDir/xbox_button_color_x.png',
    GamepadButton.y: '$xboxDir/xbox_button_color_y.png',
    GamepadButton.lb: '$xboxDir/xbox_lb.png',
    GamepadButton.rb: '$xboxDir/xbox_rb.png',
    GamepadButton.lt: '$xboxDir/xbox_lt.png',
    GamepadButton.rt: '$xboxDir/xbox_rt.png',
    GamepadButton.dpadUp: '$xboxDir/xbox_dpad_up.png',
    GamepadButton.dpadDown: '$xboxDir/xbox_dpad_down.png',
    GamepadButton.dpadLeft: '$xboxDir/xbox_dpad_left.png',
    GamepadButton.dpadRight: '$xboxDir/xbox_dpad_right.png',
    GamepadButton.thumbLeft: '$xboxDir/xbox_stick_l.png',
    GamepadButton.thumbRight: '$xboxDir/xbox_stick_r.png',
    GamepadButton.start: '$xboxDir/xbox_button_menu.png',
    GamepadButton.select: '$xboxDir/xbox_button_view.png',
    GamepadButton.mode: '$xboxDir/xbox_guide.png',
  };

  // PlayStation Series（Kenney）：✕○□△ 彩色面键、L1/R1/L2/R2 扳机、Create/Options。
  // 无独立 PS/Guide 键图标 → mode 缺省（回退绘制符号）。
  static const Map<GamepadButton, String> _playstation =
      <GamepadButton, String>{
    GamepadButton.a: '$playstationDir/playstation_button_color_cross.png',
    GamepadButton.b: '$playstationDir/playstation_button_color_circle.png',
    GamepadButton.x: '$playstationDir/playstation_button_color_square.png',
    GamepadButton.y: '$playstationDir/playstation_button_color_triangle.png',
    GamepadButton.lb: '$playstationDir/playstation_trigger_l1.png',
    GamepadButton.rb: '$playstationDir/playstation_trigger_r1.png',
    GamepadButton.lt: '$playstationDir/playstation_trigger_l2.png',
    GamepadButton.rt: '$playstationDir/playstation_trigger_r2.png',
    GamepadButton.dpadUp: '$playstationDir/playstation_dpad_up.png',
    GamepadButton.dpadDown: '$playstationDir/playstation_dpad_down.png',
    GamepadButton.dpadLeft: '$playstationDir/playstation_dpad_left.png',
    GamepadButton.dpadRight: '$playstationDir/playstation_dpad_right.png',
    GamepadButton.thumbLeft: '$playstationDir/playstation_stick_l.png',
    GamepadButton.thumbRight: '$playstationDir/playstation_stick_r.png',
    GamepadButton.start: '$playstationDir/playstation5_button_options.png',
    GamepadButton.select: '$playstationDir/playstation5_button_create.png',
    // GamepadButton.mode: 无 PS 系统键素材 → 回退绘制符号。
  };

  // Nintendo Switch（Kenney）：黑底 ABXY（物理位置印字，序列化仍是 Xbox 语义 label）、
  // L/R 与 ZL/ZR、+/− 与 Home。
  static const Map<GamepadButton, String> _switch = <GamepadButton, String>{
    // 面键相对 Xbox **A/B、X/Y 位置对调**（与 GamepadGlyphs 的 Switch 印字一致）：
    // 逻辑底键 .a→物理印字 B、右键 .b→A、左键 .x→Y、上键 .y→X。序列化仍是 label。
    GamepadButton.a: '$switchDir/switch_button_b.png',
    GamepadButton.b: '$switchDir/switch_button_a.png',
    GamepadButton.x: '$switchDir/switch_button_y.png',
    GamepadButton.y: '$switchDir/switch_button_x.png',
    GamepadButton.lb: '$switchDir/switch_button_l.png',
    GamepadButton.rb: '$switchDir/switch_button_r.png',
    GamepadButton.lt: '$switchDir/switch_button_zl.png',
    GamepadButton.rt: '$switchDir/switch_button_zr.png',
    GamepadButton.dpadUp: '$switchDir/switch_dpad_up.png',
    GamepadButton.dpadDown: '$switchDir/switch_dpad_down.png',
    GamepadButton.dpadLeft: '$switchDir/switch_dpad_left.png',
    GamepadButton.dpadRight: '$switchDir/switch_dpad_right.png',
    GamepadButton.thumbLeft: '$switchDir/switch_stick_l.png',
    GamepadButton.thumbRight: '$switchDir/switch_stick_r.png',
    GamepadButton.start: '$switchDir/switch_button_plus.png',
    GamepadButton.select: '$switchDir/switch_button_minus.png',
    GamepadButton.mode: '$switchDir/switch_button_home.png',
  };
}
