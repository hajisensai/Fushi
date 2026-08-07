import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// TODO-1298：通用图片键 `{card-image}` 守卫 + 旧别名向后兼容。
///
/// `{card-image}` 是书籍封面 / 视频 GIF 共用的通用图片占位符（语义中性、名副其实），
/// 取代名不副实的 `{book-cover}` 成为 Lapis `Picture` 字段的默认映射。旧键
/// `{book-cover}` / `{video-clip}` 保留为别名：三者都读同一个 `context.coverPath`，
/// 渲染结果必须逐字节相同——老配置 / 老卡片模板不受影响。
void main() {
  const AnkiMiningPayload payload = AnkiMiningPayload(expression: '言葉');

  AnkiMiningContext contextWithCover(String? cover) => AnkiMiningContext(
        sentence: 'これは言葉です。',
        coverPath: cover,
      );

  group('AnkiHandlebarRenderer {card-image} (TODO-1298)', () {
    test('renders context.coverPath', () {
      final String value = AnkiHandlebarRenderer.render(
        '{card-image}',
        payload,
        contextWithCover('cover.gif'),
      );
      expect(value, 'cover.gif');
    });

    test('{card-image} == {book-cover} == {video-clip} 逐字节相同（向后兼容）', () {
      final AnkiMiningContext ctx = contextWithCover('hibiki_cover_x.gif');
      final String cardImage =
          AnkiHandlebarRenderer.render('{card-image}', payload, ctx);
      final String bookCover =
          AnkiHandlebarRenderer.render('{book-cover}', payload, ctx);
      final String videoClip =
          AnkiHandlebarRenderer.render('{video-clip}', payload, ctx);
      expect(cardImage, bookCover);
      expect(cardImage, videoClip);
    });

    test('coverPath 为 null 时三者都渲染空串', () {
      final AnkiMiningContext ctx = contextWithCover(null);
      expect(AnkiHandlebarRenderer.render('{card-image}', payload, ctx), '');
      expect(AnkiHandlebarRenderer.render('{book-cover}', payload, ctx), '');
      expect(AnkiHandlebarRenderer.render('{video-clip}', payload, ctx), '');
    });

    test('三者都渲染媒体引用串（模拟 backend 落盘后回填）逐字节相同', () {
      // backend 把 coverPath 落盘后用 `<img src="ref">` 覆盖 coverPath 再渲染。
      const String mediaRef = '<img src="hibiki_cover_abc.gif">';
      final AnkiMiningContext ctx = contextWithCover(mediaRef);
      expect(
          AnkiHandlebarRenderer.render('{card-image}', payload, ctx), mediaRef);
      expect(
        AnkiHandlebarRenderer.render('{card-image}', payload, ctx),
        AnkiHandlebarRenderer.render('{book-cover}', payload, ctx),
      );
      expect(
        AnkiHandlebarRenderer.render('{card-image}', payload, ctx),
        AnkiHandlebarRenderer.render('{video-clip}', payload, ctx),
      );
    });
  });

  group('AnkiHandlebarOptions.coreOptions (TODO-1298)', () {
    test('含新键 {card-image} 且仍保留旧别名 {book-cover}/{video-clip}', () {
      expect(AnkiHandlebarOptions.coreOptions, contains('{card-image}'));
      expect(AnkiHandlebarOptions.coreOptions, contains('{book-cover}'));
      expect(AnkiHandlebarOptions.coreOptions, contains('{video-clip}'));
    });

    test('forTermDictionaries 保留 card-image', () {
      final List<String> options =
          AnkiHandlebarOptions.forTermDictionaries(<String>['広辞苑']);
      expect(options, contains('{card-image}'));
    });
  });

  group('LapisNoteType default mapping (TODO-1298)', () {
    test('Picture 默认映射到通用键 {card-image}（不再是名不副实的 book-cover）', () {
      expect(LapisNoteType.defaultFieldMappings['Picture'], '{card-image}');
    });
  });
}
