import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_audio/fushi_audio.dart' show Bookmark;
import 'package:fushi_core/fushi_core.dart' show BookFormat, EpubBookRow;
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi_web_core/fushi_web_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/novel/web/web_novel_library.dart';
import 'package:fushi/src/media/novel/web/web_novel_page_fetcher.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show fushiBooksProvider;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/collections_page.dart'
    show buildCollectionReaderMediaItem;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 预览里给用户确认的东西（全是 Rust 提取 / 会话的结论，这里只渲染）。
@immutable
class WebNovelPreview {
  const WebNovelPreview({
    required this.chapterTitle,
    required this.excerpt,
    required this.hasNext,
    this.workTitle,
    this.mergeIntoTitle,
    this.existingChapters = 0,
  });

  final String chapterTitle;
  final String? workTitle;
  final String excerpt;
  final bool hasNext;

  /// 并入书架上已有的书时是它的书名；新书为 null。
  final String? mergeIntoTitle;
  final int existingChapters;
}

/// 预览确认框。返回 true = 用户点了「阅读」。
Future<bool> showWebNovelPreviewDialog(
  BuildContext context,
  WebNovelPreview preview,
) async {
  final bool? confirmed = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => WebNovelPreviewDialog(preview: preview),
  );
  return confirmed ?? false;
}

class WebNovelPreviewDialog extends StatelessWidget {
  const WebNovelPreviewDialog({required this.preview, super.key});

  final WebNovelPreview preview;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final String? mergeInto = preview.mergeIntoTitle;
    final List<Widget> rows = <Widget>[
      Text(
        preview.chapterTitle,
        key: const ValueKey<String>('web-novel-preview-chapter'),
        style: theme.textTheme.titleMedium,
      ),
      if (preview.workTitle != null) Text(preview.workTitle!, style: muted),
      Text(
        preview.excerpt,
        key: const ValueKey<String>('web-novel-preview-excerpt'),
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium,
      ),
      Row(
        children: <Widget>[
          FushiIcon(
            preview.hasNext ? FushiIcons.skipNext : FushiIcons.linkOff,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              preview.hasNext
                  ? t.novel_web_preview_next_found
                  : t.novel_web_preview_next_missing,
              key: const ValueKey<String>('web-novel-preview-next'),
              style: muted,
            ),
          ),
        ],
      ),
      Text(
        mergeInto == null
            ? t.novel_web_preview_new
            : t.novel_web_preview_merge(
                title: mergeInto,
                count: preview.existingChapters,
              ),
        key: const ValueKey<String>('web-novel-preview-target'),
        style: muted,
      ),
    ];
    return FushiAlertDialog(
      icon: const FushiDialogHeroIcon(
        icon: FushiIcons.books,
        tone: FushiHeroTone.primary,
      ),
      title: Text(t.novel_web_preview_title),
      content: SizedBox(
        width: 440,
        child: FushiEntranceScope(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (int i = 0; i < rows.length; i++)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
                  child: FushiStaggeredEntrance(index: i, child: rows[i]),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(t.dialog_cancel),
        ),
        FushiFilledButton(
          key: const ValueKey<String>('web-novel-preview-read'),
          onPressed: () => Navigator.pop(context, true),
          child: Text(t.novel_web_preview_read),
        ),
      ],
    );
  }
}

/// 浏览器当前页 →（Rust 提取 + 并进连载会话）→ 预览确认 → 进书架 → 在阅读器打开。
///
/// - 整页 HTML 一次 `evaluateJavascript` 取回（[webNovelPageHtml]），作品身份先只按
///   URL 问 Rust（[WebArticleExtractor.workKeyForUrl]）找书架上已有的同一部作品；
/// - 有就用它的快照开会话（并进去、去重、排序都在 Rust），没有开新会话；
/// - 预览里给出章节标题、首段、下一章是否找到、是新书还是并进哪本；
/// - 确认后组装 / 就地重建 EPUB（[WebNovelLibrary.save]），开到这一章。
///
/// 返回 false = 这一页没识别到正文（调用方已提示）或用户取消。
Future<bool> readWebNovelPageInFushi({
  required BuildContext context,
  required WidgetRef ref,
  required InAppWebViewController controller,
  required Uri pageUrl,
}) async {
  final AppModel appModel = ref.read(appProvider);
  final WebNovelLibrary library = WebNovelLibrary(database: appModel.database);
  final Uint8List html = await webNovelPageHtml(controller);
  final String? workKey = WebArticleExtractor.workKeyForUrl(pageUrl);
  final EpubBookRow? existing = workKey == null
      ? null
      : await library.findBook(workKey);
  final WebNovelSnapshot? previous = WebNovelSnapshot.tryParse(
    existing?.sourceMetadata,
  );

  WebNovelSession session = WebNovelSession.open(snapshot: previous?.raw);
  try {
    WebNovelIngest ingest = await session.ingest(html, pageUrl);
    EpubBookRow? target = existing;
    if (ingest.status == WebNovelIngestStatus.otherWork) {
      // URL 推的身份与页面推的不一致（通用站点按目录链接定身份）：当新作品。
      session.close();
      session = WebNovelSession.open();
      ingest = await session.ingest(html, pageUrl);
      target = null;
    }
    if (!ingest.status.accepted || ingest.index == null) {
      FushiToast.show(
        msg: t.novel_web_extract_empty,
        severity: ToastSeverity.warning,
      );
      return false;
    }
    final WebNovelSnapshot snapshot = session.snapshot();
    if (!context.mounted) return false;
    final WebArticle article = ingest.article;
    final bool confirmed = await showWebNovelPreviewDialog(
      context,
      WebNovelPreview(
        chapterTitle: article.title,
        workTitle: snapshot.workTitle,
        excerpt: article.excerpt,
        hasNext: article.next != null,
        mergeIntoTitle: target?.title,
        existingChapters:
            WebNovelSnapshot.tryParse(
              target?.sourceMetadata,
            )?.chapters.length ??
            0,
      ),
    );
    if (!confirmed || !context.mounted) return false;

    final WebNovelChapterContent content = await library.materialize(article);
    final String bookKey = await library.save(
      snapshot: snapshot,
      chapterIndex: ingest.index!,
      content: content,
      pendingText: t.novel_web_chapter_pending,
      nextChapterTitle: t.novel_web_chapter_next,
      existing: target,
    );
    ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    if (!context.mounted) return true;
    final MediaItem item = buildCollectionReaderMediaItem(
      bookKey: bookKey,
      title: target?.title ?? snapshot.workTitle ?? article.title,
      format: BookFormat.epub,
    );
    await appModel.openMedia(
      ref: ref,
      mediaSource: item.getMediaSource(appModel: appModel),
      item: item,
      waitUntilClosed: false,
      initialBookmarkJump: Bookmark(
        sectionIndex: ingest.index!,
        normCharOffset: 0,
        label: '',
        createdAt: DateTime.now(),
      ),
    );
    return true;
  } finally {
    session.close();
  }
}
