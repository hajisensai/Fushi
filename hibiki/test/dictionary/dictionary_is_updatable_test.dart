import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

/// TODO-609：Dictionary 来源 getter。在线来源词典把 revision/isUpdatable/
/// indexUrl/downloadUrl 落进 metadata（弱类型，零 schema 迁移）。
///
/// isUpdatable 是**三条件与门**：必须 metadata['isUpdatable']=='true' 且
/// indexUrl 非空 且 downloadUrl 非空——任一缺失都不显示更新按钮、不崩。
/// 旧词典 metadata 为空 → 三条件全不满足 → false（向后兼容）。
void main() {
  Dictionary dict(Map<String, String> metadata) => Dictionary(
        name: 'JMdict',
        formatKey: 'yomichan',
        order: 0,
        metadata: metadata,
      );

  group('Dictionary 来源 getter', () {
    test('revision/indexUrl/downloadUrl 读 metadata，缺则空串', () {
      final Dictionary d = dict({
        'revision': '2026-06-20',
        'indexUrl': 'https://example.com/index.json',
        'downloadUrl': 'https://example.com/dict.zip',
      });
      expect(d.revision, '2026-06-20');
      expect(d.indexUrl, 'https://example.com/index.json');
      expect(d.downloadUrl, 'https://example.com/dict.zip');
    });

    test('metadata 空 → getter 全空串', () {
      final Dictionary d = dict(const {});
      expect(d.revision, '');
      expect(d.indexUrl, '');
      expect(d.downloadUrl, '');
    });

    test('三条件全满足 → isUpdatable true', () {
      final Dictionary d = dict({
        'isUpdatable': 'true',
        'indexUrl': 'https://example.com/index.json',
        'downloadUrl': 'https://example.com/dict.zip',
      });
      expect(d.isUpdatable, isTrue);
    });

    test('isUpdatable != true → false（即便 url 都在）', () {
      final Dictionary d = dict({
        'isUpdatable': 'false',
        'indexUrl': 'https://example.com/index.json',
        'downloadUrl': 'https://example.com/dict.zip',
      });
      expect(d.isUpdatable, isFalse);
    });

    test('缺 indexUrl → false（与门）', () {
      final Dictionary d = dict({
        'isUpdatable': 'true',
        'downloadUrl': 'https://example.com/dict.zip',
      });
      expect(d.isUpdatable, isFalse);
    });

    test('缺 downloadUrl → false（与门）', () {
      final Dictionary d = dict({
        'isUpdatable': 'true',
        'indexUrl': 'https://example.com/index.json',
      });
      expect(d.isUpdatable, isFalse);
    });

    test('旧词典 metadata 全空 → isUpdatable false（向后兼容）', () {
      final Dictionary d = dict(const {});
      expect(d.isUpdatable, isFalse);
    });

    test('isUpdatable 缺失（仅 url）→ false', () {
      final Dictionary d = dict({
        'indexUrl': 'https://example.com/index.json',
        'downloadUrl': 'https://example.com/dict.zip',
      });
      expect(d.isUpdatable, isFalse);
    });
  });
}
