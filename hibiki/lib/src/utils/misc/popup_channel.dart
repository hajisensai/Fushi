import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PopupChannel {
  PopupChannel._();
  static final PopupChannel instance = PopupChannel._();

  static const _channel = MethodChannel('app.hibiki.reader/popup');

  void Function(String)? _onNewProcessText;

  void init({void Function(String)? onNewProcessText}) {
    _onNewProcessText = onNewProcessText;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onNewProcessText' && _onNewProcessText != null) {
        final text = call.arguments as String?;
        if (text != null && text.trim().isNotEmpty) {
          _onNewProcessText!(text);
        }
      }
    });
  }

  Future<String?> getInitialProcessText() async {
    try {
      final result =
          await _channel.invokeMethod<String>('getInitialProcessText');
      return result;
    } catch (e) {
      debugPrint('[Hibiki-popup] getInitialProcessText failed: $e');
      return null;
    }
  }

  Future<void> finishPopup() async {
    try {
      await _channel.invokeMethod<void>('finishPopup');
    } catch (e) {
      debugPrint('[Hibiki-popup] finishPopup failed: $e');
    }
  }
}
