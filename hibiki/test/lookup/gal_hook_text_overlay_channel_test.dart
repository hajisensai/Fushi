import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/platform/gal_hook_text_overlay_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String channelName = 'app.hibiki.reader/gal_hook_text';
  const MethodChannel channel = MethodChannel(channelName);
  const MethodCodec codec = StandardMethodCodec();

  Future<void> invokeFromNative(String method, [Object? arguments]) async {
    final ByteData data = codec.encodeMethodCall(MethodCall(method, arguments));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(channelName, data, (_) {});
  }

  setUp(() => GalHookTextOverlayChannel.platformOverride = true);

  tearDown(() {
    GalHookTextOverlayChannel.clearEventHandlers();
    GalHookTextOverlayChannel.platformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('lookup callback preserves exact line id, text, and character index',
      () async {
    String? lineId;
    String? text;
    int? index;
    GalHookTextOverlayChannel.setEventHandlers(
      onLookupText: (String id, String value, int valueIndex) {
        lineId = id;
        text = value;
        index = valueIndex;
      },
    );

    await invokeFromNative('lookupText', <String, Object?>{
      'lineId': 'line-42',
      'text': 'これは本だ',
      'index': 3,
    });

    expect(lineId, 'line-42');
    expect(text, 'これは本だ');
    expect(index, 3);
  });

  test('toolbar and native window state events are forwarded', () async {
    final List<String> events = <String>[];
    GalHookTextWindowRect? rect;
    GalHookTextOverlayChannel.setEventHandlers(
      onToggleFollow: () => events.add('follow'),
      onTogglePassThrough: () => events.add('pass'),
      onToggleTransparency: () => events.add('transparent'),
      onOpenWorkbench: () => events.add('workbench'),
      onClose: () => events.add('close'),
      onLockChanged: (bool locked) => events.add('lock:$locked'),
      onBoundsChanged: (GalHookTextWindowRect value) => rect = value,
    );

    await invokeFromNative('toggleFollow');
    await invokeFromNative('togglePassThrough');
    await invokeFromNative('toggleTransparency');
    await invokeFromNative('openWorkbench');
    await invokeFromNative('close');
    await invokeFromNative('lockChanged', <String, Object?>{'locked': true});
    await invokeFromNative('windowRectChanged', <String, Object?>{
      'left': 10,
      'top': 20,
      'width': 900,
      'height': 140,
    });

    expect(events, <String>[
      'follow',
      'pass',
      'transparent',
      'workbench',
      'close',
      'lock:true'
    ]);
    expect(rect?.toMap(), <String, Object?>{
      'left': 10,
      'top': 20,
      'width': 900,
      'height': 140,
    });
  });

  test('show sends restored bounds and Hook defaults', () async {
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      captured = call;
      return true;
    });

    final bool shown = await GalHookTextOverlayChannel.show(
      rect: const GalHookTextWindowRect(
        left: 12,
        top: 34,
        width: 800,
        height: 180,
      ),
      passThrough: true,
      locked: true,
    );

    expect(shown, isTrue);
    expect(captured?.method, 'show');
    final Map<Object?, Object?> args =
        captured?.arguments as Map<Object?, Object?>;
    expect(args['windowWidth'], 900.0);
    expect(args['windowHeight'], 140.0);
    expect(args['bgColor'], 0xE0000000);
    expect(args['clickLookupEnabled'], isTrue);
    expect(args['left'], 12);
    expect(args['top'], 34);
    expect(args['width'], 800);
    expect(args['height'], 180);
    expect(args['passThrough'], isTrue);
    expect(args['locked'], isTrue);
  });

  test('state setters keep following, pass-through, and lock independent',
      () async {
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return null;
    });

    await GalHookTextOverlayChannel.setFollowing(false);
    await GalHookTextOverlayChannel.setPassThrough(true);
    await GalHookTextOverlayChannel.setLocked(true);

    expect(calls.map((MethodCall call) => call.method),
        <String>['setFollowing', 'setPassThrough', 'setLocked']);
    expect(calls[0].arguments, <String, Object?>{'following': false});
    expect(calls[1].arguments, <String, Object?>{'enabled': true});
    expect(calls[2].arguments, <String, Object?>{'locked': true});
  });
}
