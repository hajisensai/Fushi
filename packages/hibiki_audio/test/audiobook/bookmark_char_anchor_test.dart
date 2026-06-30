import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// BUG-459: Bookmark 被复用为「跳回原文」的内存传输。真实书签的 normCharOffset 是
/// 0-10000 章内进度分数；收藏句 / 制卡历史的偏移是 getNormalizedOffset 的「章节内
/// 绝对可匹配字符索引」，必须走独立的 charAnchor 字段，避免跳转端把绝对索引误当
/// 分数 /10000≈0 而恒跳章首。这两个新字段只用于内存传输，不得反序列化进真实书签。
void main() {
  group('Bookmark BUG-459 char anchor transport', () {
    test('真实书签默认无 charAnchor、不抑制进度保存（向后兼容分数路径）', () {
      final Bookmark bm = Bookmark(
        sectionIndex: 3,
        normCharOffset: 5000, // 0-10000 分数 = 章节中点
        label: 'ch4 50%',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      expect(bm.charAnchor, isNull,
          reason: '真实书签不带绝对字符锚 → 跳转端走 normCharOffset/10000 分数恢复');
      expect(bm.preserveSavedPosition, isFalse, reason: '真实书签跳转照常持久化阅读进度');
    });

    test('收藏句 / 制卡历史跳转可携带绝对字符锚并抑制进度覆盖', () {
      final Bookmark bm = Bookmark(
        sectionIndex: 1,
        normCharOffset: 0, // 句子跳转不走分数
        charAnchor: 4231, // getNormalizedOffset 口径绝对索引
        preserveSavedPosition: true,
        label: '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
      );
      expect(bm.charAnchor, 4231);
      expect(bm.preserveSavedPosition, isTrue);
    });

    test('charAnchor / preserveSavedPosition 不持久化（fromJson / toJson 不含）', () {
      // 即便上游误把绝对索引塞进 JSON，反序列化也恒得真实书签语义（charAnchor==null）。
      final Bookmark roundTripped = Bookmark.fromJson(<String, dynamic>{
        'sectionIndex': 2,
        'normCharOffset': 1234,
        'label': 'l',
        'createdAt':
            DateTime.fromMillisecondsSinceEpoch(3000).toIso8601String(),
        // 故意塞入临时字段——必须被忽略，不污染持久化书签语义。
        'charAnchor': 9999,
        'preserveSavedPosition': true,
      });
      expect(roundTripped.charAnchor, isNull,
          reason: 'charAnchor 是内存传输字段，反序列化不读取');
      expect(roundTripped.preserveSavedPosition, isFalse,
          reason: 'preserveSavedPosition 是内存传输字段，反序列化恒默认 false');

      final Map<String, dynamic> json = Bookmark(
        sectionIndex: 1,
        normCharOffset: 0,
        charAnchor: 4231,
        preserveSavedPosition: true,
        label: '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
      ).toJson();
      expect(json.containsKey('charAnchor'), isFalse,
          reason: 'toJson 不写 charAnchor（不持久化）');
      expect(json.containsKey('preserveSavedPosition'), isFalse,
          reason: 'toJson 不写 preserveSavedPosition（不持久化）');
    });
  });
}
