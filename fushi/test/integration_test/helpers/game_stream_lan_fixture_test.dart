import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../integration_test/helpers/game_stream_lan_fixture.dart';

void main() {
  test('recorder restores binding handler after app override', () {
    final FlutterExceptionHandler? original = FlutterError.onError;
    addTearDown(() => FlutterError.onError = original);
    final List<String> calls = <String>[];
    void bindingHandler(FlutterErrorDetails details) {
      calls.add('binding:${details.exception.runtimeType}');
    }

    final GameStreamFlutterErrorRecorder recorder =
        GameStreamFlutterErrorRecorder(bindingHandler: bindingHandler);
    FlutterError.onError = (_) => calls.add('app');
    recorder.install();

    FlutterError.reportError(
      FlutterErrorDetails(
        exception: PlatformException(code: 'window_not_foreground'),
      ),
    );
    expect(recorder.lastFailure, <String, Object?>{
      'failureType': 'PlatformException',
      'failureCode': 'window_not_foreground',
    });
    expect(calls, <String>['binding:PlatformException']);

    FlutterError.onError = (_) => calls.add('app-after-install');
    recorder.restore();
    expect(identical(FlutterError.onError, bindingHandler), isTrue);
  });
}
