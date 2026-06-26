import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

/// TODO-843：`{video-clip}` 占位符守卫。
///
/// `{video-clip}` 是 `{book-cover}` 的语义别名（视频场景下 coverPath 本就是 GIF），
/// 让用户能给视频卡用语义清晰的字段名而不必借用 `{book-cover}`。两者读同一个
/// `context.coverPath`，渲染结果必须逐字节相同——这正是「媒体嵌入零改动」的基础：
/// 两 backend 都把 coverPath 落盘成媒体引用后塞回同一个 coverPath 字段再渲染。
void main() {
  const AnkiMiningPayload payload = AnkiMiningPayload(expression: '言葉');

  AnkiMiningContext contextWithCover(String? cover) => AnkiMiningContext(
        sentence: 'これは言葉です。',
        coverPath: cover,
      );

  group('AnkiHandlebarRenderer {video-clip}', () {
    test('renders context.coverPath', () {
      final String value = AnkiHandlebarRenderer.render(
        '{video-clip}',
        payload,
        contextWithCover('clip.gif'),
      );
      expect(value, 'clip.gif');
    });

    test('{video-clip} 与 {book-cover} 同 context 渲染逐字节相同', () {
      final AnkiMiningContext ctx = contextWithCover('hibiki_cover_x.gif');
      final String clip =
          AnkiHandlebarRenderer.render('{video-clip}', payload, ctx);
      final String cover =
          AnkiHandlebarRenderer.render('{book-cover}', payload, ctx);
      expect(clip, cover);
    });

    test('coverPath 为 null 时两者都渲染空串', () {
      final AnkiMiningContext ctx = contextWithCover(null);
      expect(AnkiHandlebarRenderer.render('{video-clip}', payload, ctx), '');
      expect(AnkiHandlebarRenderer.render('{book-cover}', payload, ctx), '');
    });

    test('两者都渲染媒体引用串（模拟 backend 落盘后回填）逐字节相同', () {
      // backend 把 coverPath 落盘后用 `<img src="ref">` 覆盖 coverPath 再渲染。
      const String mediaRef = '<img src="hibiki_cover_abc.gif">';
      final AnkiMiningContext ctx = contextWithCover(mediaRef);
      expect(
          AnkiHandlebarRenderer.render('{video-clip}', payload, ctx), mediaRef);
      expect(
        AnkiHandlebarRenderer.render('{video-clip}', payload, ctx),
        AnkiHandlebarRenderer.render('{book-cover}', payload, ctx),
      );
    });
  });

  group('AnkiHandlebarOptions.coreOptions', () {
    test('含 {video-clip} 且仍含 {book-cover}（防回归删除）', () {
      expect(AnkiHandlebarOptions.coreOptions, contains('{video-clip}'));
      expect(AnkiHandlebarOptions.coreOptions, contains('{book-cover}'));
    });

    test('forTermDictionaries 保留 video-clip', () {
      final List<String> options =
          AnkiHandlebarOptions.forTermDictionaries(<String>['広辞苑']);
      expect(options, contains('{video-clip}'));
      expect(options, contains('{single-glossary-広辞苑}'));
    });
  });
}
