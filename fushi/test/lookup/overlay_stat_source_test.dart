import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/overlay_stat_source.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// app 外查词 / 制卡（瞬态浮窗 + 剪贴板面板）的统计来源判据与跨源收藏一致性。
///
/// 背景：这条链路不经页面、拿不到书 / 视频上下文，此前四类计数（查词 / 制卡 /
/// 收藏词 / 收藏句）一律硬写 `kStatSourceBook`——galgame hook 会话里学到的东西
/// 全堆进「阅读」tab，「游戏」tab 只剩游玩次数一行。
void main() {
  const String today = '2026-09-10';

  group('来源判据（两个值域各一个包装器，判据只有一份）', () {
    test('统计来源值域：有归属会话 → game，没有 → book', () {
      expect(statSourceTypeForGameKey('D:\\games\\x.exe'), kStatSourceGame);
      expect(statSourceTypeForGameKey(null), kStatSourceBook);
    });

    test('收藏句 / 制卡句值域：同一判据，取那一列自己的常量', () {
      expect(
        minedSentenceSourceForGameKey('D:\\games\\x.exe'),
        kFavoriteSentenceSourceGame,
      );
      expect(minedSentenceSourceForGameKey(null), kFavoriteSentenceSourceBook);
    });

    test('空串等同 null（无稳定 id 的会话不算游戏域）', () {
      // `_beginActivitySession` 已把空 mediaKey 归一成 null，这里是第二道门：
      // 空串落进 source_type 会造出一个既不是 book 也不是 game 的幽灵桶。
      expect(statSourceTypeForGameKey(''), kStatSourceBook);
      expect(minedSentenceSourceForGameKey(''), kFavoriteSentenceSourceBook);
    });

    test('两个值域的三个落库串逐字节稳定（永不改变）', () {
      expect(kStatSourceBook, 'book');
      expect(kStatSourceVideo, 'video');
      expect(kStatSourceGame, 'game');
      expect(kFavoriteSentenceSourceBook, 'book');
      expect(kFavoriteSentenceSourceVideo, 'video');
      expect(kFavoriteSentenceSourceGame, 'game');
    });

    test('单例包装器：没有在跑的会话时两个值域都返 book', () {
      // 包装器读的是 GalHookSessionController.instance（static final，构造时会挂
      // Texthooker 监听），单测里没有在跑的 galgame 会话 → activityGameKey 恒 null。
      // 这一条同时证明包装器在 headless 下可调用不抛——它跑在查词/制卡的旁路埋点
      // 里，抛了会被上层 catch 吞成「收藏失败」。game 态由上面的纯判据覆盖。
      TestWidgetsFlutterBinding.ensureInitialized();
      expect(overlayStatSourceType(), kStatSourceBook);
      expect(overlayMinedSentenceSource(), kFavoriteSentenceSourceBook);
    });

    test('单例包装器只是「读 activityGameKey + 委托纯判据」的一行', () {
      // 行为由纯判据钉死；这里钉住「包装器没有第二份判据」这一结构事实。
      final String src =
          File('lib/src/lookup/overlay_stat_source.dart').readAsStringSync();
      expect(
        src,
        contains('statSourceTypeForGameKey('),
        reason: 'overlayStatSourceType 必须委托纯判据，不得自己再写一遍',
      );
      expect(
        src,
        contains('minedSentenceSourceForGameKey('),
        reason: 'overlayMinedSentenceSource 必须委托纯判据',
      );
      expect(
        src,
        contains('GalHookSessionController.instance.activityGameKey'),
        reason: '判据的唯一输入是会话控制器的 activityGameKey',
      );
    });

    test('已知限制：SentenceSourceKind 还没有 game，宽松解析回退 book', () {
      // 加枚举值会让 collections_page 的四处穷尽 switch 编译不过（图标 / 标签 /
      // 跳转模块都要补 game 分支）。在补齐之前，游戏来源的制卡句在收藏夹里按书
      // 展示——那些行本来就无定位锚点、不可跳转，行为无退化。统计分桶**不**经这
      // 个枚举（走 StatSourceKind + 字符串比较），故三域之和的恒等式不受影响。
      expect(SentenceSourceKind.tryParse(kFavoriteSentenceSourceGame), isNull);
      expect(
        sentenceSourceKindOf(kFavoriteSentenceSourceGame),
        SentenceSourceKind.book,
      );
    });

    test('会话控制器暴露了只读 activityGameKey（判据的唯一输入）', () {
      final String src = File('lib/src/mining/gal_hook_session_controller.dart')
          .readAsStringSync();
      expect(src, contains('String? get activityGameKey => _activityGameKey;'));
    });
  });

  group('跨源 ★ 一致性（judge 跨源 / 删跨源 / 写单源）', () {
    late FushiDatabase db;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
    });

    Future<bool> check() => overlayToggleOrCheckFavoriteWord(
          db: db,
          toggle: false,
          expression: 'あ',
          reading: 'あ',
          addSourceType: kStatSourceBook,
          dateKey: today,
        );

    Future<bool> toggle(String addSourceType) =>
        overlayToggleOrCheckFavoriteWord(
          db: db,
          toggle: true,
          expression: 'あ',
          reading: 'あ',
          addSourceType: addSourceType,
          dateKey: today,
        );

    test('未收藏 → check false，toggle 写当前源一行', () async {
      expect(await check(), isFalse);
      expect(await toggle(kStatSourceGame), isTrue);
      final List<FavoriteWordRow> rows = await db.getAllFavoriteWords();
      expect(rows, hasLength(1), reason: '只写当前源，绝不两源各一行（那才是重复计数）');
      expect(rows.single.sourceType, kStatSourceGame);
    });

    test('① 书里收藏过 → 游戏会话里 check 也是已收藏（★ 不随会话闪）', () async {
      await db.addFavoriteWord(
        expression: 'あ',
        reading: 'あ',
        glossary: '',
        sourceType: kStatSourceBook,
        dateKey: today,
      );
      expect(await check(), isTrue);
    });

    test('② 取消收藏把两个源里存在的都删掉（不留孤儿行）', () async {
      for (final String s in <String>[kStatSourceBook, kStatSourceGame]) {
        await db.addFavoriteWord(
          expression: 'あ',
          reading: 'あ',
          glossary: '',
          sourceType: s,
          dateKey: today,
        );
      }
      expect(await db.getAllFavoriteWords(), hasLength(2));
      expect(await toggle(kStatSourceGame), isFalse);
      expect(await db.getAllFavoriteWords(), isEmpty,
          reason: '只删当前源会剩一行孤儿：★ 灭了，收藏夹里还在，统计还计着');
      expect(await check(), isFalse);
    });

    test('③ 已在 book 源时再 toggle 是取消，不是在 game 源补一行', () async {
      await db.addFavoriteWord(
        expression: 'あ',
        reading: 'あ',
        glossary: '',
        sourceType: kStatSourceBook,
        dateKey: today,
      );
      expect(await toggle(kStatSourceGame), isFalse);
      expect(await db.getAllFavoriteWords(), isEmpty);
    });

    test('★ 一轮 toggle 往返回到零行（book 源下与加 game 源之前逐字节同行为）', () async {
      expect(await toggle(kStatSourceBook), isTrue);
      expect(await check(), isTrue);
      expect(await toggle(kStatSourceBook), isFalse);
      expect(await check(), isFalse);
      expect(await db.getAllFavoriteWords(), isEmpty);
    });

    test('不同词条互不干扰（跨源判定不是全表判定）', () async {
      await toggle(kStatSourceGame);
      expect(
        await overlayToggleOrCheckFavoriteWord(
          db: db,
          toggle: false,
          expression: 'い',
          reading: 'い',
          addSourceType: kStatSourceBook,
          dateKey: today,
        ),
        isFalse,
      );
    });
  });
}
