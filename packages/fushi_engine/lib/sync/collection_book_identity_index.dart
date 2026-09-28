import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/game_identity_index.dart';

/// 合集专用双向身份索引；不改变阅读器的本地 bookKey 契约。
///
/// 书（epub）走 uid ↔ wire bookKey；游戏（game）走本机 `galgames.id` ↔ 游戏跨端
/// 身份（[GameIdentityIndex]），否则两台电脑各自入库的同一款游戏在合集里永远
/// 对不上号。srt / video 的键本就跨端稳定，原样透传。
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
  /// 条目也要替对端转发归属）。
  String localKey(String mediaType, String key) {
    if (mediaType == MediaKind.epub.dbValue) return uidByKey[key] ?? key;
    if (mediaType == MediaKind.game.dbValue) {
      return games.resolve(<String>[key]) ?? key;
    }
    return key;
  }

  String wireKey(String mediaType, String key) {
    if (mediaType == MediaKind.epub.dbValue) return wireKeyByKey[key] ?? key;
    if (mediaType == MediaKind.game.dbValue) {
      return games.wireIdentity(key).key;
    }
    return key;
  }

  /// wire 书键 → 本地 bookKey（标签宿主键）；本机没有这本书返回 null。
  String? localBookKey(String wireKey) {
    final String? uid = uidByKey[wireKey];
    if (uid != null) return bookKeyByUid[uid];
    // 本机书的 bookKey 本身就是 wire 键时 uidByKey 也有它；兜底认裸 uid。
    return bookKeyByUid[wireKey];
  }
}
