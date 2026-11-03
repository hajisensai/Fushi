/// 牌组的「自定义学习」流程（Anki Custom Study）：弹 [showSrsCustomStudyDialog]，提升今日上限后照常复习，
/// 或开一个临时会话（[SrsCustomStudy]）。本机牌组列表与远程复习的牌组列表共用，复习库取当前作用域的
/// `srsStoreProvider`（远程复习时是主机上的库）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/srs/srs_custom_study_dialog.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/utils.dart';

/// 对 [deck] 走一遍自定义学习；[openReview] 打开复习页（[custom] 为 null = 普通复习）。
Future<void> srsRunCustomStudy(
  BuildContext context,
  WidgetRef ref,
  SrsDeckSummary deck, {
  required Future<void> Function(SrsCustomStudy? custom) openReview,
}) async {
  final SrsDbStore? store = await readSrsStore(ref);
  if (store == null || !context.mounted) return;
  final SrsDayContext day = await store.dayContext();
  final int today = day.dayIndexOf(store.now().$1);
  if (!context.mounted) return;
  final SrsCustomStudyChoice? choice = await showSrsCustomStudyDialog(
    context: context,
    deckName: deck.fullName,
    todayExtension:
        deck.deck.limitExtension?.on(today) ?? (newCards: 0, reviews: 0),
  );
  if (choice == null || !context.mounted) return;
  if (choice.isExtension) {
    final ({int newCards, int reviews}) total = await store.extendTodayLimits(
      deck.deck.id,
      newCards: choice.extendNew,
      reviews: choice.extendReviews,
    );
    if (!context.mounted) return;
    bumpSrsRevision(ref);
    FushiToast.show(
      msg: t.srs_custom_study_extended(
        newCards: total.newCards,
        reviews: total.reviews,
      ),
      severity: ToastSeverity.success,
    );
    await openReview(null);
    return;
  }
  await openReview(choice.sessionAt(store.now().$1));
}
