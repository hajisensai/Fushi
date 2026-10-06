import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_core/fushi_core.dart';

/// 「删合集时连订阅一起删」的订阅快照。
///
/// 必须在弹确认框、删合集**之前**取（[load]）：归属判据里的刮削作品行与任务的
/// `collection_id` 随删合集消失，删完再查恒为空。快照在确认框弹出前定死，确认框
/// 里写的 N 就是真会删掉的订阅数。
class CollectionOwnedSubscriptions {
  const CollectionOwnedSubscriptions(this.subscriptionIds);

  static const CollectionOwnedSubscriptions none = CollectionOwnedSubscriptions(
    <String>[],
  );

  final List<String> subscriptionIds;

  static Future<CollectionOwnedSubscriptions> load(
    FushiDatabase db,
    Iterable<int> collectionIds,
  ) async {
    final List<VideoDownloadSubscriptionRow> rows = await db
        .getVideoDownloadSubscriptionsOwnedByCollections(collectionIds);
    return CollectionOwnedSubscriptions(<String>[
      for (final VideoDownloadSubscriptionRow row in rows) row.subscriptionId,
    ]);
  }

  /// 确认框的勾选行文案；没有归属订阅时为 null（不摆这一行）。
  String? get deleteLabel => subscriptionIds.isEmpty
      ? null
      : t.collection_delete_also_subscriptions(n: subscriptionIds.length);

  Future<int> delete(FushiDatabase db) =>
      db.deleteVideoDownloadSubscriptions(subscriptionIds);
}
