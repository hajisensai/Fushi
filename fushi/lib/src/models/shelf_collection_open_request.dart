import 'package:flutter/foundation.dart';

/// 「请书架 / 漫画库打开某个合集的详情页」的一次请求（首页「最近添加」系列合并卡
/// 点开时发，设计稿 H8）。
///
/// 为什么走请求而不是首页自己 push 详情页：书合集详情页
/// （`MediaCollectionGridDetailPage`）的成员卡、成员菜单、进度 / 读完、删除连同
/// 成员等回调全长在书架页（`ReaderFushiHistoryPage`）的状态里，首页另拼一份就是
/// 第二套成员渲染。首页只切到对应 tab 并发请求，由书架页用它唯一的
/// `_openCollectionDetail` 打开——与在书架上点合集卡同一个出口。
@immutable
class ShelfCollectionOpenRequest {
  const ShelfCollectionOpenRequest({
    required this.collectionId,
    required this.manga,
  });

  /// 要打开的合集 id（`media_collections.id`）。
  final int collectionId;

  /// true = 漫画库实例（`mangaOnly`）接单；false = 书架实例接单。
  final bool manga;

  @override
  bool operator ==(Object other) =>
      other is ShelfCollectionOpenRequest &&
      other.collectionId == collectionId &&
      other.manga == manga;

  @override
  int get hashCode => Object.hash(collectionId, manga);
}

/// 待处理的打开请求；null = 没有。书架 / 漫画库页订阅它，并在首次构建后检查一次
/// （tab 懒构建时请求先于页面存在）。
final ValueNotifier<ShelfCollectionOpenRequest?> shelfCollectionOpenRequest =
    ValueNotifier<ShelfCollectionOpenRequest?>(null);

/// 发一次打开请求（覆盖尚未被接走的旧请求——只有最后一次点击算数）。
void requestShelfCollectionOpen({
  required int collectionId,
  required bool manga,
}) {
  shelfCollectionOpenRequest.value = ShelfCollectionOpenRequest(
    collectionId: collectionId,
    manga: manga,
  );
}

/// 书架 / 漫画库实例接单：待处理请求属于本实例（[manga] 与之相符）时取走并清空，
/// 返回合集 id；否则不动、返回 null（留给另一个实例）。
int? takeShelfCollectionOpenRequest({required bool manga}) {
  final ShelfCollectionOpenRequest? request = shelfCollectionOpenRequest.value;
  if (request == null || request.manga != manga) return null;
  shelfCollectionOpenRequest.value = null;
  return request.collectionId;
}
