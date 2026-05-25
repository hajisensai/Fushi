import 'package:flutter/foundation.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

class PopupChannel {
  PopupChannel._();
  static final PopupChannel instance = PopupChannel._();

  static const _channel = HibikiChannels.popup;

  void Function(String text, int charIndex)? _onNewProcessText;

  void init({
    void Function(String text, int charIndex)? onNewProcessText,
  }) {
    _onNewProcessText = onNewProcessText;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onNewProcessText' && _onNewProcessText != null) {
        final ({String text, int charIndex}) parsed =
            _parseProcessTextArgs(call.arguments);
        if (parsed.text.trim().isNotEmpty) {
          _onNewProcessText!(parsed.text, parsed.charIndex);
        }
      }
    });
    if (_onNewProcessText != null) {
      getInitialProcessText().then((data) {
        if (data.text != null && data.text!.trim().isNotEmpty) {
          _onNewProcessText?.call(data.text!, data.charIndex);
        }
      });
    }
  }

  Future<({String? text, int charIndex})> getInitialProcessText() async {
    try {
      final Object? result =
          await _channel.invokeMethod<Object>('getInitialProcessText');
      if (result is Map) {
        final String? text = result['text']?.toString();
        final int charIndex =
            result['charIndex'] is int ? result['charIndex'] as int : -1;
        return (text: text, charIndex: charIndex);
      }
      if (result is String) {
        return (text: result, charIndex: -1);
      }
      return (text: null, charIndex: -1);
    } catch (e, stack) {
      ErrorLogService.instance
          .log('PopupChannel.getInitialProcessText', e, stack);
      debugPrint('[Hibiki-popup] getInitialProcessText failed: $e');
      return (text: null, charIndex: -1);
    }
  }

  static ({String text, int charIndex}) _parseProcessTextArgs(Object? args) {
    if (args is Map) {
      final String text = args['text']?.toString() ?? '';
      final int charIndex =
          args['charIndex'] is int ? args['charIndex'] as int : -1;
      return (text: text, charIndex: charIndex);
    }
    if (args is String) {
      return (text: args, charIndex: -1);
    }
    return (text: '', charIndex: -1);
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
