import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';

void main() {
  test('window binding is app-level state and stop keeps binding by default',
      () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: false,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );
    const ExternalWindowInfo window = ExternalWindowInfo(
      hwnd: 77,
      pid: 1234,
      title: 'Test Game',
    );

    await controller.bindWindow(window);
    expect(controller.state.boundWindow, window);
    expect(controller.state.gamePid, 1234);
    expect(
      controller.events.map((event) => event.code),
      contains('window.bound'),
    );

    await controller.stopCapture();
    expect(controller.state.phase, GalHookSessionPhase.idle);
    expect(controller.state.boundWindow, window);

    await controller.close();
    endpoints.dispose();
  });

  test('new external line is observed after the text ring buffer is full',
      () async {
    final TexthookerService service = TexthookerService.test();
    for (int i = 0; i < TexthookerService.maxLines; i++) {
      service.appendLine('line $i');
    }
    final ChangeNotifier endpoints = ChangeNotifier();
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: false,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );
    expect(controller.state.hasText, isTrue);

    service.appendLine(
      'newest',
      source: TexthookerLineSource.websocket,
      sourceLabel: 'ws://localhost:6677',
    );

    expect(service.entries, hasLength(TexthookerService.maxLines));
    expect(
      controller.events.map((event) => event.code),
      contains('text.external_line_received'),
    );

    await controller.close();
    endpoints.dispose();
  });
}
