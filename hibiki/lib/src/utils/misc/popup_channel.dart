import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

class PopupChannel {
  PopupChannel._();
  static final PopupChannel instance = PopupChannel._();

  static const _channel = HibikiChannels.popup;

  void Function(String text, int charIndex, Rect? anchor)? _onNewProcessText;

  void init({
    void Function(String text, int charIndex, Rect? anchor)? onNewProcessText,
  }) {
    _onNewProcessText = onNewProcessText;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onNewProcessText' && _onNewProcessText != null) {
        final ({String text, int charIndex, Rect? anchor}) parsed =
            _parseProcessTextArgs(call.arguments);
        if (parsed.text.trim().isNotEmpty) {
          _onNewProcessText!(parsed.text, parsed.charIndex, parsed.anchor);
        }
      }
    });
    if (_onNewProcessText != null) {
      getInitialProcessText().then((data) {
        if (data.text != null && data.text!.trim().isNotEmpty) {
          _onNewProcessText?.call(data.text!, data.charIndex, data.anchor);
        }
      });
    }
  }

  Future<({String? text, int charIndex, Rect? anchor})>
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
        );
      }
      if (result is String) {
        return (text: result, charIndex: -1, anchor: null);
      }
      return (text: null, charIndex: -1, anchor: null);
    } catch (e, stack) {
      ErrorLogService.instance
          .log('PopupChannel.getInitialProcessText', e, stack);
      debugPrint('[Hibiki-popup] getInitialProcessText failed: $e');
      return (text: null, charIndex: -1, anchor: null);
    }
  }

  static ({String text, int charIndex, Rect? anchor}) _parseProcessTextArgs(
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
      );
    }
    if (args is String) {
      return (text: args, charIndex: -1, anchor: null);
    }
    return (text: '', charIndex: -1, anchor: null);
  }

  /// TODO-872：浮动字幕条点字传来的「被查字屏幕矩形」（物理像素 [left, top, right,
  /// bottom]）。系统 PROCESS_TEXT / hibiki://lookup 不带该字段 → 解析为 null →
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

  Future<void> finishPopup() async {
    try {
      await _channel.invokeMethod<void>('finishPopup');
    } catch (e, stack) {
      ErrorLogService.instance.log('PopupChannel.finishPopup', e, stack);
      debugPrint('[Hibiki-popup] finishPopup failed: $e');
    }
  }
}
