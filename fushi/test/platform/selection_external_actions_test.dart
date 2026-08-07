import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/selection_external_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('test/selection_actions');
  final List<MethodCall> calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('share forwards CJK, spaces, and newlines unchanged', () async {
    const String payload = '日本語  中文\nsecond line  ';
    String? shared;
    final SelectionExternalActions actions = SelectionExternalActions(
      channel: channel,
      shareSelectedText: (String text) async {
        shared = text;
      },
    );

    expect(await actions.shareText(payload), isTrue);
    expect(shared, payload);
  });

  test('web search uses exact method and QUERY payload unchanged', () async {
    const String payload = '漢字  かな\nnext line  ';
    final SelectionExternalActions actions = SelectionExternalActions(
      channel: channel,
      shareSelectedText: (String _) async {},
    );

    expect(await actions.searchWeb(payload), isTrue);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'webSearch');
    expect(calls.single.arguments, <String, String>{'query': payload});
  });

  test('missing search handler and failed share return visible-failure signal',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall _) async => false);
    final SelectionExternalActions actions = SelectionExternalActions(
      channel: channel,
      shareSelectedText: (String _) async {
        throw StateError('no share activity');
      },
    );

    expect(await actions.searchWeb('query'), isFalse);
    expect(await actions.shareText('query'), isFalse);
  });
}
