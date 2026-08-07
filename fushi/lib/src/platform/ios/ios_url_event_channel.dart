import 'package:flutter/services.dart';

class IosUrlEventChannel {
  const IosUrlEventChannel._();

  static const MethodChannel _method =
      MethodChannel('app.fushi.reader/url_events');
  static const EventChannel _events =
      EventChannel('app.fushi.reader/url_events/stream');

  static Future<String?> getInitialUrl() =>
      _method.invokeMethod<String>('getInitialUrl');

  static Stream<String> get urls => _events
      .receiveBroadcastStream()
      .where((event) => event is String)
      .cast<String>();
}
