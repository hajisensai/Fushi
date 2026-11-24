/// 「打开系列卡详情页」的签名（追踪对话框 / 追踪页的「系列卡」按钮用）。
///
/// 只放类型、不放实现：实现 `trackingSeriesCardOpener`
/// （`tracking_series_card_open.dart`）要读 AppModel 取书目与模块开关，由已经持有
/// AppModel 的调用方传进 `BookTrackingDialog` / `TrackingPage`。追踪 UI 只依赖这个
/// 签名，不会因为默认实现把 AppModel 拖进自己的 import 闭包（import_cycle_guard_test，
/// 2026-11-24 develop 627）。
library;

import 'package:material_ui/material_ui.dart';

/// Opens a series card's detail page, where its series links and the way
/// each volume counts are managed ("Tracking" section). [bookKey] is any
/// volume of the card: it tells the Books tab from the Manga tab.
typedef TrackingSeriesCardOpener =
    Future<void> Function(
      BuildContext context,
      int collectionId,
      String bookKey,
    );
