import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

class PopupChannel {
  PopupChannel._();
  static final PopupChannel instance = PopupChannel._();

  static const _channel = FushiChannels.popup;

  void Function(String text, int charIndex, Rect? anchor, Rect? subtitle)?
      _onNewProcessText;

  void init({
    void Function(String text, int charIndex, Rect? anchor, Rect? subtitle)?
        onNewProcessText,
  }) {
    _onNewProcessText = onNewProcessText;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onNewProcessText' && _onNewProcessText != null) {
        final ({
          String text,
          int charIndex,
          Rect? anchor,
          Rect? subtitle
        }) parsed = _parseProcessTextArgs(call.arguments);
        if (parsed.text.trim().isNotEmpty) {
          _onNewProcessText!(
            parsed.text,
            parsed.charIndex,
            parsed.anchor,
            parsed.subtitle,
          );
        }
      }
    });
    if (_onNewProcessText != null) {
      getInitialProcessText().then((data) {
        if (data.text != null && data.text!.trim().isNotEmpty) {
          _onNewProcessText?.call(
            data.text!,
            data.charIndex,
            data.anchor,
            data.subtitle,
          );
        }
      });
    }
  }

  Future<({String? text, int charIndex, Rect? anchor, Rect? subtitle})>
      getInitialProcessText() async {
    try {
      final Object? result =
          await _channel.invokeMethod<Object>('getInitialProcessText');
      if (result is Map) {
        final String? text = result['text']?.toString();
        final int charIndex =
            result['charIndex'] is int ? result['charIndex'] as int : -1;
        return (
          text: text,
          charIndex: charIndex,
          anchor: _parseAnchor(result['anchor']),
          subtitle: _parseAnchor(result['subtitle']),
        );
      }
      if (result is String) {
        return (text: result, charIndex: -1, anchor: null, subtitle: null);
      }
      return (text: null, charIndex: -1, anchor: null, subtitle: null);
    } catch (e, stack) {
      ErrorLogService.instance
          .log('PopupChannel.getInitialProcessText', e, stack);
      debugPrint('[Fushi-popup] getInitialProcessText failed: $e');
      return (text: null, charIndex: -1, anchor: null, subtitle: null);
    }
  }

  static ({String text, int charIndex, Rect? anchor, Rect? subtitle})
      _parseProcessTextArgs(
    Object? args,
  ) {
    if (args is Map) {
      final String text = args['text']?.toString() ?? '';
      final int charIndex =
          args['charIndex'] is int ? args['charIndex'] as int : -1;
      return (
        text: text,
        charIndex: charIndex,
        anchor: _parseAnchor(args['anchor']),
        subtitle: _parseAnchor(args['subtitle']),
      );
    }
    if (args is String) {
      return (text: args, charIndex: -1, anchor: null, subtitle: null);
    }
    return (text: '', charIndex: -1, anchor: null, subtitle: null);
  }

  /// TODO-872：浮动字幕条点字传来的「被查字屏幕矩形」（物理像素 [left, top, right,
  /// bottom]）。系统 PROCESS_TEXT / fushi://lookup 不带该字段 → 解析为 null →
  /// 弹窗保持默认 topCenter 贴顶。任何非法/不足 4 元素的载荷也回退 null（不抛）。
  static Rect? _parseAnchor(Object? value) {
    if (value is! List || value.length != 4) return null;
    final List<double> sides = <double>[];
    for (final Object? side in value) {
      if (side is num) {
        sides.add(side.toDouble());
      } else {
        return null;
      }
    }
    return Rect.fromLTRB(sides[0], sides[1], sides[2], sides[3]);
  }

  /// 请求原生侧关闭独立查词窗。
  ///
  /// BUG-1757：返回**是否真的有人接下这次关闭**。原生侧的关闭回调注册在
  /// `PopupEngineHolder` 单例上，历史上会被销毁中的旧 Activity 清掉（见该类注释），
  /// 此时这里返回 false —— 调用方必须据此解开自己的关闭闭锁，否则窗口留在屏幕上而
  /// 所有关闭入口永久静默早退。通道异常同样返回 false：宁可让用户能再点一次，
  /// 也不要把弹窗锁死。
  Future<bool> finishPopup() async {
    try {
      final bool? accepted = await _channel.invokeMethod<bool>('finishPopup');
      return accepted ?? false;
    } catch (e, stack) {
      ErrorLogService.instance.log('PopupChannel.finishPopup', e, stack);
      debugPrint('[Fushi-popup] finishPopup failed: $e');
      return false;
    }
  }
}
