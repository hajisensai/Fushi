import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_audio_capture_controller.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel audioChannel =
      MethodChannel('app.hibiki.reader/process_audio_capture');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final GalgameAudioCaptureController capture =
      GalgameAudioCaptureController.instance;
  final DesktopLookupService lookup = DesktopLookupService.instance;

  setUp(() {
    lookup.debugReset();
    capture.debugReset();
    GalgameAudioCaptureController.debugIsSupportedOverride = true;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(audioChannel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    lookup.debugReset();
    capture.debugReset();
    GalgameAudioCaptureController.debugIsSupportedOverride = null;
  });

  test('identical clipboard lines keep distinct audio occurrences', () async {
    final List<String> marked = <String>[];
    messenger.setMockMethodCallHandler(audioChannel, (MethodCall call) async {
      if (call.method == 'mark') {
        final Map<Object?, Object?> args =
            call.arguments! as Map<Object?, Object?>;
        marked.add(args['occurrenceId']! as String);
      }
      return <String, Object?>{'ok': true};
    });
    expect(
      await capture.start(
        const ExternalWindowInfo(hwnd: 1, pid: 77, title: 'VN'),
      ),
      isTrue,
    );

    lookup.processClipboardText('same line');
    final String first = lookup.pendingRequest!.audioOccurrenceId!;
    lookup.clearPending();
    lookup.processClipboardText('same line');
    final String second = lookup.pendingRequest!.audioOccurrenceId!;

    expect(second, isNot(first));
    expect(marked, <String>[first, second]);
    expect(lookup.pendingRequest!.text, 'same line');
  });

  test('hotkey reuses the marker of the current clipboard occurrence',
      () async {
    messenger.setMockMethodCallHandler(
      audioChannel,
      (MethodCall call) async => <String, Object?>{'ok': true},
    );
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async => call.method == 'Clipboard.getData'
          ? <String, Object?>{'text': 'current line'}
          : null,
    );
    expect(
      await capture.start(
        const ExternalWindowInfo(hwnd: 1, pid: 77, title: 'VN'),
      ),
      isTrue,
    );
    lookup.processClipboardText('current line');
    final String occurrence = lookup.pendingRequest!.audioOccurrenceId!;

    await lookup.debugTriggerHotKey();

    expect(lookup.pendingRequest!.origin, DesktopLookupOrigin.hotkey);
    expect(lookup.pendingRequest!.audioOccurrenceId, occurrence);
  });
}
