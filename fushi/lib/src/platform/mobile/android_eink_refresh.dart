/// 墨水屏「全刷」的 Android 厂商通道 Dart 门面（拍板台 oF0jVdOTIE 方案 B）。
///
/// 原生实现在 `android/app/src/main/java/app/fushi/reader/EinkRefreshChannel.java`，
/// 方法名是跨语言契约，改一边必须改另一边。
///
/// 墨水屏阅读器的 EPD 控制器各家私有：文石 Onyx（`View.refreshScreen`）、瑞芯微
/// RK35xx（`EinkManager.sendOneFullFrame`，小米 / 掌阅等新机）、NTX（Nook / Tolino，
/// `View.postInvalidateDelayed` 带波形参数）、老瑞芯微 RK30xx（`View.requestEpdMode`）。
/// 原生侧全部走反射探测，不引任何厂商 SDK 依赖；探测不到 = 本机不支持，调用方
/// （`EinkFullRefreshController`）退回通用的黑屏闪刷（方案 A）。
///
/// 非 Android 平台恒返回 false，且**不发任何通道调用**——那边没注册这条通道。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 设备自带全刷的抽象：返回 true = 已向设备的 EPD 控制器请求了一次全刷；
/// false = 本机没有可用的厂商通道（调用方应退回黑屏闪刷）。
abstract interface class EinkDeviceRefresher {
  Future<bool> fullRefresh();
}

/// Android 厂商 EPD 通道。能力探测结果在原生侧缓存（一次进程内不变），
/// Dart 侧再记一份「已知不支持」，之后的翻页不再过通道。
final class AndroidEinkRefresh implements EinkDeviceRefresher {
  AndroidEinkRefresh._();

  static final AndroidEinkRefresh instance = AndroidEinkRefresh._();

  static const String _methodFullRefresh = 'fullRefresh';

  MethodChannel get _channel => FushiChannels.einkRefresh;

  /// false = 已确认本机没有厂商通道；null = 还没问过。
  bool? _supported;

  @override
  Future<bool> fullRefresh() async {
    if (!Platform.isAndroid || _supported == false) return false;
    try {
      final bool requested =
          await _channel.invokeMethod<bool>(_methodFullRefresh) ?? false;
      if (!requested) {
        // 原生侧只在「探测不到任何厂商通道」时返回 false（调用失败走异常），
        // 这个结论一次进程内不会变。
        _supported = false;
      }
      return requested;
    } on MissingPluginException {
      _supported = false;
      return false;
    } on PlatformException catch (e, stack) {
      // 探测到了厂商通道但这次调用失败（反射调用抛错）：记诊断，本次退回闪刷，
      // 不把整条通道判死——下次翻页仍会再试。
      ErrorLogService.instance.log('AndroidEinkRefresh.fullRefresh', e, stack);
      return false;
    }
  }
}
