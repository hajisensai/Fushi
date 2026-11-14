import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_mining_settings.dart';
import 'package:fushi/src/pages/implementations/galgame_mining_overrides_section.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';
import 'package:material_ui/material_ui.dart';

const GalMiningSettings _global = GalMiningSettings(
  imageMode: VideoMiningImageMode.gif,
  animatedFormat: MiningAnimatedFormat.avif,
  stillFormat: MiningStillFormat.jpg,
  clipFormat: MiningClipFormat.webmVp9,
  audioLimit: GalMiningAudioLimit(mode: GalMiningAudioMode.auto),
);

Future<void> _pump(
  WidgetTester tester,
  GalGameMiningOverrides overrides, {
  GalMiningSettings global = _global,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          children: <Widget>[
            GalgameMiningOverridesSection(
              overrides: overrides,
              global: global,
              onChanged: (GalGameMiningOverrides _) {},
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  const Key seconds = ValueKey<String>('galgame-mining-override-audio-seconds');
  const Key reset = ValueKey<String>('galgame-mining-override-reset');

  testWidgets('完全跟随全局：没有秒数行、没有「全部恢复」', (WidgetTester tester) async {
    await _pump(tester, GalGameMiningOverrides.none);

    expect(
      find.byKey(const ValueKey<String>('galgame-mining-override-audio-mode')),
      findsOneWidget,
    );
    expect(find.byKey(seconds), findsNothing);
    expect(find.byKey(reset), findsNothing);
  });

  testWidgets('本游戏覆盖成「最长时长」：出现秒数行与「全部恢复」', (WidgetTester tester) async {
    await _pump(
      tester,
      const GalGameMiningOverrides(audioMode: GalMiningAudioMode.maxLength),
    );

    expect(find.byKey(seconds), findsOneWidget);
    expect(find.byKey(reset), findsOneWidget);
  });

  testWidgets('全局是固定时长、本游戏未覆盖：秒数行按生效模式出现', (WidgetTester tester) async {
    await _pump(
      tester,
      GalGameMiningOverrides.none,
      global: const GalMiningSettings(
        imageMode: VideoMiningImageMode.gif,
        animatedFormat: MiningAnimatedFormat.avif,
        stillFormat: MiningStillFormat.jpg,
        clipFormat: MiningClipFormat.webmVp9,
        audioLimit: GalMiningAudioLimit(
          mode: GalMiningAudioMode.fixedLength,
          seconds: 5,
        ),
      ),
    );

    expect(find.byKey(seconds), findsOneWidget);
    expect(find.byKey(reset), findsNothing);
  });
}
