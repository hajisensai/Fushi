import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/collections/collection_grouping.dart';
import 'package:hibiki/src/utils/misc/shelf_ordering.dart';

/// 命名统一 Phase 3.3 守卫：统一媒体身份值对象 [MediaRef] 的值语义 / 序列化
/// 形态冻结，以及三个既有身份类型对它的委托不改变对外行为。
void main() {
  group('MediaRef 值语义', () {
    test('== / hashCode 按 (kind, entryKey) 二元组比较', () {
      const MediaRef a = MediaRef(kind: MediaKind.epub, entryKey: 'k1');
      const MediaRef b = MediaRef(kind: MediaKind.epub, entryKey: 'k1');
      const MediaRef otherKey = MediaRef(kind: MediaKind.epub, entryKey: 'k2');
      const MediaRef otherKind = MediaRef(kind: MediaKind.srt, entryKey: 'k1');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(otherKey));
      expect(a, isNot(otherKind));
    });

    test('序列化形态冻结：dbMediaType = MediaKind.dbValue、compositeKey 同历史插值', () {
      const MediaRef v = MediaRef(kind: MediaKind.video, entryKey: 'v/1');
      expect(v.dbMediaType, 'video');
      expect(v.compositeKey, 'video|v/1');
      expect(
        const MediaRef(kind: MediaKind.game, entryKey: 'g1').compositeKey,
        'game|g1',
      );
    });

    test('tryParse：已知种类命中，未知/哨兵/空 entryKey 返 null 不抛', () {
      expect(
        MediaRef.tryParse('epub', 'bookKey'),
        const MediaRef(kind: MediaKind.epub, entryKey: 'bookKey'),
      );
      expect(MediaRef.tryParse('srt', 'uid-1'),
          const MediaRef(kind: MediaKind.srt, entryKey: 'uid-1'));
      // 未知种类（对端未来值 / 其它值域的串）→ null，调用方保留裸串透传。
      expect(MediaRef.tryParse('book', 'k'), isNull);
      expect(MediaRef.tryParse('', 'k'), isNull, reason: "'' 合集墓碑哨兵");
      expect(MediaRef.tryParse(null, 'k'), isNull);
      expect(MediaRef.tryParse('epub', null), isNull);
      expect(MediaRef.tryParse('epub', ''), isNull);
    });
  });

  group('既有身份类型委托 MediaRef（对外 API 不变）', () {
    test('ShelfEntryRef：字段/相等性/toString 与旧实现一致，ref 可取', () {
      const ShelfEntryRef ref =
          ShelfEntryRef(mediaType: MediaKind.epub, entryKey: 'k');
      expect(ref.mediaType, MediaKind.epub);
      expect(ref.entryKey, 'k');
      expect(ref.ref, const MediaRef(kind: MediaKind.epub, entryKey: 'k'));
      expect(
          ref, const ShelfEntryRef(mediaType: MediaKind.epub, entryKey: 'k'));
      expect(
        ref,
        isNot(const ShelfEntryRef(mediaType: MediaKind.srt, entryKey: 'k')),
      );
      expect(ref.toString(), 'ShelfEntryRef(MediaKind.epub, k)');
    });

    test('CollectionOrderingItem：字段委托 + 复合键经 ref 生成', () {
      const CollectionOrderingItem<String> it = CollectionOrderingItem<String>(
        mediaType: MediaKind.video,
        entryKey: 'v1',
        importedAt: 7,
        payload: 'p',
      );
      expect(it.mediaType, MediaKind.video);
      expect(it.entryKey, 'v1');
      expect(it.importedAt, 7);
      expect(it.payload, 'p');
      expect(it.ref.compositeKey, 'video|v1');
    });
  });
}
