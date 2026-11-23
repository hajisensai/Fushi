// Linux global-lookup context capture over AT-SPI: the tree walk
// (findFocusedSelectionContext) against a fake accessibility tree, the
// character → UTF-16 offset conversion, and the shared tail that turns a
// captured buffer into the selected term + sentence. The D-Bus layer itself
// (DBusAtspiTree) was verified against GTK 3 and GTK 4 TextViews in Xvfb.

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/linux_atspi_context.dart';
import 'package:fushi/src/lookup/selection_capture_ffi.dart';

class _Node {
  _Node({
    this.states = const <int>{AtspiState.showing},
    this.children = const <AtspiRef>[],
    this.text,
    this.selections = const <(int, int)>[],
  });

  final Set<int> states;
  final List<AtspiRef> children;
  final String? text;
  final List<(int, int)> selections;
}

/// In-memory AT-SPI tree. Text offsets count Unicode code points, as AT-SPI
/// does. `collection` lists the buses whose toolkit implements Collection.
class _FakeTree implements AtspiTree {
  _FakeTree({
    required this.apps,
    required this.nodes,
    this.pids = const <String, int>{},
    this.collection = const <String>{},
    this.failingBuses = const <String>{},
  });

  final List<AtspiRef> apps;
  final Map<AtspiRef, _Node> nodes;
  final Map<String, int> pids;
  final Set<String> collection;
  final Set<String> failingBuses;
  int stateCalls = 0;

  _Node _node(AtspiRef ref) {
    if (failingBuses.contains(ref.bus)) {
      throw StateError('org.freedesktop.DBus.Error.NoReply');
    }
    return nodes[ref] ?? _Node();
  }

  @override
  Future<List<AtspiRef>> applications() async => apps;

  @override
  Future<int?> processId(String bus) async => pids[bus];

  @override
  Future<List<AtspiRef>> children(AtspiRef node) async => _node(node).children;

  @override
  Future<AtspiStateSet> state(AtspiRef node) async {
    stateCalls++;
    return AtspiStateSet.of(_node(node).states);
  }

  @override
  Future<List<String>> interfaces(AtspiRef node) async => <String>[
    'org.a11y.atspi.Accessible',
    if (_node(node).text != null) 'org.a11y.atspi.Text',
    if (collection.contains(node.bus)) 'org.a11y.atspi.Collection',
  ];

  @override
  Future<List<AtspiRef>?> focusedDescendants(AtspiRef root) async {
    if (!collection.contains(root.bus)) return null;
    final List<AtspiRef> stack = <AtspiRef>[..._node(root).children];
    while (stack.isNotEmpty) {
      final AtspiRef ref = stack.removeAt(0);
      if (_node(ref).states.contains(AtspiState.focused)) {
        return <AtspiRef>[ref];
      }
      stack.addAll(_node(ref).children);
    }
    return <AtspiRef>[];
  }

  @override
  Future<int> selectionCount(AtspiRef node) async =>
      _node(node).selections.length;

  @override
  Future<(int, int)> selection(AtspiRef node, int index) async =>
      _node(node).selections[index];

  @override
  Future<int> characterCount(AtspiRef node) async =>
      _node(node).text!.runes.length;

  @override
  Future<String> text(AtspiRef node, int start, int end) async =>
      String.fromCharCodes(
        _node(node).text!.runes.toList().sublist(start, end),
      );
}

const int _ownPid = 4242;

/// One application `bus` with one window holding a focused text view.
Map<AtspiRef, _Node> _appWithText(
  String bus, {
  required String text,
  required (int, int) selection,
  bool windowActive = true,
  bool focused = true,
}) {
  final AtspiRef app = AtspiRef(bus, '/root');
  final AtspiRef window = AtspiRef(bus, '/win');
  final AtspiRef panel = AtspiRef(bus, '/panel');
  final AtspiRef button = AtspiRef(bus, '/button');
  final AtspiRef view = AtspiRef(bus, '/view');
  return <AtspiRef, _Node>{
    app: _Node(children: <AtspiRef>[window]),
    window: _Node(
      states: <int>{AtspiState.showing, if (windowActive) AtspiState.active},
      children: <AtspiRef>[panel],
    ),
    panel: _Node(children: <AtspiRef>[button, view]),
    button: _Node(),
    view: _Node(
      states: <int>{AtspiState.showing, if (focused) AtspiState.focused},
      text: text,
      selections: <(int, int)>[selection],
    ),
  };
}

String _selected(AtspiSelectionContext ctx) =>
    ctx.contextText.substring(ctx.selStart, ctx.selStart + ctx.selLen);

void main() {
  const String novel = '吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。';
  final int target = novel.indexOf('見当');

  group('findFocusedSelectionContext', () {
    for (final bool collection in <bool>[true, false]) {
      test('reads the focused selection and its surroundings '
          '(${collection ? 'Collection' : 'tree walk'})', () async {
        final _FakeTree tree = _FakeTree(
          apps: const <AtspiRef>[AtspiRef(':1.5', '/root')],
          nodes: _appWithText(
            ':1.5',
            text: novel,
            selection: (target, target + 2),
          ),
          pids: const <String, int>{':1.5': 100},
          collection: collection ? const <String>{':1.5'} : const <String>{},
        );
        final AtspiSelectionContext? ctx = await findFocusedSelectionContext(
          tree,
          ownPid: _ownPid,
        );
        expect(ctx, isNotNull);
        expect(ctx!.contextText, novel);
        expect(_selected(ctx), '見当');
      });
    }

    test('skips Fushi itself and inactive windows', () async {
      final _FakeTree tree = _FakeTree(
        apps: const <AtspiRef>[
          AtspiRef(':1.2', '/root'), // Fushi, active, own text selected
          AtspiRef(':1.3', '/root'), // background app with a selection
          AtspiRef(':1.4', '/root'), // the foreground app
        ],
        nodes: <AtspiRef, _Node>{
          ..._appWithText(':1.2', text: 'Fushi の文。', selection: (0, 5)),
          ..._appWithText(
            ':1.3',
            text: '背景の文。',
            selection: (0, 2),
            windowActive: false,
          ),
          ..._appWithText(':1.4', text: novel, selection: (target, target + 2)),
        },
        pids: const <String, int>{':1.2': _ownPid, ':1.3': 7, ':1.4': 8},
      );
      final AtspiSelectionContext? ctx = await findFocusedSelectionContext(
        tree,
        ownPid: _ownPid,
      );
      expect(_selected(ctx!), '見当');
      expect(ctx.contextText, novel);
    });

    test('a failing application does not hide the others', () async {
      final _FakeTree tree = _FakeTree(
        apps: const <AtspiRef>[
          AtspiRef(':1.9', '/root'),
          AtspiRef(':1.4', '/root'),
        ],
        nodes: _appWithText(
          ':1.4',
          text: novel,
          selection: (target, target + 2),
        ),
        failingBuses: const <String>{':1.9'},
      );
      final AtspiSelectionContext? ctx = await findFocusedSelectionContext(
        tree,
        ownPid: _ownPid,
      );
      expect(_selected(ctx!), '見当');
    });

    test('null without a selection, focus or active window', () async {
      Future<AtspiSelectionContext?> run(Map<AtspiRef, _Node> nodes) =>
          findFocusedSelectionContext(
            _FakeTree(
              apps: const <AtspiRef>[AtspiRef(':1.4', '/root')],
              nodes: nodes,
            ),
            ownPid: _ownPid,
          );
      final Map<AtspiRef, _Node> noSelection = _appWithText(
        ':1.4',
        text: novel,
        selection: (0, 0),
      );
      noSelection[const AtspiRef(':1.4', '/view')] = _Node(
        states: const <int>{AtspiState.showing, AtspiState.focused},
        text: novel,
      );
      expect(await run(noSelection), isNull);
      expect(
        await run(
          _appWithText(
            ':1.4',
            text: novel,
            selection: (target, target + 2),
            focused: false,
          ),
        ),
        isNull,
      );
      expect(
        await run(
          _appWithText(
            ':1.4',
            text: novel,
            selection: (target, target + 2),
            windowActive: false,
          ),
        ),
        isNull,
      );
      // Offsets past the end of the text: the application is inconsistent.
      expect(
        await run(_appWithText(':1.4', text: novel, selection: (5, 500))),
        isNull,
      );
    });

    test('expands at most maxExpand characters each side and accepts a '
        'reversed selection', () async {
      final String long = '${'あ' * 1000}見当${'い' * 1000}';
      final _FakeTree tree = _FakeTree(
        apps: const <AtspiRef>[AtspiRef(':1.4', '/root')],
        nodes: _appWithText(':1.4', text: long, selection: (1002, 1000)),
      );
      final AtspiSelectionContext? ctx = await findFocusedSelectionContext(
        tree,
        ownPid: _ownPid,
        maxExpand: 10,
      );
      expect(ctx!.contextText, '${'あ' * 10}見当${'い' * 10}');
      expect(ctx.selStart, 10);
      expect(ctx.selLen, 2);
    });

    test(
      'the walk skips hidden subtrees and stops at the node budget',
      () async {
        const AtspiRef app = AtspiRef(':1.4', '/root');
        const AtspiRef window = AtspiRef(':1.4', '/win');
        const AtspiRef hidden = AtspiRef(':1.4', '/hidden');
        const AtspiRef hiddenView = AtspiRef(':1.4', '/hidden/view');
        const AtspiRef table = AtspiRef(':1.4', '/table');
        const AtspiRef cell = AtspiRef(':1.4', '/table/cell');
        final Map<AtspiRef, _Node> nodes = <AtspiRef, _Node>{
          app: _Node(children: const <AtspiRef>[window]),
          window: _Node(
            states: const <int>{AtspiState.showing, AtspiState.active},
            children: const <AtspiRef>[hidden, table],
          ),
          // A stale page of a stack: FOCUSED but not on screen.
          hidden: _Node(
            states: const <int>{},
            children: const <AtspiRef>[hiddenView],
          ),
          hiddenView: _Node(
            states: const <int>{AtspiState.focused},
            text: novel,
            selections: <(int, int)>[(0, 2)],
          ),
          table: _Node(
            states: const <int>{
              AtspiState.showing,
              AtspiState.managesDescendants,
            },
            children: const <AtspiRef>[cell],
          ),
          cell: _Node(
            states: const <int>{AtspiState.showing, AtspiState.focused},
            text: novel,
            selections: <(int, int)>[(0, 2)],
          ),
        };
        final _FakeTree tree = _FakeTree(
          apps: const <AtspiRef>[app],
          nodes: nodes,
        );
        expect(
          await findFocusedSelectionContext(tree, ownPid: _ownPid),
          isNull,
        );
        // window, hidden, table: hiddenView and cell are never visited.
        expect(tree.stateCalls, 1 + 3);

        // Budget: a deep chain of showing nodes ends the walk early.
        final Map<AtspiRef, _Node> chain = <AtspiRef, _Node>{
          app: _Node(children: const <AtspiRef>[window]),
          window: _Node(
            states: const <int>{AtspiState.showing, AtspiState.active},
            children: const <AtspiRef>[AtspiRef(':1.4', '/n0')],
          ),
        };
        for (int i = 0; i < 50; i++) {
          chain[AtspiRef(':1.4', '/n$i')] = _Node(
            children: <AtspiRef>[AtspiRef(':1.4', '/n${i + 1}')],
          );
        }
        chain[const AtspiRef(':1.4', '/n50')] = _Node(
          states: const <int>{AtspiState.showing, AtspiState.focused},
          text: novel,
          selections: <(int, int)>[(target, target + 2)],
        );
        final _FakeTree deep = _FakeTree(
          apps: const <AtspiRef>[app],
          nodes: chain,
        );
        expect(
          await findFocusedSelectionContext(
            deep,
            ownPid: _ownPid,
            nodeBudget: 20,
          ),
          isNull,
        );
        expect(
          _selected(
            (await findFocusedSelectionContext(
              _FakeTree(apps: const <AtspiRef>[app], nodes: chain),
              ownPid: _ownPid,
            ))!,
          ),
          '見当',
        );
      },
    );
  });

  group('contextFromCharacterOffsets', () {
    test('converts code-point offsets to UTF-16 around astral characters', () {
      // 😺 and 𠮷 are two UTF-16 units each but one AT-SPI character.
      const String s = '😺猫の𠮷野家で見当。';
      final AtspiSelectionContext? ctx = contextFromCharacterOffsets(s, 7, 2);
      expect(ctx, isNotNull);
      expect(_selected(ctx!), '見当');
      expect(ctx.selStart, 9);
      expect(ctx.selLen, 2);
      final AtspiSelectionContext? astral = contextFromCharacterOffsets(
        s,
        3,
        1,
      );
      expect(_selected(astral!), '𠮷');
      expect(astral.selLen, 2);
    });

    test('null for offsets outside the text', () {
      expect(contextFromCharacterOffsets('abc', 2, 5), isNull);
      expect(contextFromCharacterOffsets('abc', -1, 1), isNull);
      expect(contextFromCharacterOffsets('abc', 1, 0), isNull);
    });
  });

  group('SelectionCapture.contextFromCapture', () {
    test('cuts the sentence the selection sits in', () {
      final ForegroundSelectionContext? ctx =
          SelectionCapture.contextFromCapture(
            source: 'AT-SPI',
            contextText: novel,
            selStart: target,
            selLen: 2,
            elapsedMs: 3,
          );
      expect(ctx!.selectedText, '見当');
      expect(ctx.sentence, 'どこで生れたかとんと見当がつかぬ。');
      expect(
        ctx.sentence.substring(
          ctx.sentenceSelStart,
          ctx.sentenceSelStart + ctx.sentenceSelLen,
        ),
        '見当',
      );
    });

    test('null for an empty buffer or offsets past its end', () {
      ForegroundSelectionContext? run(String text, int start, int len) =>
          SelectionCapture.contextFromCapture(
            source: 'AT-SPI',
            contextText: text,
            selStart: start,
            selLen: len,
            elapsedMs: 0,
          );
      expect(run('', 0, 1), isNull);
      expect(run(novel, 0, 0), isNull);
      expect(run(novel, novel.length - 1, 5), isNull);
    });
  });
}
