import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 只为调到 `@protected` 的 [BaseAnkiRepository.buildNoteTags]。
class _TagRepository extends BaseAnkiRepository {
  List<String> tags(
    String userTags, {
    AnkiMiningSource? source,
    bool includeCategory = true,
    bool nest = false,
    String? titleTag,
    String? collectionTag,
    String? charPositionTag,
  }) => buildNoteTags(
    userTags,
    source: source,
    includeHibiki: false,
    includeCategory: includeCategory,
    nestTitleUnderCategory: nest,
    titleTag: titleTag,
    collectionTag: collectionTag,
    charPositionTag: charPositionTag,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final _TagRepository repo = _TagRepository();

  group('作品名标签挂在分类下（反馈 m0GUNdWK4U）', () {
    test('默认关：作品名仍是平级标签（现有用户行为不变）', () {
      expect(
        repo.tags('jp', source: AnkiMiningSource.video, titleTag: 'My Show'),
        <String>['jp', 'video', 'My_Show'],
      );
    });

    test('开启：书名 / 番名 / 游戏名 / 音乐都输出 <分类>::<作品名>', () {
      expect(
        repo.tags(
          '',
          source: AnkiMiningSource.video,
          nest: true,
          titleTag: 'My Show',
          collectionTag: 'Season 1',
        ),
        <String>['video', 'video::My_Show', 'video::Season_1'],
      );
      expect(
        repo.tags('', source: AnkiMiningSource.book, nest: true, titleTag: 'B'),
        <String>['book', 'book::B'],
      );
      expect(
        repo.tags('', source: AnkiMiningSource.game, nest: true, titleTag: 'G'),
        <String>['game', 'game::G'],
      );
      expect(
        repo.tags(
          '',
          source: AnkiMiningSource.music,
          nest: true,
          titleTag: 'Song',
        ),
        <String>['music', 'music::Song'],
      );
    });

    test('开启但关掉单独的分类标签：只剩层级标签', () {
      expect(
        repo.tags(
          '',
          source: AnkiMiningSource.video,
          includeCategory: false,
          nest: true,
          titleTag: 'My Show',
        ),
        <String>['video::My_Show'],
      );
    });

    test('没有来源分类时照旧输出平级作品名；字符位置标签不嵌套', () {
      expect(repo.tags('', nest: true, titleTag: 'Free'), <String>['Free']);
      expect(
        repo.tags(
          '',
          source: AnkiMiningSource.book,
          nest: true,
          titleTag: 'B',
          charPositionTag: 'chars_10',
        ),
        <String>['book', 'book::B', 'chars_10'],
      );
    });

    test('书名与合集名相同时去重合并', () {
      expect(
        repo.tags(
          '',
          source: AnkiMiningSource.video,
          nest: true,
          titleTag: 'Same',
          collectionTag: 'Same',
        ),
        <String>['video', 'video::Same'],
      );
    });
  });

  test('设置 JSON 往返保留开关，旧数据缺键时为关', () {
    const AnkiSettings on = AnkiSettings(tagNestTitleUnderCategory: true);
    expect(
      AnkiSettings.fromJson(on.toJson()).tagNestTitleUnderCategory,
      isTrue,
    );
    expect(
      AnkiSettings.fromJson(<String, dynamic>{}).tagNestTitleUnderCategory,
      isFalse,
    );
  });
}
