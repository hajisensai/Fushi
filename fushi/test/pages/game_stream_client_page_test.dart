import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/game_stream_client_page.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Widget host() => MaterialApp(
    home: Scaffold(
      body: GameStreamClientPage(
        streamBuilder: (BuildContext context, Widget navigation) =>
            Column(children: <Widget>[navigation, const Text('stream-body')]),
        texthookerBuilder: (BuildContext context, Widget navigation) =>
            Column(children: <Widget>[navigation, const Text('lines-body')]),
      ),
    ),
  );

  testWidgets('exposes a texthooker entry and builds it lazily', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.text('stream-body'), findsOneWidget);
    expect(find.text('lines-body'), findsNothing);

    await tester.tap(find.text(t.texthooker).first);
    await tester.pumpAndSettle();
    expect(find.text('lines-body'), findsOneWidget);

    // 切回串流库后台词页保活（IndexedStack），不销毁。
    await tester.tap(find.text(t.game_stream_tab).first);
    await tester.pumpAndSettle();
    expect(find.text('lines-body', skipOffstage: false), findsOneWidget);
  });
}
