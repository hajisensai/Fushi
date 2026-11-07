import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/ax_tree_contract_model.dart';

late SemanticsUpdateSpyBinding _binding;

Future<void> _pumpAndCommit(
  WidgetTester tester,
  AxTreeContractChecker engine,
  String step, {
  int frames = 1,
}) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    engine.commitFrame('$step frame $i');
  }
}

/// 两个容器之间来回搬一棵带 GlobalKey 的语义子树。
class _Mover extends StatefulWidget {
  const _Mover();

  @override
  State<_Mover> createState() => _MoverState();
}

class _MoverState extends State<_Mover> {
  final GlobalKey _key = GlobalKey();
  bool left = true;

  void flip() => setState(() => left = !left);

  @override
  Widget build(BuildContext context) {
    final Widget moved = Semantics(
      key: _key,
      container: true,
      label: 'moved',
      explicitChildNodes: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text('moved child a'),
          Semantics(
            container: true,
            explicitChildNodes: true,
            label: 'moved child b',
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const <Widget>[
                Text('grandchild 1'),
                Text('grandchild 2'),
              ],
            ),
          ),
        ],
      ),
    );
    return Column(
      children: <Widget>[
        Semantics(
          container: true,
          label: 'left box',
          child: SizedBox(
            height: 100,
            child: Column(children: <Widget>[if (left) moved]),
          ),
        ),
        Semantics(
          container: true,
          label: 'right box',
          child: SizedBox(
            height: 100,
            child: Column(children: <Widget>[if (!left) moved]),
          ),
        ),
      ],
    );
  }
}

void main() {
  _binding = SemanticsUpdateSpyBinding();

  testWidgets('GlobalKey reparent between semantics containers', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final AxTreeContractChecker engine = AxTreeContractChecker(_binding);

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: _Mover())));
    engine.commitFrame('initial');
    final _MoverState state = tester.state(find.byType(_Mover));
    for (int i = 0; i < 4; i++) {
      state.flip();
      await _pumpAndCommit(tester, engine, 'flip $i');
    }
    handle.dispose();
  });

  testWidgets('webview-like Focus+Texture tiles across width changes', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final AxTreeContractChecker engine = AxTreeContractChecker(_binding);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1715, 900);
    addTearDown(tester.view.reset);
    Widget tile(int i) => SizedBox(
      height: 94,
      child: Focus(
        autofocus: true,
        child: SizedBox.expand(
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: 1200,
              maxWidth: 1200,
              child: Texture(textureId: i),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              final List<Widget> tiles = <Widget>[
                for (int i = 0; i < 4; i++) ...<Widget>[
                  Text('tile $i title'),
                  tile(i),
                ],
              ];
              return c.maxWidth > 1200
                  ? Row(
                      children: <Widget>[
                        const SizedBox(width: 300, child: Text('side panel')),
                        Expanded(child: ListView(children: tiles)),
                      ],
                    )
                  : ListView(children: tiles);
            },
          ),
        ),
      ),
    );
    engine.commitFrame('initial');
    for (int i = 0; i < 6; i++) {
      tester.view.physicalSize = Size(i.isEven ? 1075 : 1715, 900);
      await _pumpAndCommit(tester, engine, 'resize $i', frames: 3);
    }
    handle.dispose();
  });

  for (final String mode in <String>[
    'container',
    'explicitChildNodes',
    'merge',
  ]) {
    testWidgets('toggling intermediate boundary: $mode', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final AxTreeContractChecker engine = AxTreeContractChecker(_binding);

      late StateSetter set;
      bool on = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (BuildContext context, StateSetter s) {
                set = s;
                final Widget leaf = Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (final String tag in <String>['a', 'b'])
                      Semantics(
                        container: true,
                        explicitChildNodes: true,
                        label: 'leaf $tag',
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text('leaf $tag 1'),
                            Text('leaf $tag 2'),
                          ],
                        ),
                      ),
                  ],
                );
                final Widget inner = switch (mode) {
                  'container' => Semantics(
                    container: on,
                    label: 'mid',
                    child: leaf,
                  ),
                  'explicitChildNodes' => Semantics(
                    container: true,
                    explicitChildNodes: on,
                    label: 'mid',
                    child: leaf,
                  ),
                  _ => on ? MergeSemantics(child: leaf) : leaf,
                };
                return Semantics(container: true, label: 'outer', child: inner);
              },
            ),
          ),
        ),
      );
      engine.commitFrame('initial');
      for (int i = 0; i < 4; i++) {
        set(() => on = !on);
        await _pumpAndCommit(tester, engine, '$mode toggle $i');
      }
      handle.dispose();
    });
  }

  Widget twoTooltips() => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Tooltip(
        message: 'Tooltip A',
        child: Container(
          width: 100,
          height: 100,
          color: const Color(0xFFFF0000),
        ),
      ),
      Tooltip(
        message: 'Tooltip B',
        child: Container(
          width: 100,
          height: 100,
          color: const Color(0xFF00FF00),
        ),
      ),
    ],
  );

  final Map<String, Widget Function()> hosts = <String, Widget Function()>{
    'ListView item (flutter#182444)': () =>
        ListView(children: <Widget>[twoTooltips()]),
    'MergeSemantics': () => Align(
      alignment: Alignment.topLeft,
      child: MergeSemantics(child: twoTooltips()),
    ),
    'ListTile title': () => ListView(
      children: <Widget>[ListTile(title: twoTooltips(), onTap: () {})],
    ),
    'ListTile trailing IconButtons': () => ListView(
      children: <Widget>[
        ListTile(
          title: const Text('row title'),
          onTap: () {},
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              IconButton(
                tooltip: 'Tooltip A',
                icon: const Icon(Icons.edit),
                onPressed: () {},
              ),
              IconButton(
                tooltip: 'Tooltip B',
                icon: const Icon(Icons.delete),
                onPressed: () {},
              ),
            ],
          ),
        ),
      ],
    ),
    'MergeSemantics IconButtons': () => Align(
      alignment: Alignment.topLeft,
      child: MergeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              tooltip: 'Tooltip A',
              icon: const Icon(Icons.edit),
              onPressed: () {},
            ),
            IconButton(
              tooltip: 'Tooltip B',
              icon: const Icon(Icons.delete),
              onPressed: () {},
            ),
          ],
        ),
      ),
    ),
    'plain Row': () =>
        Align(alignment: Alignment.topLeft, child: twoTooltips()),
  };

  for (final MapEntry<String, Widget Function()> host in hosts.entries) {
    testWidgets('hovering between two Tooltips in ${host.key}', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final AxTreeContractChecker engine = AxTreeContractChecker(_binding);

      await tester.pumpWidget(MaterialApp(home: Scaffold(body: host.value())));
      engine.commitFrame('initial');
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(700, 500));
      addTearDown(mouse.removePointer);
      final Offset a = tester.getCenter(find.byTooltip('Tooltip A'));
      final Offset b = tester.getCenter(find.byTooltip('Tooltip B'));
      for (int i = 0; i < 6; i++) {
        await mouse.moveTo(i.isEven ? a : b);
        await _pumpAndCommit(tester, engine, 'hover $i', frames: 20);
      }
      await mouse.moveTo(const Offset(700, 500));
      await _pumpAndCommit(tester, engine, 'leave', frames: 40);
      handle.dispose();
    });
  }

  testWidgets(
    'two shown OverlayPortals anchored in one ListView item both reach the '
    'engine tree (flutter#182444 / #190344)',
    (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final AxTreeContractChecker engine = AxTreeContractChecker(_binding);
      final OverlayPortalController a = OverlayPortalController();
      final OverlayPortalController b = OverlayPortalController();
      Widget portal(OverlayPortalController c, String tag) => OverlayPortal(
        controller: c,
        overlayChildBuilder: (BuildContext context) => Positioned(
          left: 10,
          top: 300,
          child: Semantics(
            container: true,
            label: 'overlay $tag',
            child: const SizedBox(width: 80, height: 20),
          ),
        ),
        child: const SizedBox(width: 100, height: 100),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: <Widget>[
                Row(children: <Widget>[portal(a, 'A'), portal(b, 'B')]),
              ],
            ),
          ),
        ),
      );
      engine.commitFrame('initial');
      a.show();
      b.show();
      await _pumpAndCommit(tester, engine, 'show both', frames: 2);
      expect(engine.hasLabel('overlay A'), isTrue);
      expect(engine.hasLabel('overlay B'), isTrue);
      b.hide();
      await _pumpAndCommit(tester, engine, 'hide B', frames: 2);
      a.hide();
      await _pumpAndCommit(tester, engine, 'hide A', frames: 2);
      handle.dispose();
    },
  );
}
