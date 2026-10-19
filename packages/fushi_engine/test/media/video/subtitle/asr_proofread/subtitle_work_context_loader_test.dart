import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_work_context_loader.dart';
import 'package:test/test.dart';

void main() {
  late FushiDatabase db;
  late SubtitleWorkContextLoader loader;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    loader = SubtitleWorkContextLoader(db);
  });
  tearDown(() => db.close());

  Future<void> addVideo(String uid, String path, {String? title}) =>
      db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value<String>(uid),
          title: Value<String>(title ?? uid),
          videoPath: Value<String>(path),
        ),
      );

  Future<int> addCollection(String name, {String type = 'collection'}) => db
      .into(db.mediaCollections)
      .insert(
        MediaCollectionsCompanion.insert(
          name: name,
          createdAt: 1,
          collectionType: Value<String>(type),
        ),
      );

  Future<void> addMember(int collectionId, String uid) => db
      .into(db.mediaCollectionItems)
      .insert(
        MediaCollectionItemsCompanion.insert(
          collectionId: collectionId,
          mediaType: 'video',
          entryKey: uid,
        ),
      );

  Future<int> addWork({
    int? collectionId,
    String? bookUid,
    required String title,
    String? originalTitle,
  }) => db
      .into(db.videoMetadataWorks)
      .insert(
        VideoMetadataWorksCompanion.insert(
          collectionId: Value<int?>(collectionId),
          bookUid: Value<String?>(bookUid),
          mediaType: 'tv',
          title: title,
          originalTitle: Value<String?>(originalTitle),
          updatedAt: 1,
        ),
      );

  Future<void> addVoiceCredit(
    int workId, {
    required String characterKey,
    required String characterName,
    String? characterKanji,
    required String personKey,
    required String personName,
    String? personKanji,
    String kind = 'voice_actor',
    String? language = 'ja',
    required int order,
  }) async {
    await db.upsertVideoMetadataPeople(<VideoMetadataPeopleCompanion>[
      VideoMetadataPeopleCompanion.insert(
        personKey: personKey,
        name: personName,
        originalName: Value<String?>(personKanji),
        updatedAt: 1,
      ),
    ]);
    await db.upsertVideoMetadataCharacters(<VideoMetadataCharactersCompanion>[
      VideoMetadataCharactersCompanion.insert(
        characterKey: characterKey,
        name: characterName,
        originalName: Value<String?>(characterKanji),
        updatedAt: 1,
      ),
    ]);
    await db
        .into(db.videoMetadataCredits)
        .insert(
          VideoMetadataCreditsCompanion.insert(
            workId: Value<int?>(workId),
            personKey: personKey,
            characterKey: Value<String?>(characterKey),
            creditKind: kind,
            roleName: Value<String>(characterName),
            language: Value<String?>(language),
            sortOrder: Value<int>(order),
          ),
        );
  }

  Future<void> addAnidbIdentity(
    String path, {
    required String kanji,
    required int updatedAt,
    String ed2k = '0123456789abcdef0123456789abcdef',
  }) => db.upsertAnidbFileIdentity(
    AnidbFileIdentitiesCompanion.insert(
      ed2k: ed2k,
      fileSize: 100,
      kanjiTitle: Value<String>(kanji),
      filePath: Value<String?>(path),
      resolvedAt: updatedAt,
      updatedAt: updatedAt,
    ),
  );

  group('fallbackSubtitleWorkKey', () {
    test('目录优先，同一目录不同写法得同一键', () {
      final String a = fallbackSubtitleWorkKey(
        folderPath: r'D:\Anime\K-On\',
        title: 'x',
      );
      final String b = fallbackSubtitleWorkKey(
        folderPath: 'D:/Anime/./K-On',
        title: 'y',
      );
      expect(a, startsWith('folder:'));
      expect(a, b);
      expect(
        fallbackSubtitleWorkKey(folderPath: 'D:/Anime/K-On 2', title: 'x'),
        isNot(a),
      );
    });

    test('没有目录用标题（空白与大小写归一）', () {
      final String a = fallbackSubtitleWorkKey(title: '  K-On!  Season 1 ');
      expect(a, startsWith('title:'));
      expect(
        fallbackSubtitleWorkKey(folderPath: ' ', title: 'k-on! season 1'),
        a,
      );
    });

    test('标题为空且无目录直接报错，不造一个所有无名视频共用的键', () {
      expect(
        () => fallbackSubtitleWorkKey(title: '   '),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  test('合集：键、作品原名、AniDB 汉字标题与角色（日文名 / 日语声优）', () async {
    await addVideo('ep1', '/lib/kon/01.mkv');
    await addVideo('ep2', '/lib/kon/02.mkv');
    final int c = await addCollection('K-On! folder');
    await addMember(c, 'ep1');
    await addMember(c, 'ep2');
    final int work = await addWork(
      collectionId: c,
      title: 'K-On!',
      originalTitle: 'けいおん!',
    );
    await addVoiceCredit(
      work,
      characterKey: 'character:mal:8',
      characterName: 'Akiyama, Mio',
      characterKanji: '秋山 澪',
      personKey: 'person:mal:2',
      personName: 'Hikasa, Youko',
      order: 1,
    );
    await addVoiceCredit(
      work,
      characterKey: 'character:mal:7',
      characterName: 'Hirasawa, Yui',
      characterKanji: '平沢 唯',
      personKey: 'person:mal:1',
      personName: 'Toyosaki, Aki',
      personKanji: '豊崎愛生',
      order: 0,
    );
    // 另一个 provider 的同名角色（写法只差标点）：并成一个，只补空。
    await addVoiceCredit(
      work,
      characterKey: 'character:anidb:7',
      characterName: 'Hirasawa Yui',
      personKey: 'person:anidb:1',
      personName: 'Toyosaki Aki',
      order: 2,
    );
    // 英语配音不算日语声优。
    await addVoiceCredit(
      work,
      characterKey: 'character:mal:9',
      characterName: 'Kotobuki, Tsumugi',
      personKey: 'person:mal:3',
      personName: 'Dub Actor',
      language: 'en',
      order: 3,
    );
    await addAnidbIdentity('/lib/kon/01.mkv', kanji: '旧标题', updatedAt: 1);
    await addAnidbIdentity(
      '/lib/kon/02.mkv',
      kanji: 'けいおん!',
      updatedAt: 5,
      ed2k: 'fedcba9876543210fedcba9876543210',
    );

    final SubtitleWorkContext ctx = (await loader.forCollection(c))!;
    expect(ctx.workKey, 'collection:$c');
    expect(ctx.title, 'K-On!');
    expect(ctx.originalTitle, 'けいおん!');
    expect(ctx.kanjiTitle, 'けいおん!', reason: '成员里最近一次 AniDB 识别');
    expect(ctx.hasScrapedData, isTrue);
    expect(
      ctx.characters.map((SubtitleWorkCharacter c) => c.toJson()).toList(),
      <Map<String, Object?>>[
        <String, Object?>{
          'name': 'Hirasawa, Yui',
          'originalName': '平沢 唯',
          'voiceActor': '豊崎愛生',
        },
        <String, Object?>{
          'name': 'Akiyama, Mio',
          'originalName': '秋山 澪',
          'voiceActor': 'Hikasa, Youko',
        },
        <String, Object?>{'name': 'Kotobuki, Tsumugi'},
      ],
    );

    // 从这一集进来拿到同一个键（与合集页共用一张表）。
    expect((await loader.forBook('ep2'))!.workKey, 'collection:$c');
    expect(
      (await loader.forVideoPath('/lib/kon/02.mkv'))!.workKey,
      'collection:$c',
    );
  });

  test('单成员合集按单集刮（作品行挂在那一集上）：仍取合集键', () async {
    await addVideo('ep1', '/lib/show/01.mkv');
    final int c = await addCollection('Show');
    await addMember(c, 'ep1');
    await addWork(bookUid: 'ep1', title: 'Show', originalTitle: 'ショー');

    final SubtitleWorkContext viaBook = (await loader.forBook('ep1'))!;
    final SubtitleWorkContext viaCollection = (await loader.forCollection(c))!;
    expect(viaBook.workKey, 'collection:$c');
    expect(viaCollection.workKey, viaBook.workKey);
    expect(viaBook.originalTitle, 'ショー');
  });

  test('独立视频自己挂作品行：work:<id>；播放列表不算作品归属', () async {
    await addVideo('movie', '/lib/movie.mkv', title: 'file title');
    final int playlist = await addCollection('Mix', type: 'playlist');
    await addMember(playlist, 'movie');
    final int work = await addWork(bookUid: 'movie', title: 'Movie');
    await addAnidbIdentity('/lib/movie.mkv', kanji: '映画', updatedAt: 1);

    final SubtitleWorkContext ctx = (await loader.forBook('movie'))!;
    expect(ctx.workKey, 'work:$work');
    expect(ctx.title, 'Movie');
    expect(ctx.kanjiTitle, '映画');
  });

  test('没刮削：在合集里取合集键（无刮削数据），不在任何合集里返回 null', () async {
    await addVideo('a', '/lib/a/01.mkv');
    await addVideo('b', '/lib/b.mkv');
    final int c = await addCollection('Folder A');
    await addMember(c, 'a');

    final SubtitleWorkContext ctx = (await loader.forBook('a'))!;
    expect(ctx.workKey, 'collection:$c');
    expect(ctx.title, 'Folder A');
    expect(ctx.hasScrapedData, isFalse);
    expect(await loader.forBook('b'), isNull);
  });

  test('不存在的视频 / 路径 / 合集返回 null', () async {
    expect(await loader.forBook('missing'), isNull);
    expect(await loader.forVideoPath('/nowhere.mkv'), isNull);
    expect(await loader.forCollection(404), isNull);
  });
}
