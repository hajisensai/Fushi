import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/game_identity_index.dart';

/// 合集专用双向身份索引；不改变阅读器的本地 bookKey 契约。
///
/// 合集成员只有书（epub）换算：uid ↔ wire bookKey。srt / video 的键本就跨端
/// 稳定，game 成员**维持裸 `galgames.id`**，都原样透传。
///
/// 游戏成员刻意不换成 [GameIdentityIndex] 的跨端身份：合集引擎按 wire 键逐字做
/// 成员并集 / 墓碑裁决，成员不带别名；而跨端身份的主键会随刮削、同名入库漂移
/// （同一款游戏今天发 `title:…`、刮削后发 `vndb:…`），升级前对端存的又是裸
/// id——任何一次换键都会让新旧两键在并集里共存、移出时墓碑只压住其中一个、另
/// 一个下一轮复活。游戏的跨端身份只用于标签清单（[games]，带别名解析）。
class CollectionBookIdentityIndex {
  CollectionBookIdentityIndex._(
    this.uidByKey,
    this.wireKeyByKey, {
    this.bookKeyByUid = const <String, String>{},
    this.games = GameIdentityIndex.empty,
  });

  final Map<String, String> uidByKey;
  final Map<String, String> wireKeyByKey;

  /// 本地书 uid → 本地 bookKey（标签宿主键是 bookKey，不是合集成员用的 uid）。
  final Map<String, String> bookKeyByUid;

  final GameIdentityIndex games;

  static Future<CollectionBookIdentityIndex> load(FushiDatabase db) async {
    final List<EpubBookRow> books = await db.getAllEpubBooks();
    final Map<String, String> aliases = await db.getCollectionBookAliases();
    final Map<String, String> remoteByUid = <String, String>{
      for (final MapEntry<String, String> alias in aliases.entries)
        alias.value: alias.key,
    };
    final Map<String, String> uidByKey = <String, String>{};
    final Map<String, String> wireKeyByKey = <String, String>{};
    final Map<String, String> bookKeyByUid = <String, String>{};
    for (final EpubBookRow book in books) {
      if (book.uid.isEmpty) continue;
      final String wireKey =
          remoteByUid[book.uid] ??
          collectionBookWireKey(
            bookKey: book.bookKey,
            sourceMetadata: book.sourceMetadata,
          );
      uidByKey[book.bookKey] = book.uid;
      bookKeyByUid[book.uid] = book.bookKey;
      wireKeyByKey[book.uid] = wireKey;
      wireKeyByKey[book.bookKey] = wireKey;
    }
    // 明确持久关联优先于普通标题键；源描述符负责升级前的在线条目自愈。
    for (final EpubBookRow book in books) {
      if (book.uid.isEmpty) continue;
      uidByKey.putIfAbsent(wireKeyByKey[book.uid]!, () => book.uid);
    }
    uidByKey.addAll(aliases);
    return CollectionBookIdentityIndex._(
      uidByKey,
      wireKeyByKey,
      bookKeyByUid: bookKeyByUid,
      games: await GameIdentityIndex.load(db),
    );
  }

  /// wire 键 → 本地成员键；对不上照抄透传（合集清单是跨端 union，本机没有的
  /// 条目也要替对端转发归属）。仅 epub 换算，game 等键原样（见类注释）。
  String localKey(String mediaType, String key) =>
      mediaType == MediaKind.epub.dbValue ? uidByKey[key] ?? key : key;

  String wireKey(String mediaType, String key) =>
      mediaType == MediaKind.epub.dbValue ? wireKeyByKey[key] ?? key : key;

  /// wire 书键 → 本地 bookKey（标签宿主键）；本机没有这本书返回 null。
  String? localBookKey(String wireKey) {
    final String? uid = uidByKey[wireKey];
    if (uid != null) return bookKeyByUid[uid];
    // 本机书的 bookKey 本身就是 wire 键时 uidByKey 也有它；兜底认裸 uid。
    return bookKeyByUid[wireKey];
  }
}
