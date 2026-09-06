import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/ankimobile_repository.dart';
import 'package:fushi_anki/fushi_anki.dart';

// PR#1222 事后审查补的缺口：原生侧回的 `{status, json}` 到 Dart 三态（四态）的
// 解析此前**零覆盖**——所有测试都注入 `readInfoForAddingJson` 把它绕过去了，
// Swift 侧守卫也只断言源码里出现过 `"denied"` / `"empty"` 这些字面量，没有任何
// 测试断言 Dart 按同一批字面量解析。
//
// 失败场景：任一侧把字面量改成 `"DENIED"` 或改 key 名，编译过、全部测试绿，
// 线上 denied 静默降级成 empty——用户又回到「AnkiMobile 没回传配置」这句
// 与事实无关的诊断，正是 BUG-2150 要消灭的那类误导。
//
// 这里走真 MethodChannel（mock 的是原生那一端），所以字面量两侧必须真的对上。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('app.fushi.reader/ankimobile');

  /// 让通道按原生侧的形状回一个 Map，然后走**未注入**的仓库（真解析路径）。
  Future<AnkiFetchResult> consumeWithNativeReply(
    Map<Object?, Object?>? reply,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'consumeInfoForAddingPasteboard');
      return reply;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final repo = AnkiMobileRepository(openUrl: (_) async => true);
    return repo.consumeInfoForAddingPasteboard();
  }

  String? codeOf(AnkiFetchResult result) =>
      result is AnkiFetchError ? result.code : null;

  test('原生 "denied" 解析成 denied 码（不是降级成 empty）', () async {
    final result = await consumeWithNativeReply(<Object?, Object?>{
      'status': 'denied',
    });
    expect(codeOf(result), AnkiErrorCode.ankiMobilePasteboardDenied);
  });

  test('原生 "notActive" 解析成 not-active 码', () async {
    final result = await consumeWithNativeReply(<Object?, Object?>{
      'status': 'notActive',
    });
    expect(codeOf(result), AnkiErrorCode.ankiMobileNotActive);
  });

  test('原生 "empty" 解析成 pasteboard-empty 码', () async {
    final result = await consumeWithNativeReply(<Object?, Object?>{
      'status': 'empty',
    });
    expect(codeOf(result), AnkiErrorCode.ankiMobilePasteboardEmpty);
  });

  test('原生 "ok" + 有牌组的 JSON 一路走通到成功', () async {
    final result = await consumeWithNativeReply(<Object?, Object?>{
      'status': 'ok',
      'json': '{"decks":[{"id":1,"name":"Default"}],'
          '"notetypes":[{"id":2,"name":"Basic","fields":["Front","Back"]}]}',
    });
    expect(result, isA<AnkiFetchSuccess>());
  });

  test('原生 "ok" 但 json 为空 → empty，不当成功', () async {
    final result = await consumeWithNativeReply(<Object?, Object?>{
      'status': 'ok',
      'json': '  ',
    });
    expect(codeOf(result), AnkiErrorCode.ankiMobilePasteboardEmpty);
  });

  test('通道回 null / 未知 status 一律退成 empty，不崩', () async {
    expect(
      codeOf(await consumeWithNativeReply(null)),
      AnkiErrorCode.ankiMobilePasteboardEmpty,
    );
    expect(
      codeOf(
        await consumeWithNativeReply(<Object?, Object?>{'status': 'DENIED'}),
      ),
      AnkiErrorCode.ankiMobilePasteboardEmpty,
    );
  });
}
