import 'package:fushi_core/fushi_core.dart';

/// 合集专用双向身份索引；不改变阅读器的本地 bookKey 契约。
class CollectionBookIdentityIndex {
  CollectionBookIdentityIndex._(this.uidByKey, this.wireKeyByKey);

  final Map<String, String> uidByKey;
  final Map<String, String> wireKeyByKey;

  static Future<CollectionBookIdentityIndex> load(FushiDatabase db) async {
    final List<EpubBookRow> books = await db.getAllEpubBooks();
    final Map<String, String> aliases = await db.getCollectionBookAliases();
    final Map<String, String> remoteByUid = <String, String>{
      for (final MapEntry<String, String> alias in aliases.entries)
        alias.value: alias.key,
    };
    final Map<String, String> uidByKey = <String, String>{};
    final Map<String, String> wireKeyByKey = <String, String>{};
    for (final EpubBookRow book in books) {
      if (book.uid.isEmpty) continue;
      final String wireKey =
          remoteByUid[book.uid] ??
          collectionBookWireKey(
            bookKey: book.bookKey,
            sourceMetadata: book.sourceMetadata,
          );
      uidByKey[book.bookKey] = book.uid;
      wireKeyByKey[book.uid] = wireKey;
      wireKeyByKey[book.bookKey] = wireKey;
    }
    // 明确持久关联优先于普通标题键；源描述符负责升级前的在线条目自愈。
    for (final EpubBookRow book in books) {
      if (book.uid.isEmpty) continue;
      uidByKey.putIfAbsent(wireKeyByKey[book.uid]!, () => book.uid);
    }
    uidByKey.addAll(aliases);
    return CollectionBookIdentityIndex._(uidByKey, wireKeyByKey);
  }

  String localKey(String mediaType, String key) =>
      mediaType == MediaKind.epub.dbValue ? uidByKey[key] ?? key : key;

  String wireKey(String mediaType, String key) =>
      mediaType == MediaKind.epub.dbValue ? wireKeyByKey[key] ?? key : key;
}
