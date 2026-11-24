import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show shelfReadPercent;

/// 书 / 漫画卡面的阅读状态文案：已读完 / 未读 / 百分比。书架卡、库页「继续
/// 阅读」、导航速览、首页「继续」卡共用这一份（比例由 `shelfReadFraction` 算，
/// 百分比数字由 [shelfReadPercent] 定），同一本书在各处写法一致。
String bookReadProgressLabel(double fraction, {bool completed = false}) {
  if (completed || fraction >= 1) return t.shelf_filter_read_status_finished;
  final int? percent = shelfReadPercent(fraction);
  if (percent == null) return t.shelf_filter_read_status_unread;
  return '$percent%';
}
