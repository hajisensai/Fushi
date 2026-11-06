import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/links/theme_song/theme_song_plan.dart';
import 'package:fushi/src/pages/implementations/music/music_track_detail_page.dart';
import 'package:material_ui/material_ui.dart';

/// 曲目详情「出现在：第 1–12 集 OP」（作品图谱 L2）：标签按集号压缩、角色跟连接走；
/// 点某一集的集号 = 那一集的 OP 起点，点整行 = 第一集。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  ThemeSongEpisode ep(int n) => ThemeSongEpisode(
    bookUid: 'b$n',
    episodeIndex: 0,
    episodeNumber: n,
    path: '/anime/$n.mkv',
  );

  final ThemeSongAppearance appearance = ThemeSongAppearance(
    videoTitle: '魔女之旅',
    role: ThemeSongRole.op,
    episodes: <({ThemeSongEpisode episode, int startMs})>[
      for (int n = 1; n <= 12; n++) (episode: ep(n), startMs: 30000 + n),
    ],
  );

  test('标签：第 1–12 集 OP；没写角色就不标', () {
    expect(themeSongAppearanceLabel(appearance), '第 1–12 集 OP');
    expect(
      themeSongAppearanceLabel(
        ThemeSongAppearance(
          videoTitle: 'x',
          role: null,
          episodes: <({ThemeSongEpisode episode, int startMs})>[
            (episode: ep(2), startMs: 1),
            (episode: ep(4), startMs: 1),
          ],
        ),
      ),
      '第 2, 4 集',
    );
  });

  testWidgets('点集号跳那一集的起点；点整行跳第一集', (WidgetTester tester) async {
    final List<({ThemeSongEpisode episode, int startMs})> opened =
        <({ThemeSongEpisode episode, int startMs})>[];
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ThemeSongAppearanceTile(
                appearance: appearance,
                onOpenEpisode: opened.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('魔女之旅'), findsOneWidget);
    expect(find.text('第 1–12 集 OP'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('music-appearance-episode-5')),
    );
    await tester.pumpAndSettle();
    expect(opened.single.episode.episodeNumber, 5);
    expect(opened.single.startMs, 30005);
    await tester.tap(find.text('魔女之旅'));
    await tester.pumpAndSettle();
    expect(opened.last.episode.episodeNumber, 1);
  });
}
