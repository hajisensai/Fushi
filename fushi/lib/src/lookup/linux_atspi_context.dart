// Linux counterpart of the Windows UI Automation / macOS Accessibility context
// capture behind `SelectionCapture.captureForegroundContext`: reads the
// selected text AND the text around it from the foreground application through
// AT-SPI (the `org.a11y.atspi` D-Bus protocol every GTK / Qt / Firefox /
// Chromium / LibreOffice app speaks when accessibility is on).
//
// Why Dart (package:dbus) and not the runner or `fushi_lookup_card`:
// - AT-SPI is plain D-Bus; package:dbus is already a dependency (Flatpak
//   updater, global shortcuts portal), so there is nothing new to build or ship.
// - Every call is async: a slow or hung foreign app cannot block the GTK main
//   thread (libatspi's API is synchronous and not thread safe).
// - The tree walk is pure logic over [AtspiTree], unit-tested with a fake tree;
//   the helper only exists while a card is up and would add a process hop.
//
// The walk: registry root → applications (skipping Fushi's own process) →
// their ACTIVE top-level windows → the FOCUSED descendant (Collection.GetMatches
// in one call where the toolkit implements it, else a bounded walk over SHOWING
// nodes) → its Text interface: selection 0 and up to [maxExpand] characters on
// each side. Anything missing (no a11y bus, toolkit a11y off, Flatpak's
// filtered a11y proxy, nothing focused, no selection, timeout) yields null and
// the caller falls back to the PRIMARY selection.
//
// This file imports only dart:* and package:dbus so it also runs under plain
// `dart` (that is how it was verified against a GTK app in Xvfb).

import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';

/// One accessible object: the D-Bus unique name of its application and its
/// object path.
class AtspiRef {
  const AtspiRef(this.bus, this.path);

  final String bus;
  final String path;

  @override
  bool operator ==(Object other) =>
      other is AtspiRef && other.bus == bus && other.path == path;

  @override
  int get hashCode => Object.hash(bus, path);

  @override
  String toString() => '$bus$path';
}

/// AT-SPI state bits (`AtspiStateType`), as indexes into the two-word bitset
/// `GetState` returns.
abstract final class AtspiState {
  static const int active = 1;
  static const int defunct = 6;
  static const int focused = 12;
  static const int managesDescendants = 31;
  static const int showing = 25;
}

/// Decoded `GetState` reply: a set of [AtspiState] indexes.
class AtspiStateSet {
  const AtspiStateSet(this.words);

  /// Builds the set from state indexes (tests and the Collection rule).
  factory AtspiStateSet.of(Iterable<int> states) {
    final List<int> words = <int>[0, 0];
    for (final int s in states) {
      words[s ~/ 32] |= 1 << (s % 32);
    }
    return AtspiStateSet(words);
  }

  final List<int> words;

  bool contains(int state) {
    final int word = state ~/ 32;
    return word < words.length && (words[word] >> (state % 32)) & 1 == 1;
  }
}

/// The text a selection sits in, offsets in UTF-16 code units (Dart string
/// indexes), the same shape the Windows / macOS channel returns.
class AtspiSelectionContext {
  const AtspiSelectionContext({
    required this.contextText,
    required this.selStart,
    required this.selLen,
  });

  final String contextText;
  final int selStart;
  final int selLen;
}

/// The slice of the AT-SPI protocol the walk needs. [DBusAtspiTree] talks to
/// the real accessibility bus; tests supply a fake.
abstract interface class AtspiTree {
  /// The applications registered on the bus (children of the registry root).
  Future<List<AtspiRef>> applications();

  /// Process id behind an application's bus name, or null when unknown.
  Future<int?> processId(String bus);

  Future<List<AtspiRef>> children(AtspiRef node);

  Future<AtspiStateSet> state(AtspiRef node);

  Future<List<String>> interfaces(AtspiRef node);

  /// `Collection.GetMatches` for the first FOCUSED descendant of [root]:
  /// null when the toolkit does not implement Collection (the caller then
  /// walks), an empty list when it does and nothing matched.
  Future<List<AtspiRef>?> focusedDescendants(AtspiRef root);

  Future<int> selectionCount(AtspiRef node);

  /// Selection [index] as character offsets `(start, end)`.
  Future<(int, int)> selection(AtspiRef node, int index);

  Future<int> characterCount(AtspiRef node);

  /// Text between character offsets [start] and [end].
  Future<String> text(AtspiRef node, int start, int end);
}

const String _textInterface = 'org.a11y.atspi.Text';

/// Upper bound for nodes visited per window by the fallback walk (a large GTK
/// window has a few hundred; browsers manage their documents themselves).
const int kAtspiWalkNodeBudget = 1500;

/// Finds the focused text with a non-empty selection in the foreground
/// application and returns the selection with up to [maxExpand] characters of
/// text on each side. [ownPid] is skipped: Fushi itself is active while its
/// own windows have focus, and its text is never what the user selected.
Future<AtspiSelectionContext?> findFocusedSelectionContext(
  AtspiTree tree, {
  required int ownPid,
  int maxExpand = 600,
  int nodeBudget = kAtspiWalkNodeBudget,
  void Function(String message)? log,
}) async {
  final List<AtspiRef> apps = await tree.applications();
  // Applications are independent (one per D-Bus connection): ask them all at
  // once, so one slow app costs its own latency, not the sum.
  final List<List<AtspiRef>> activeWindows = await Future.wait(
    apps.map((AtspiRef app) => _activeWindows(tree, app, ownPid)),
  );
  final List<AtspiRef> windows = activeWindows
      .expand((List<AtspiRef> w) => w)
      .toList();
  int focusedCount = 0;
  for (final AtspiRef window in windows) {
    final AtspiRef? focused = await _focusedIn(tree, window, nodeBudget);
    if (focused == null) continue;
    focusedCount++;
    final AtspiSelectionContext? context = await _selectionContext(
      tree,
      focused,
      maxExpand,
    );
    if (context != null) return context;
  }
  // Counts only (privacy): tells "no active window" (focus already moved,
  // e.g. to Fushi) from "focused object has no text / selection".
  log?.call(
    'atspi: no selection (apps=${apps.length} activeWindows=${windows.length} '
    'focused=$focusedCount)',
  );
  return null;
}

Future<List<AtspiRef>> _activeWindows(
  AtspiTree tree,
  AtspiRef app,
  int ownPid,
) async {
  try {
    final int? pid = await tree.processId(app.bus);
    if (pid == ownPid) return const <AtspiRef>[];
    final List<AtspiRef> windows = await tree.children(app);
    final List<AtspiRef> active = <AtspiRef>[];
    for (final AtspiRef window in windows) {
      final AtspiStateSet s = await tree.state(window);
      if (s.contains(AtspiState.active) && !s.contains(AtspiState.defunct)) {
        active.add(window);
      }
    }
    return active;
  } on Object {
    // A dead or misbehaving application must not hide the others.
    return const <AtspiRef>[];
  }
}

Future<AtspiRef?> _focusedIn(
  AtspiTree tree,
  AtspiRef window,
  int nodeBudget,
) async {
  List<AtspiRef>? matches;
  try {
    matches = await tree.focusedDescendants(window);
  } on Object {
    matches = null;
  }
  if (matches != null) {
    return matches.isEmpty ? null : matches.first;
  }
  // No Collection interface: depth-first over what is on screen. The focused
  // object is always SHOWING; objects that manage their descendants (tables,
  // terminals' scrollback, browser documents) can expose thousands of
  // transient children and are not descended into.
  final List<AtspiRef> stack = <AtspiRef>[window];
  int visited = 0;
  while (stack.isNotEmpty && visited < nodeBudget) {
    final AtspiRef node = stack.removeLast();
    visited++;
    final AtspiStateSet s;
    try {
      s = await tree.state(node);
    } on Object {
      continue;
    }
    if (s.contains(AtspiState.focused) && node != window) return node;
    if (node != window && !s.contains(AtspiState.showing)) continue;
    if (s.contains(AtspiState.managesDescendants)) continue;
    try {
      // Reversed so the first child is visited first.
      stack.addAll((await tree.children(node)).reversed);
    } on Object {
      continue;
    }
  }
  return null;
}

Future<AtspiSelectionContext?> _selectionContext(
  AtspiTree tree,
  AtspiRef node,
  int maxExpand,
) async {
  if (!(await tree.interfaces(node)).contains(_textInterface)) return null;
  if (await tree.selectionCount(node) <= 0) return null;
  final (int rawStart, int rawEnd) = await tree.selection(node, 0);
  final int count = await tree.characterCount(node);
  final int selStart = rawStart < rawEnd ? rawStart : rawEnd;
  final int selEnd = rawStart < rawEnd ? rawEnd : rawStart;
  if (selStart < 0 || selEnd <= selStart || selEnd > count) return null;
  final int from = selStart - maxExpand < 0 ? 0 : selStart - maxExpand;
  final int to = selEnd + maxExpand > count ? count : selEnd + maxExpand;
  final String contextText = await tree.text(node, from, to);
  return contextFromCharacterOffsets(
    contextText,
    selStart - from,
    selEnd - selStart,
  );
}

/// AT-SPI offsets count characters (Unicode code points); Dart strings index
/// UTF-16 code units. Converts a selection given in code points within
/// [contextText] into UTF-16 offsets. Null when the offsets do not fit the
/// text (the application reported offsets inconsistent with its own text).
AtspiSelectionContext? contextFromCharacterOffsets(
  String contextText,
  int charStart,
  int charLen,
) {
  if (charStart < 0 || charLen <= 0) return null;
  int units = 0;
  int chars = 0;
  int? start;
  for (final int rune in contextText.runes) {
    if (chars == charStart) start = units;
    if (chars == charStart + charLen) break;
    units += rune > 0xFFFF ? 2 : 1;
    chars++;
  }
  if (start == null || chars < charStart + charLen) return null;
  return AtspiSelectionContext(
    contextText: contextText,
    selStart: start,
    selLen: units - start,
  );
}

/// [AtspiTree] over the accessibility bus.
class DBusAtspiTree implements AtspiTree {
  DBusAtspiTree(this.client);

  final DBusClient client;

  static const String _accessible = 'org.a11y.atspi.Accessible';
  static const String _collection = 'org.a11y.atspi.Collection';
  static const String _registry = 'org.a11y.atspi.Registry';
  static const String _rootPath = '/org/a11y/atspi/accessible/root';

  /// Connects to the accessibility bus: `AT_SPI_BUS_ADDRESS` when set (Flatpak
  /// sets it to its filtered proxy), else the address `org.a11y.Bus` hands out
  /// on the session bus. Null when there is no such bus.
  static Future<DBusClient?> connect() async {
    final String? env = Platform.environment['AT_SPI_BUS_ADDRESS'];
    if (env != null && env.isNotEmpty) return DBusClient(DBusAddress(env));
    final DBusClient session = DBusClient.session();
    try {
      final DBusMethodSuccessResponse reply =
          await DBusRemoteObject(
            session,
            name: 'org.a11y.Bus',
            path: DBusObjectPath('/org/a11y/bus'),
          ).callMethod(
            'org.a11y.Bus',
            'GetAddress',
            const <DBusValue>[],
            replySignature: DBusSignature('s'),
          );
      final String address = reply.values.first.asString();
      return address.isEmpty ? null : DBusClient(DBusAddress(address));
    } finally {
      await session.close();
    }
  }

  DBusRemoteObject _object(AtspiRef ref) =>
      DBusRemoteObject(client, name: ref.bus, path: DBusObjectPath(ref.path));

  Future<List<DBusValue>> _call(
    AtspiRef ref,
    String interface,
    String method,
    List<DBusValue> args,
    String signature,
  ) async {
    final DBusMethodSuccessResponse reply = await _object(ref).callMethod(
      interface,
      method,
      args,
      replySignature: DBusSignature(signature),
    );
    return reply.values;
  }

  static List<AtspiRef> _refs(DBusValue array) => array
      .asArray()
      .map((DBusValue v) {
        final List<DBusValue> pair = v.asStruct();
        return AtspiRef(pair[0].asString(), pair[1].asObjectPath().value);
      })
      // ("", "/org/a11y/atspi/null") is how AT-SPI spells "no object".
      .where((AtspiRef r) => r.bus.isNotEmpty && !r.path.endsWith('/null'))
      .toList();

  @override
  Future<List<AtspiRef>> applications() =>
      children(const AtspiRef(_registry, _rootPath));

  @override
  Future<int?> processId(String bus) async {
    try {
      return await client.getConnectionUnixProcessId(bus);
    } on Object {
      return null;
    }
  }

  @override
  Future<List<AtspiRef>> children(AtspiRef node) async => _refs(
    (await _call(
      node,
      _accessible,
      'GetChildren',
      const <DBusValue>[],
      'a(so)',
    )).first,
  );

  @override
  Future<AtspiStateSet> state(AtspiRef node) async {
    final List<DBusValue> v = await _call(
      node,
      _accessible,
      'GetState',
      const <DBusValue>[],
      'au',
    );
    return AtspiStateSet(
      v.first.asArray().map((DBusValue w) => w.asUint32()).toList(),
    );
  }

  @override
  Future<List<String>> interfaces(AtspiRef node) async => (await _call(
    node,
    _accessible,
    'GetInterfaces',
    const <DBusValue>[],
    'as',
  )).first.asStringArray().toList();

  @override
  Future<List<AtspiRef>?> focusedDescendants(AtspiRef root) async {
    if (!(await interfaces(root)).contains(_collection)) return null;
    final AtspiStateSet focused = AtspiStateSet.of(<int>[AtspiState.focused]);
    // MatchRule (aiia{ss}iaiiasib): states + ALL, no attribute / role /
    // interface constraint, not inverted. Match types: 1 = ALL.
    final DBusStruct rule = DBusStruct(<DBusValue>[
      DBusArray.int32(focused.words),
      const DBusInt32(1),
      DBusDict(
        DBusSignature('s'),
        DBusSignature('s'),
        const <DBusValue, DBusValue>{},
      ),
      const DBusInt32(1),
      DBusArray.int32(const <int>[]),
      const DBusInt32(1),
      DBusArray.string(const <String>[]),
      const DBusInt32(1),
      const DBusBoolean(false),
    ]);
    final List<DBusValue> v = await _call(
      root,
      _collection,
      'GetMatches',
      <DBusValue>[
        rule,
        const DBusUint32(1), // SORT_ORDER_CANONICAL
        const DBusInt32(1), // first match is enough
        const DBusBoolean(true), // whole subtree
      ],
      'a(so)',
    );
    return _refs(v.first);
  }

  @override
  Future<int> selectionCount(AtspiRef node) async => (await _call(
    node,
    _textInterface,
    'GetNSelections',
    const <DBusValue>[],
    'i',
  )).first.asInt32();

  @override
  Future<(int, int)> selection(AtspiRef node, int index) async {
    final List<DBusValue> v = await _call(
      node,
      _textInterface,
      'GetSelection',
      <DBusValue>[DBusInt32(index)],
      'ii',
    );
    return (v[0].asInt32(), v[1].asInt32());
  }

  @override
  Future<int> characterCount(AtspiRef node) async =>
      (await _object(node).getProperty(
        _textInterface,
        'CharacterCount',
        signature: DBusSignature('i'),
      )).asInt32();

  @override
  Future<String> text(AtspiRef node, int start, int end) async => (await _call(
    node,
    _textInterface,
    'GetText',
    <DBusValue>[DBusInt32(start), DBusInt32(end)],
    's',
  )).first.asString();
}

/// Captures the foreground application's selection context over AT-SPI.
/// Never throws; null on any miss, after at most [timeout].
Future<AtspiSelectionContext?> captureLinuxAtspiContext({
  int maxExpand = 600,
  Duration timeout = const Duration(milliseconds: 800),
  void Function(String message)? log,
}) async {
  DBusClient? client;
  try {
    client = await DBusAtspiTree.connect().timeout(timeout);
    if (client == null) {
      log?.call('atspi: no accessibility bus');
      return null;
    }
    return await findFocusedSelectionContext(
      DBusAtspiTree(client),
      ownPid: pid,
      maxExpand: maxExpand,
      log: log,
    ).timeout(timeout);
  } on TimeoutException {
    log?.call('atspi: timed out after ${timeout.inMilliseconds} ms');
    return null;
  } on Object catch (e) {
    // Privacy: the error type only, never text.
    log?.call('atspi: ${e.runtimeType}');
    return null;
  } finally {
    unawaited(client?.close().catchError((Object _) {}));
  }
}
