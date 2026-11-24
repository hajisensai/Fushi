import 'package:fushi_audio/fushi_audio.dart' show kFavoriteSentenceSourceWeb;

import 'package:fushi/src/media/privacy/media_visibility.dart';

/// 收藏 / 制卡行的来源作品上锁（本次会话未解锁）时不出现（[MediaVisibility.hidesWork]，
/// 唯一的上锁过滤入口）。网页收藏的 bookKey 是网址，不是作品身份。收藏夹与首页
/// 「收藏句子」小组件共用这一判据。
///
/// 单独成文件（不放在收藏夹页里）：首页小组件只要这一个判据，import 收藏夹页会把
/// 它连同整个 app 依赖闭包拖进 import 大环（`import_cycle_guard_test`）。
bool favoriteHiddenByLock(
  MediaVisibility visibility, {
  required String? bookKey,
  required String? title,
  required String source,
}) => visibility.hidesWork(
  key: source == kFavoriteSentenceSourceWeb ? null : bookKey,
  title: title ?? '',
);
