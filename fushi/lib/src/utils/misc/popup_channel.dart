import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// BUG-3487：截屏识字带来的「被点字所在 OCR text block 全文 + 本行在块里的起点」。
/// 只有截屏识字入口给；其它入口为 null（制卡句子回落为整行）。
typedef PopupSourceBlock = ({String text, int offset});

/// 原生侧推来的一次查词。
typedef PopupProcessTextHandler =
    void Function(
      String text,
      int charIndex,
      Rect? anchor,
      Rect? subtitle,
      PopupSourceBlock? sourceBlock,
    );

class PopupChannel {
  PopupChannel._();
  static final PopupChannel instance = PopupChannel._();

  static const _channel = FushiChannels.popup;

  PopupProcessTextHandler? _onNewProcessText;

  void init({PopupProcessTextHandler? onNewProcessText}) {
    _onNewProcessText = onNewProcessText;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onNewProcessText' && _onNewProcessText != null) {
        final _ProcessText parsed = _parseProcessTextArgs(call.arguments);
        // 空词也放行：原生侧只在入口**有意**打开空查词窗时才推空词（悬浮球「查词」、
        // 剪贴板为空，见 PopupEngineHolder.pushProcessText 的 allowBlank），热页据此
        // 清掉上一次的结果、回到只有搜索栏的初始态。系统 PROCESS_TEXT 的偶发空选区
        // 在原生侧就被丢掉了，到不了这里。
        _onNewProcessText!(
          parsed.text,
          parsed.charIndex,
          parsed.anchor,
          parsed.subtitle,
          parsed.sourceBlock,
        );
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
            data.sourceBlock,
          );
        }
      });
    }
  }

  Future<
    ({
      String? text,
      int charIndex,
      Rect? anchor,
      Rect? subtitle,
      PopupSourceBlock? sourceBlock,
    })
  >
  getInitialProcessText() async {
    try {
      final Object? result = await _channel.invokeMethod<Object>(
        'getInitialProcessText',
      );
      if (result is Map) {
        final String? text = result['text']?.toString();
        final int charIndex = result['charIndex'] is int
            ? result['charIndex'] as int
            : -1;
        return (
          text: text,
          charIndex: charIndex,
          anchor: _parseAnchor(result['anchor']),
          subtitle: _parseAnchor(result['subtitle']),
          sourceBlock: _parseSourceBlock(result),
        );
      }
      if (result is String) {
        return (
          text: result,
          charIndex: -1,
          anchor: null,
          subtitle: null,
          sourceBlock: null,
        );
      }
      return (
        text: null,
        charIndex: -1,
        anchor: null,
        subtitle: null,
        sourceBlock: null,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log(
        'PopupChannel.getInitialProcessText',
        e,
        stack,
      );
      debugPrint('[Fushi-popup] getInitialProcessText failed: $e');
      return (
        text: null,
        charIndex: -1,
        anchor: null,
        subtitle: null,
        sourceBlock: null,
      );
    }
  }

  static _ProcessText _parseProcessTextArgs(Object? args) {
    if (args is Map) {
      final String text = args['text']?.toString() ?? '';
      final int charIndex = args['charIndex'] is int
          ? args['charIndex'] as int
          : -1;
      return (
        text: text,
        charIndex: charIndex,
        anchor: _parseAnchor(args['anchor']),
        subtitle: _parseAnchor(args['subtitle']),
        sourceBlock: _parseSourceBlock(args),
      );
    }
    if (args is String) {
      return (
        text: args,
        charIndex: -1,
        anchor: null,
        subtitle: null,
        sourceBlock: null,
      );
    }
    return (
      text: '',
      charIndex: -1,
      anchor: null,
      subtitle: null,
      sourceBlock: null,
    );
  }

  /// BUG-3487：截屏识字的所属块全文与本行起点。缺键 / 类型不对 / 偏移越界一律 null
  /// （不抛），制卡句子回落为整行。
  static PopupSourceBlock? _parseSourceBlock(Map<Object?, Object?> map) {
    final Object? text = map['sourceBlock'];
    final Object? offset = map['sourceBlockOffset'];
    if (text is! String || offset is! int) return null;
    if (offset < 0 || offset > text.length) return null;
    return (text: text, offset: offset);
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

typedef _ProcessText = ({
  String text,
  int charIndex,
  Rect? anchor,
  Rect? subtitle,
  PopupSourceBlock? sourceBlock,
});
