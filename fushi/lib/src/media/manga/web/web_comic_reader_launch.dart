import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart'
    show MangaFushiSource, MediaItem, ReaderFushiSource;
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/media/manga/web/web_comic_chapter.dart';
import 'package:fushi/src/media/manga/web/web_comic_scan.dart';
import 'package:fushi/src/media/manga/web/web_comic_scanner.dart';
import 'package:fushi/src/media/manga/web/web_comic_site_rule.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';

/// 浏览器上的「用 Fushi 阅读本章」动作是否可用。
///
/// 网页漫画（扫图交给漫画阅读器）属于在线漫画来源，与 Mihon 源同一道 App Store
/// 合规门；app 内浏览器本身不受这道门约束。判据只问
/// [StoreRestrictedCapability.onlineMangaSource]，不写 `Platform.isIOS`。
bool webComicReaderActionAvailable() =>
    StoreRestrictedCapability.onlineMangaSource.isAvailable;

/// 把一次扫图结果入库并打开漫画阅读器（与作品页开阅读器同一条 `openMedia` 路径）。
///
/// 同一作品（站点规则推得出作品身份）在库里已有时，新章并进已有章节表
/// （[mergeWebComicChapters]），阅读器里就能在打开过的章节之间连读。
Future<void> openWebComicScanInReader({
  required BuildContext context,
  required WidgetRef ref,
  required WebComicScanResult scan,
}) async {
  final AppModel appModel = ref.read(appProvider);
  final WebComicRuleSet rules = await WebComicAssets.rules();
  final WebComicSiteRule? rule =
      rules.byId(scan.ruleId) ?? rules.matchChapter(scan.pageUrl);
  OnlineMangaLibraryEntry entry = webComicEntryFromScan(
    scan,
    rule: rule,
    nowMs: DateTime.now().millisecondsSinceEpoch,
    nextLabel: t.manga_web_chapter_next,
    prevLabel: t.manga_web_chapter_prev,
  );
  final String currentKey = scan.pageUrl.toString();
  final OnlineMangaLibraryService service = appModel.onlineMangaLibraryService(
    OnlineMangaRuntimeKind.web,
  );
  final EpubBookRow? existingRow = await service.find(entry);
  final OnlineMangaLibraryEntry? existing = existingRow == null
      ? null
      : OnlineMangaLibraryEntry.tryParse(existingRow.sourceMetadata);
  if (existing != null) {
    entry = entry.copyWith(
      chapters: mergeWebComicChapters(
        existing.chapters,
        entry.chapters,
        currentKey: currentKey,
      ),
    );
  }
  final EpubBookRow row = await service.add(entry);
  final int chapterIndex = entry.chapters.indexWhere(
    (OnlineMangaChapter chapter) => chapter.key == currentKey,
  );
  if (!context.mounted) return;
  final MediaItem? item = await ReaderFushiSource.instance.mediaItemForBookKey(
    row.bookKey,
  );
  if (!context.mounted) return;
  if (item == null) {
    // 刚入库建不出 MediaItem（不该发生）：直接开阅读器，少一层会话副作用也比
    // 「点了没反应」好（与作品页同一兜底）。
    await Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => FushiAppUiScaleNeutralizer(
          child: MangaFushiPage(
            item: null,
            bookKey: row.bookKey,
            initialChapterIndex: chapterIndex < 0 ? null : chapterIndex,
          ),
        ),
      ),
    );
    return;
  }
  await appModel.openMedia(
    ref: ref,
    mediaSource: MangaFushiSource.instance,
    item: item,
    launchPageBuilder: () => MangaFushiSource.instance.buildChapterLaunchPage(
      item: item,
      chapterIndex: chapterIndex < 0 ? null : chapterIndex,
    ),
  );
}
