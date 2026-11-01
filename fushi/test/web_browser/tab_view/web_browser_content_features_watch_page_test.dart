// 网页漫画「阅读本章」/ 网页小说「阅读（小说）」在视频观看页（YouTube 等）不出动作。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/manga/web/web_comic_reader_launch.dart';
import 'package:fushi/src/media/novel/web/web_novel_gate.dart';
import 'package:fushi/src/web_browser/features/play_in_fushi/youtube_watch_page.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tab_view/features/web_comic_feature.dart';
import 'package:fushi/src/web_browser/tab_view/features/web_novel_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

void main() {
  test('观看页判据复用 YouTube 观看页识别', () {
    for (final String url in <String>[
      'https://m.youtube.com/watch?v=dQw4w9WgXcQ',
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10',
      'https://youtu.be/dQw4w9WgXcQ',
      'https://www.youtube.com/shorts/dQw4w9WgXcQ',
    ]) {
      expect(isWebBrowserVideoWatchPage(Uri.parse(url)), isTrue, reason: url);
    }
    for (final String url in <String>[
      'https://m.youtube.com/',
      'https://www.youtube.com/results?search_query=x',
      'https://syosetu.com/n1234/1/',
    ]) {
      expect(isWebBrowserVideoWatchPage(Uri.parse(url)), isFalse, reason: url);
    }
    expect(isWebBrowserVideoWatchPage(null), isFalse);
  });

  testWidgets('漫画 / 小说插件在 YouTube 观看页不出动作，普通页照常', (WidgetTester tester) async {
    late List<WebBrowserAction> comicWatch;
    late List<WebBrowserAction> novelWatch;
    late List<WebBrowserAction> novelPage;
    final WebBrowserTab watch = WebBrowserTab(
      id: 'w',
      url: Uri.parse('https://m.youtube.com/watch?v=dQw4w9WgXcQ'),
    );
    final WebBrowserTab novel = WebBrowserTab(
      id: 'n',
      url: Uri.parse('https://ncode.syosetu.com/n1234ab/1/'),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (BuildContext context, WidgetRef ref, Widget? _) {
            final WebComicFeature comic = WebComicFeature(ref: ref);
            final WebNovelFeature novelFeature = WebNovelFeature(ref: ref);
            comicWatch = comic.actions(context, watch);
            novelWatch = novelFeature.actions(context, watch);
            novelPage = novelFeature.actions(context, novel);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(comicWatch, isEmpty);
    expect(novelWatch, isEmpty);
    // 合规门照旧：门关着的平台本来就没有动作；门开着时普通页仍出「阅读（小说）」。
    expect(
      novelPage.map((WebBrowserAction a) => a.id),
      webNovelReaderActionAvailable()
          ? contains('open_in_fushi.novel')
          : isEmpty,
    );
    expect(webComicReaderActionAvailable(), isA<bool>());
  });
}
