import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi_engine/media/music/disc/music_disc.dart';

import 'package:fushi/src/pages/implementations/music/music_disc_cover.dart';

Widget _harness(Widget child, {double width = 200, double height = 260}) =>
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, height: height, child: child),
        ),
      ),
    );

void main() {
  test('盘种短标只取登记的盘种，未知盘种不写', () {
    expect(musicDiscKindLabel(MusicDiscKind.cdda), 'CD');
    expect(musicDiscKindLabel(MusicDiscKind.dvd), 'DVD');
    expect(musicDiscKindLabel(MusicDiscKind.bluray), 'BD');
    expect(musicDiscKindLabel(null), '');
  });

  testWidgets('盒装卡：盒面写规格 / 标题 / 副行，盘与盒面都在格子内', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const MusicDiscCaseCard(
          cover: ColoredBox(color: Colors.pink),
          kind: MusicDiscKind.bluray,
          title: 'Album title',
          subtitle: 'Artist · FLAC',
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('BD'), findsOneWidget);
    expect(find.text('Album title'), findsOneWidget);
    expect(find.text('Artist · FLAC'), findsOneWidget);

    final Rect cell = tester.getRect(find.byType(MusicDiscCaseCard));
    final Rect disc = tester.getRect(find.byType(MusicDiscFace));
    expect(cell.contains(disc.topLeft), isTrue);
    expect(cell.contains(disc.bottomRight - const Offset(1, 1)), isTrue);
    expect(disc.width, closeTo(disc.height, 0.01));
  });

  testWidgets('悬停时盘转一个小角度，离开转回', (WidgetTester tester) async {
    Widget face(bool hovering) => _harness(
      MusicDiscFace(
        cover: const ColoredBox(color: Colors.blue),
        hovering: hovering,
      ),
      height: 200,
    );
    await tester.pumpWidget(face(false));
    AnimatedRotation rotation() =>
        tester.widget<AnimatedRotation>(find.byType(AnimatedRotation));
    expect(rotation().turns, 0);
    await tester.pumpWidget(face(true));
    await tester.pumpAndSettle();
    expect(rotation().turns, kMusicDiscHoverTurns);
    await tester.pumpWidget(face(false));
    await tester.pumpAndSettle();
    expect(rotation().turns, 0);
  });
}
