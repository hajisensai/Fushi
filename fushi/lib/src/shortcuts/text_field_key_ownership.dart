/// 焦点停在文本框里时，哪些按键归文本框（要打进去的字符），不该被页面级快捷键
/// 解析掉。
///
/// 判据只有一条：有文本框持焦（[focusedEditableText]）、没按 Ctrl / Alt / Meta、
/// 且这次按键会产出一个可打印字符。Shift 不算修饰（`Shift+A` 打大写、德语布局
/// `Shift+7` 打 `/`）；Esc / Tab / F 键 / 方向键不产出可打印字符，照常交给快捷键层
/// （Esc 返回、方向键离开单行框等既有语义不变）。与库页搜索
/// `FushiHeaderSearchKeys`「裸键在输入框里放行」同一条规矩，这里给整页 key sink
/// （首页 `_handleKeyEvent`）用：用户把某个页面动作改绑成裸字母后，在首页的输入框
/// （AI 助手块、搜索框）里打那个字母不会触发动作。
library;

import 'package:flutter/services.dart';

import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show focusedEditableText;

/// [event] 是不是一个要打进当前持焦文本框的字符键（见库注释）。没有文本框持焦时
/// 恒为 false。
bool keyTypesIntoFocusedTextField(KeyEvent event) {
  if (focusedEditableText() == null) return false;
  final HardwareKeyboard keyboard = HardwareKeyboard.instance;
  if (keyboard.isControlPressed ||
      keyboard.isAltPressed ||
      keyboard.isMetaPressed) {
    return false;
  }
  return isPrintableKeyCharacter(event.character);
}

/// [character] 是否是可打印字符（排除 null、空串与 C0 控制字符 / DEL：Enter 产出
/// `\r`、Tab 产出 `\t`、Backspace 产出 `\b` 之类）。
bool isPrintableKeyCharacter(String? character) {
  if (character == null || character.isEmpty) return false;
  final int code = character.runes.first;
  return code >= 0x20 && code != 0x7f;
}
