import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_core/fushi_core.dart';

/// 「只在其它设备上」的合集（BUG-5597）：成员行都在、本机一条都没有
/// （[FushiDatabase.getCollectionsWithoutLocalMembers]）。删掉它会经合集同步一并删掉
/// 其它设备上的这个合集，本机也没有成员本体可连带删。
///
/// 删除确认的唯一判据与文案：库页合集菜单（`collection_context_dialog.dart`）与两个
/// 合集详情页（`collection_detail_shared.dart`）都走这里，不各写一份。纯判据 / 文案
/// 层，与设计系统无关。
Future<bool> isCollectionRemoteOnly(FushiDatabase db, int collectionId) async =>
    (await db.getCollectionsWithoutLocalMembers(
      collectionIds: <int>[collectionId],
    )).containsKey(collectionId);

/// 删除合集确认框正文：只在其它设备上的合集追加「会经同步一并删除其它设备上的
/// 这个合集」。
String collectionDeleteConfirmMessage({required bool remoteOnly}) => remoteOnly
    ? '${t.delete_collection_confirm}\n\n'
          '${t.delete_collection_remote_only_warning}'
    : t.delete_collection_confirm;
