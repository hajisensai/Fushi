import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_reply_json.dart';

void main() {
  group('extractAiJsonObject', () {
    test('裸 JSON 原样返回', () {
      expect(extractAiJsonObject('{"a":1}'), '{"a":1}');
    });

    test('容忍 ```json 围栏与前后散文', () {
      const String reply = 'Sure!\n```json\n{"a": {"b": 2}}\n```\nDone.';
      expect(extractAiJsonObject(reply), '{"a": {"b": 2}}');
    });

    test('字符串里的花括号不参与配对', () {
      const String reply = r'{"css": ".x { color: red }", "n": "\"}\""}';
      expect(extractAiJsonObject(reply), reply);
    });

    test('没有对象或括号不平衡返回 null', () {
      expect(extractAiJsonObject('no json here'), isNull);
      expect(extractAiJsonObject('{"a": 1'), isNull);
    });
  });

  group('decodeAiJsonObject', () {
    test('解出对象并把 key 规整成 String', () {
      final Map<String, Object?>? map = decodeAiJsonObject('x {"k": [1]} y');
      expect(map, isNotNull);
      expect(map!['k'], <Object?>[1]);
    });

    test('坏 JSON / 顶层不是对象返回 null', () {
      expect(decodeAiJsonObject('{"k": }'), isNull);
      expect(decodeAiJsonObject('[1,2]'), isNull);
    });
  });
}
