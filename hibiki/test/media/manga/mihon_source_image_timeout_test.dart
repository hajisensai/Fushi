import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/mihon/desktop_mihon_runtime.dart';

void main() {
  test('source image timeout is extended beyond the old fixed 45 seconds', () {
    expect(
      kMihonSourceImageHeaderTimeout,
      greaterThan(const Duration(seconds: 45)),
    );
    expect(
      kMihonSourceImageIdleTimeout,
      greaterThan(const Duration(seconds: 45)),
    );
  });

  test('each received image chunk refreshes the idle timeout', () async {
    final StreamController<List<int>> controller =
        StreamController<List<int>>();
    final Future<Uint8List> reading = readMihonSourceImageBytes(
      controller.stream,
      idleTimeout: const Duration(milliseconds: 500),
    );

    controller.add(<int>[1]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    controller.add(<int>[2]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    controller.add(<int>[3]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await controller.close();

    expect(await reading, Uint8List.fromList(<int>[1, 2, 3]));
  });

  test('source image still fails after a real interval without progress',
      () async {
    final StreamController<List<int>> controller =
        StreamController<List<int>>();
    addTearDown(controller.close);
    final Future<Uint8List> reading = readMihonSourceImageBytes(
      controller.stream,
      idleTimeout: const Duration(milliseconds: 80),
    );
    controller.add(<int>[1]);

    await expectLater(reading, throwsA(isA<TimeoutException>()));
  });
}
