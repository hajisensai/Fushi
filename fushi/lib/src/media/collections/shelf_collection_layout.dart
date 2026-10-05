/// 书架里合集的呈现方式（偏好 `shelf_collection_layout`，存 `.name`）。
///
/// - [rows]（默认，现状零变化）：每个合集一条全宽横排行（行头 + 横滚成员卡），
///   集中排在散书网格**之前**；
/// - [cards]：每个合集折成网格里的**一个格子**（堆叠封面卡，与视频库「系列」卡同一
///   套 `ShelfCoverFrame` 叠层），与散书**同一个网格、同一套排序**——合集取成员的
///   代表值参与排序（最近阅读 / 导入时间取成员最大值、名称取合集名，见
///   `_shelfGroupSortKey`），不再固定排在前面。合集多了以后横排行会把散书挤到很
///   下面（用户实报「好难划到下面的书」），这一档就是给它的答案。
enum ShelfCollectionLayout {
  rows,
  cards;

  /// 从持久化 `.name` 解析；未知值（含旧版本残留）退默认 [rows]。
  static ShelfCollectionLayout fromName(String name) => values.firstWhere(
        (ShelfCollectionLayout m) => m.name == name,
        orElse: () => ShelfCollectionLayout.cards,
      );
}
