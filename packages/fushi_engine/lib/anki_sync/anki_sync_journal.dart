import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// 一张已经渲染好、可以直接交给 `add_note` 的卡。
class AnkiSyncNote {
  const AnkiSyncNote({
    required this.notetype,
    required this.deck,
    required this.fields,
    this.tags = const <String>[],
    this.media = const <(String, String)>[],
    this.allowDuplicate = false,
  });

  factory AnkiSyncNote.fromJson(Map<String, Object?> json) => AnkiSyncNote(
    notetype: json['notetype']! as String,
    deck: json['deck']! as String,
    fields: <String>[
      for (final Object? f in json['fields']! as List) f! as String,
    ],
    tags: <String>[for (final Object? t in json['tags']! as List) t! as String],
    media: <(String, String)>[
      for (final Object? m in json['media']! as List)
        if (m case [final String name, final String path]) (name, path),
    ],
    allowDuplicate: json['allowDuplicate'] == true,
  );

  final String notetype;
  final String deck;

  /// 按笔记类型字段顺序排好的值。
  final List<String> fields;
  final List<String> tags;

  /// （Anki 媒体名, 本地源路径）。媒体名按内容哈希，同名即同内容。
  final List<(String, String)> media;

  /// 用户这次明确要「新增为重复卡」：重放时不做查重。
  final bool allowDuplicate;

  AnkiSyncNote withMedia(List<(String, String)> media) => AnkiSyncNote(
    notetype: notetype,
    deck: deck,
    fields: fields,
    tags: tags,
    media: media,
    allowDuplicate: allowDuplicate,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'notetype': notetype,
    'deck': deck,
    'fields': fields,
    'tags': tags,
    'media': <List<String>>[
      for (final (String name, String path) in media) <String>[name, path],
    ],
    'allowDuplicate': allowDuplicate,
  };
}

/// 日志里的一条：一张**还没被同步确认**的卡。
class AnkiSyncJournalEntry {
  const AnkiSyncJournalEntry({
    required this.id,
    required this.createdAt,
    required this.note,
    this.noteId,
    this.guid,
    this.lastError,
  });

  factory AnkiSyncJournalEntry.fromJson(Map<String, Object?> json) =>
      AnkiSyncJournalEntry(
        id: json['id']! as String,
        createdAt: (json['createdAt']! as num).toInt(),
        note: AnkiSyncNote.fromJson(
          (json['note']! as Map).cast<String, Object?>(),
        ),
        noteId: (json['noteId'] as num?)?.toInt(),
        guid: json['guid'] as String?,
        lastError: json['lastError'] as String?,
      );

  final String id;
  final int createdAt;
  final AnkiSyncNote note;

  /// 最近一次写进本地库拿到的 note id。它**不**说明卡此刻还在库里（整库下载会冲掉），
  /// 是否在库里每次都向 helper 核对（`existing_notes`）；null = 还没写进去。
  final int? noteId;

  /// 那张笔记的 guid（跨同步不变）。核对「还在不在」按 (note id, guid)：
  /// 字段内容会被 rslib 规范化，不能拿来比。
  final String? guid;

  /// 最近一次写进本地库失败的原因（下次打开 / 同步时再试）。
  final String? lastError;

  String get firstField => note.fields.isEmpty ? '' : note.fields.first;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'createdAt': createdAt,
    'note': note.toJson(),
    if (noteId != null) 'noteId': noteId,
    if (guid != null) 'guid': guid,
    if (lastError != null) 'lastError': lastError,
  };
}

/// 「未同步的卡」日志：Fushi 这边的真相源。
///
/// 本地 collection 不可信——服务器要求整库同步时，整库下载会**静默丢掉**本地还没推上去
/// 的卡。所以每张卡先进日志、再进本地库；只有「同步成功之后，它的 note id 确实还在
/// 本地库里」才出日志；不在的一律重新写进去再同步。
///
/// 一条一个文件（`<dir>/<id>.json`，`.tmp` → rename 原子写），媒体复制进
/// `<dir>/media/`（内容哈希名，天然去重），不依赖制卡时那些临时文件还在不在。
/// 所有读写串行（[_locked]）：清理媒体不会删掉正在写入的条目的媒体；Windows 上
/// 覆盖一个正被读的文件会失败，读写也不能并发。
class AnkiSyncJournal {
  AnkiSyncJournal(this.dir, {int Function()? clock})
    : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Directory dir;
  final int Function() _clock;
  static final Random _random = Random.secure();
  Future<void> _tail = Future<void>.value();

  Directory get _mediaDir => Directory(p.join(dir.path, 'media'));

  /// 写一条（还不在本地库里）。媒体先复制进日志目录，条目里的路径随之改指那里。
  Future<AnkiSyncJournalEntry> append(AnkiSyncNote note) => _locked(() async {
    await _mediaDir.create(recursive: true);
    final List<(String, String)> media = <(String, String)>[];
    for (final (String name, String source) in note.media) {
      final File target = File(p.join(_mediaDir.path, name));
      if (!target.existsSync()) {
        final File tmp = File('${target.path}.tmp');
        await File(source).copy(tmp.path);
        await tmp.rename(target.path);
      }
      media.add((name, target.path));
    }
    final AnkiSyncJournalEntry entry = AnkiSyncJournalEntry(
      id: _newId(),
      createdAt: _clock(),
      note: note.withMedia(media),
    );
    await _write(entry);
    return entry;
  });

  /// 写进了本地库（或查到库里已有同词卡），笔记为 [noteId] / [guid]。
  Future<void> markAdded(AnkiSyncJournalEntry entry, int noteId, String guid) =>
      _locked(
        () => _write(
          AnkiSyncJournalEntry(
            id: entry.id,
            createdAt: entry.createdAt,
            note: entry.note,
            noteId: noteId,
            guid: guid,
          ),
        ),
      );

  /// 写进本地库失败：记下原因，条目留着下次再试。
  Future<void> markFailed(AnkiSyncJournalEntry entry, String error) => _locked(
    () => _write(
      AnkiSyncJournalEntry(
        id: entry.id,
        createdAt: entry.createdAt,
        note: entry.note,
        noteId: entry.noteId,
        guid: entry.guid,
        lastError: error,
      ),
    ),
  );

  /// 全部条目，按写入先后。读不出的文件跳过（它们不会被 [remove] 删掉，留给人看）。
  Future<List<AnkiSyncJournalEntry>> entries() => _locked(_entries);

  Future<int> count() async => (await entries()).length;

  /// 出日志（同步确认 / 加卡失败回滚 / 用户放弃），再清掉没有条目引用的媒体。
  Future<void> remove(Iterable<String> ids) => _locked(() async {
    for (final String id in ids) {
      final File f = File(p.join(dir.path, '$id.json'));
      if (f.existsSync()) await f.delete();
    }
    if (!_mediaDir.existsSync()) return;
    final Set<String> kept = <String>{
      for (final AnkiSyncJournalEntry e in await _entries())
        for (final (String name, String _) in e.note.media) name,
    };
    for (final FileSystemEntity f in _mediaDir.listSync()) {
      if (f is File && !kept.contains(p.basename(f.path))) await f.delete();
    }
  });

  Future<List<AnkiSyncJournalEntry>> _entries() async {
    if (!dir.existsSync()) return const <AnkiSyncJournalEntry>[];
    final List<AnkiSyncJournalEntry> out = <AnkiSyncJournalEntry>[];
    for (final FileSystemEntity f in dir.listSync()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        out.add(
          AnkiSyncJournalEntry.fromJson(
            (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>(),
          ),
        );
      } catch (_) {
        continue;
      }
    }
    out.sort(
      (AnkiSyncJournalEntry a, AnkiSyncJournalEntry b) =>
          a.createdAt.compareTo(b.createdAt),
    );
    return out;
  }

  Future<T> _locked<T>(Future<T> Function() action) {
    final Future<T> run = _tail.then((_) => action());
    _tail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> _write(AnkiSyncJournalEntry entry) async {
    await dir.create(recursive: true);
    final File target = File(p.join(dir.path, '${entry.id}.json'));
    final File tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(entry.toJson()), flush: true);
    await tmp.rename(target.path);
  }

  String _newId() {
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < 16; i++) {
      b.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }
}
