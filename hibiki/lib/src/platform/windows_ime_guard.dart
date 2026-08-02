import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:hibiki/src/shortcuts/gamepad_service.dart'
    show focusedEditableText;

/// BUG-1450：Windows 上中文输入法激活时全表面快捷键失效的根治开关。
///
/// 根因不在快捷键解析层。Flutter 的 Windows 窗口**终生**保留 IME context——引擎
/// 不会在「没有文本框聚焦」时解除关联。于是只要输入法处于吞键模式（微软拼音的中文
/// 态、MS-IME 的假名态），每一次按键都被输入法拿走，以
/// `WM_KEYDOWN / wParam=VK_PROCESSKEY` 到达，引擎再把它报成
/// `physical=0 / logical=0` 的 KeyEvent（BUG-1427 已把这条平台事实钉成守卫），
/// 于是整张快捷键表静默失效。
///
/// 日语输入法「看起来正常」只是因为它常驻半角英数态、根本不吃字母；被吃掉的空格那
/// 一个键恰好被 BUG-1239 的 native 单键转发救了回来。中文拼音没有等价的英数态
/// （切英文就等于切走输入法），所以空格 + 全部字母快捷键一起废。
///
/// 修法是消除这个特殊情况而不是逐键补转发：**没有文本输入焦点时解除窗口的 IME
/// 关联**，按键根本不进输入法，走正常 KeyEvent 管线；文本框一拿到焦点立刻恢复，
/// 中日文输入照常。native 侧见 `windows/runner/ime_association_guard.h`。
///
/// 只作用于 Windows。其它平台不存在这条平台缺陷，`install` 直接空转。
abstract final class WindowsImeGuard {
  static const MethodChannel _channel =
      MethodChannel('app.hibiki/windows_ime_guard');

  static bool _installed = false;
  static bool? _lastSent;

  /// 仅供测试覆盖平台判定与通道，避免真机 channel 依赖。
  @visibleForTesting
  static bool debugForceEnabled = false;

  /// 仅供测试观察最近一次真正发出的请求（null = 还没发过）。
  @visibleForTesting
  static bool? get debugLastSent => _lastSent;

  @visibleForTesting
  static void debugReset() {
    FocusManager.instance.removeListener(_onFocusChanged);
    _installed = false;
    _lastSent = null;
  }

  static bool get _active =>
      debugForceEnabled ||
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows);

  /// 挂上焦点监听。幂等；非 Windows 平台空转。
  ///
  /// 启动时没有任何文本框持焦，所以首次同步会立刻解除关联——快捷键从冷启动第一帧
  /// 起就不受输入法影响。
  static void install() {
    if (_installed || !_active) return;
    _installed = true;
    FocusManager.instance.addListener(_onFocusChanged);
    _syncNow();
  }

  static void _onFocusChanged() => _syncNow();

  static void _syncNow() {
    final EditableText? editable = focusedEditableText();
    final bool enable = imeShouldBeEnabled(
      hasEditableFocus: editable != null,
      focusedEditableIsReadOnly: editable?.readOnly ?? true,
    );
    // 焦点变化一帧内会触发多次通知；只有状态真正翻转才打通道。
    if (_lastSent == enable) return;
    _lastSent = enable;
    unawaited(_send(enable));
  }

  static Future<void> _send(bool enable) async {
    try {
      await _channel.invokeMethod<void>('setImeEnabled', enable);
    } on MissingPluginException {
      // 旧 runner（未含 BUG-1450 的 native 侧）：保持现状，不让缺通道把 app 打挂。
    } on PlatformException {
      // 关联失败不致命——最坏是回到修复前的行为。下次焦点翻转会重试，因为失败的
      // 状态没有在 native 侧落账（见 ImeAssociationGuard::SetEnabled）。
      _lastSent = null;
    }
  }
}

/// 是否应当让输入法接管按键。
///
/// 唯一判据是「有没有真正在接收输入的文本框」：有就必须开（否则用户打不了中日文），
/// 没有就必须关（否则输入法吞掉全部快捷键）。不能只判断 [EditableText] 是否存在：
/// [SelectableText] 内部同样用一个 `readOnly` 的 [EditableText] 承载选择焦点，点击它
/// 不代表用户要输入文字。这里按输入能力判定，而不是对白名单里的 widget 类型特判。
/// 抽成纯函数以便直接单测，不必起平台通道。
bool imeShouldBeEnabled({
  required bool hasEditableFocus,
  required bool focusedEditableIsReadOnly,
}) =>
    hasEditableFocus && !focusedEditableIsReadOnly;
