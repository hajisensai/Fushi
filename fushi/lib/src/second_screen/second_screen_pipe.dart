import 'dart:async';
import 'dart:io';

/// Longest message (UTF-16 code units) handed to the relay as is.
///
/// Android relays each message as a `Bundle` string in one oneway Binder
/// transaction. `Bundle.putString` writes UTF-16 (two bytes a unit), and
/// oneway transactions share an async buffer of about half the 1 MB Binder
/// buffer with everything else in flight. 64K units (128 KB on the wire)
/// keeps a burst of messages well inside it; anything longer (a big result
/// with its dictionary CSS, a large media reply, a long settings list) goes
/// through a file.
const int kSecondScreenInlineMessageUnits = 64 * 1024;

/// A relayed message that stands for the file after the prefix. Messages
/// themselves are JSON objects, so they never start with it.
const String _spilledPrefix = '@file:';

/// Where both ends of one second-screen client's pipe spill big messages: a
/// directory named [client] in the app's temporary directory, which both
/// processes share.
Directory secondScreenSpillRoot(String client) =>
    Directory('${Directory.systemTemp.path}${Platform.pathSeparator}$client');

/// One end of a message pipe between the main engine and the panel on the
/// second display (game stream panel or companion).
///
/// [send] delivers a message or throws: the relay reports whether it took
/// the message (`post` returns true), and a message too big for one Binder
/// transaction is written to a file under [spillDirectory] first. [receive]
/// turns what arrives back into the message, in arrival order.
class SecondScreenPipe {
  SecondScreenPipe({
    required Future<bool?> Function(String raw) post,
    required this.spillDirectory,
    this.inlineLimit = kSecondScreenInlineMessageUnits,
  }) : _post = post;

  final Future<bool?> Function(String raw) _post;
  final Directory spillDirectory;
  final int inlineLimit;
  int _spillCount = 0;
  Future<void> _inbound = Future<void>.value();

  Future<void> send(String message) async {
    File? spilled;
    String raw = message;
    if (message.length > inlineLimit) {
      await spillDirectory.create(recursive: true);
      spilled = File(
        '${spillDirectory.path}${Platform.pathSeparator}'
        '${DateTime.now().microsecondsSinceEpoch}-${_spillCount++}.json',
      );
      await spilled.writeAsString(message, flush: true);
      raw = '$_spilledPrefix${spilled.path}';
    }
    final bool? delivered = await _post(raw);
    if (delivered == true) return;
    if (spilled != null && spilled.existsSync()) await spilled.delete();
    throw StateError('second screen: the relay did not take the message');
  }

  /// Hands each received [raw] to [onMessage] as the message it stands for,
  /// strictly in arrival order (a spilled one is read back and its file
  /// deleted). A message that cannot be read goes to [onError].
  void receive(
    String raw,
    void Function(String message) onMessage,
    void Function(Object error, StackTrace stack) onError,
  ) {
    _inbound = _inbound.then((_) async {
      try {
        onMessage(await _open(raw));
      } catch (error, stack) {
        onError(error, stack);
      }
    });
  }

  static Future<String> _open(String raw) async {
    if (!raw.startsWith(_spilledPrefix)) return raw;
    final File file = File(raw.substring(_spilledPrefix.length));
    try {
      return await file.readAsString();
    } finally {
      if (file.existsSync()) await file.delete();
    }
  }

  /// Deletes [root] and every spilled message in it.
  static Future<void> clearSpills(Directory root) async {
    if (root.existsSync()) await root.delete(recursive: true);
  }
}
