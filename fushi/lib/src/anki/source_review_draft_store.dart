import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_anki/fushi_anki.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/sync/remote_source_note.dart';

class SourceReviewMiningDraft {
  const SourceReviewMiningDraft({
    required this.link,
    required this.rawPayloadJson,
    required this.context,
  });
  final CardSourceLink link;
  final String rawPayloadJson;
  final AnkiMiningContext context;
}

class SourceReviewPatchDraft {
  SourceReviewPatchDraft({
    required this.original,
    required Map<String, String> fields,
  }) : fields = Map<String, String>.unmodifiable(fields);
  final AnkiSourceNote original;
  final Map<String, String> fields;
}

class SourceReviewDraft {
  const SourceReviewDraft({
    required this.sourceId,
    this.peerUrl,
    this.peerIdentity,
    this.mining,
    this.patch,
  });
  final String sourceId;
  final String? peerUrl;

  /// Hash of the authenticated pairing, never its plaintext credential.
  /// Null on legacy remote drafts: readable for recovery/discard, not writable.
  final String? peerIdentity;
  final SourceReviewMiningDraft? mining;
  final SourceReviewPatchDraft? patch;
}

/// Local, explicit-recovery drafts. No API calls, background submissions or
/// automatic conflict resolution occur here. Media and the previous manifest
/// remain intact until the replacement manifest is committed.
class SourceReviewDraftStore {
  SourceReviewDraftStore(this.root);
  final Directory root;
  static final Map<String, Future<void>> _locks = <String, Future<void>>{};

  Future<SourceReviewDraft> saveMining({
    required CardSourceLink link,
    required String rawPayloadJson,
    required AnkiMiningContext context,
    String? peerUrl,
    String? peerIdentity,
  }) =>
      _locked(link.sourceId, (Directory directory) async {
        final Object? decoded = jsonDecode(rawPayloadJson);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Invalid mining payload');
        }
        await directory.create(recursive: true);
        final Directory media = Directory(
          p.join(directory.path, 'media-${CardSourceLink.newSourceId()}'),
        );
        await media.create();
        final String? cover =
            await _copyMedia(context.coverPath, media, 'cover');
        final String? sentenceAudio = await _copyMedia(
          context.sentenceAudioPath,
          media,
          'sentence_audio',
        );
        // These are the payload's local media reference slots. Inline data, HTTP
        // URLs and already-rendered Anki references are self-contained references.
        for (final String key in <String>[
          'audio',
          'image',
          'sentenceAudio',
          'cover',
        ]) {
          final Object? ref = decoded[key];
          if (ref is String && _isLocalMedia(ref)) {
            decoded[key] = await _copyMedia(ref, media, 'payload_$key');
          }
        }
        final SourceReviewDraft draft = SourceReviewDraft(
          sourceId: link.sourceId,
          peerUrl: _publicPeerUrl(peerUrl),
          peerIdentity: _validatedPeerIdentity(peerIdentity),
          mining: SourceReviewMiningDraft(
            link: link,
            rawPayloadJson: jsonEncode(decoded),
            context: context
                .withMediaRefs(coverRef: cover, sentenceAudioRef: sentenceAudio)
                .withSourceLink(link),
          ),
        );
        await _commit(directory, draft);
        return draft;
      });

  Future<SourceReviewDraft> savePatch({
    required AnkiSourceNote original,
    required Map<String, String> fields,
    String? peerUrl,
    String? peerIdentity,
  }) =>
      _locked(original.sourceId, (Directory directory) async {
        for (final String field in fields.keys) {
          if (!original.fields.containsKey(field)) {
            throw const FormatException('Patch contains an unknown field');
          }
        }
        final SourceReviewDraft? previous = await _read(
          directory,
          original.sourceId,
        );
        final SourceReviewDraft draft = SourceReviewDraft(
          sourceId: original.sourceId,
          peerUrl: _publicPeerUrl(peerUrl) ?? previous?.peerUrl,
          peerIdentity:
              _validatedPeerIdentity(peerIdentity) ?? previous?.peerIdentity,
          mining: previous?.mining,
          patch: SourceReviewPatchDraft(original: original, fields: fields),
        );
        await directory.create(recursive: true);
        await _commit(directory, draft);
        return draft;
      });

  Future<SourceReviewDraft?> read(String sourceId) =>
      _locked(sourceId, (Directory directory) => _read(directory, sourceId));

  Future<void> delete(String sourceId) => _locked(sourceId, (
        Directory directory,
      ) async {
        if (await directory.exists()) {
          // _directory rejects traversal and symlink/junction escapes before this
          // recursive operation. Only this source UUID's private directory is used.
          await directory.delete(recursive: true);
        }
      });

  Future<T> _locked<T>(
    String sourceId,
    Future<T> Function(Directory directory) action,
  ) async {
    CardSourceLink.markerForSourceId(sourceId);
    final String key = p.normalize(p.absolute(root.path, sourceId));
    final String lockKey = Platform.isWindows ? key.toLowerCase() : key;
    final Future<void> previous = _locks[lockKey] ?? Future<void>.value();
    final Completer<void> release = Completer<void>();
    _locks[lockKey] = release.future;
    await previous;
    try {
      return await action(await _directory(sourceId));
    } finally {
      release.complete();
      if (identical(_locks[lockKey], release.future)) _locks.remove(lockKey);
    }
  }

  Future<Directory> _directory(String sourceId) async {
    final String rootPath = await root.exists()
        ? await root.resolveSymbolicLinks()
        : p.normalize(root.absolute.path);
    final Directory directory = Directory(p.join(rootPath, sourceId));
    final FileSystemEntityType type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw FileSystemException('Invalid draft directory', directory.path);
    }
    final String target = type == FileSystemEntityType.directory
        ? await directory.resolveSymbolicLinks()
        : directory.path;
    if (!p.isWithin(rootPath, target) || p.basename(target) != sourceId) {
      throw FileSystemException('Draft path escapes its root', target);
    }
    return Directory(target);
  }

  Future<String?> _copyMedia(
    String? ref,
    Directory directory,
    String name,
  ) async {
    if (ref == null || ref.isEmpty) return ref;
    if (!_isLocalMedia(ref)) return ref;
    final String path = AnkiAudioRef.localPath(ref);
    final String extension = p.extension(path).toLowerCase();
    final String safeExtension =
        RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension) ? extension : '.bin';
    final File copied = await File(
      path,
    ).copy(p.join(directory.path, '$name$safeExtension'));
    final RandomAccessFile handle = await copied.open(mode: FileMode.append);
    try {
      await handle.flush();
    } finally {
      await handle.close();
    }
    return copied.absolute.path;
  }

  static bool _isLocalMedia(String ref) =>
      ref.isNotEmpty &&
      !ref.startsWith('[sound:') &&
      !ref.startsWith('<') &&
      AnkiAudioRef.classify(ref) == AnkiAudioRefKind.localFile;

  /// Preserve only the public origin. Userinfo, paths, query tokens and fragments
  /// are deliberately excluded from the on-disk ownership hint.
  static String? _publicPeerUrl(String? value) {
    if (value == null) return null;
    final Uri? uri = Uri.tryParse(value);
    if (uri == null ||
        !<String>['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const FormatException('Invalid peer URL');
    }
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    ).toString();
  }

  static String? _validatedPeerIdentity(String? value) {
    if (value != null && !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
      throw const FormatException('Invalid saved pairing identity');
    }
    return value;
  }

  Future<void> _commit(Directory directory, SourceReviewDraft draft) async {
    final String nonce = CardSourceLink.newSourceId();
    final File next = File(p.join(directory.path, 'next-$nonce.json'));
    final File current = File(p.join(directory.path, 'draft.json'));
    final File backup = File(p.join(directory.path, 'previous-$nonce.json'));
    await next.writeAsString(jsonEncode(_encode(draft)), flush: true);
    bool moved = false;
    try {
      if (await current.exists()) {
        await current.rename(backup.path);
        moved = true;
      }
      // Destination no longer exists: works on Windows as well as POSIX.
      await next.rename(current.path);
    } catch (_) {
      if (moved && !await current.exists() && await backup.exists()) {
        await backup.rename(current.path);
      }
      rethrow;
    }
    // Previous generations intentionally survive until cancel/success deletes
    // the draft. They are a crash recovery fallback, including their media.
  }

  Future<SourceReviewDraft?> _read(Directory directory, String sourceId) async {
    if (!await directory.exists()) return null;
    final List<File> backups = <File>[];
    await for (final FileSystemEntity entry in directory.list(
      followLinks: false,
    )) {
      if (entry is File &&
          RegExp(
            r'^previous-[0-9a-f-]+\.json$',
          ).hasMatch(p.basename(entry.path))) {
        backups.add(entry);
      }
    }
    backups.sort(
      (File a, File b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
    );
    final List<File> manifests = <File>[
      File(p.join(directory.path, 'draft.json')),
      ...backups,
    ];
    Object? failure;
    for (final File file in manifests) {
      if (!await file.exists()) continue;
      try {
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw const FormatException('Invalid draft manifest');
        }
        final SourceReviewDraft draft = _decode(
          jsonDecode(await file.readAsString()),
          sourceId,
        );
        final SourceReviewMiningDraft? mining = draft.mining;
        if (mining != null) {
          final Map<String, dynamic> raw =
              jsonDecode(mining.rawPayloadJson) as Map<String, dynamic>;
          final List<String?> paths = <String?>[
            mining.context.coverPath,
            mining.context.sentenceAudioPath,
            for (final String key in <String>[
              'audio',
              'image',
              'sentenceAudio',
              'cover',
            ])
              raw[key] as String?,
          ];
          for (final String? path in paths) {
            if (path == null || !_isLocalMedia(path)) continue;
            final String resolved = await File(
              AnkiAudioRef.localPath(path),
            ).resolveSymbolicLinks();
            if (!p.isWithin(directory.path, resolved)) {
              throw const FormatException('Draft media escapes its directory');
            }
          }
        }
        return draft;
      } catch (error) {
        failure = error;
      }
    }
    if (failure != null) {
      throw StateError('Draft could not be recovered: $failure');
    }
    return null;
  }

  static Map<String, dynamic> _encode(SourceReviewDraft draft) =>
      <String, dynamic>{
        'version': 1,
        'sourceId': draft.sourceId,
        'peerUrl': draft.peerUrl,
        'peerIdentity': draft.peerIdentity,
        if (draft.mining case final SourceReviewMiningDraft mining)
          'mining': <String, dynamic>{
            'link': mining.link.toUri().toString(),
            'rawPayloadJson': mining.rawPayloadJson,
            'context': _encodeContext(mining.context),
          },
        if (draft.patch case final SourceReviewPatchDraft patch)
          'patch': <String, dynamic>{
            'original': encodeRemoteSourceNote(patch.original),
            'fields': patch.fields,
          },
      };

  static SourceReviewDraft _decode(Object? value, String sourceId) {
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        value['sourceId'] != sourceId) {
      throw const FormatException('Invalid draft identity or version');
    }
    SourceReviewMiningDraft? mining;
    SourceReviewPatchDraft? patch;
    final Object? miningJson = value['mining'];
    if (miningJson is Map<String, dynamic>) {
      final CardSourceLink link = CardSourceLink.parse(
        miningJson['link'] as String,
      );
      if (link.sourceId != sourceId) {
        throw const FormatException('Draft source mismatch');
      }
      final String raw = miningJson['rawPayloadJson'] as String;
      if (jsonDecode(raw) is! Map<String, dynamic>) {
        throw const FormatException('Invalid mining payload');
      }
      mining = SourceReviewMiningDraft(
        link: link,
        rawPayloadJson: raw,
        context: _decodeContext(
          miningJson['context'] as Map<String, dynamic>,
          link,
        ),
      );
    }
    final Object? patchJson = value['patch'];
    if (patchJson is Map<String, dynamic>) {
      final AnkiSourceNote original = decodeRemoteSourceNote(
        patchJson['original'],
      );
      if (original.sourceId != sourceId) {
        throw const FormatException('Draft original mismatch');
      }
      patch = SourceReviewPatchDraft(
        original: original,
        fields: decodeRemoteSourceFields(patchJson['fields']),
      );
    }
    if (mining == null && patch == null) {
      throw const FormatException('Empty draft');
    }
    return SourceReviewDraft(
      sourceId: sourceId,
      peerUrl: _publicPeerUrl(value['peerUrl'] as String?),
      peerIdentity: _validatedPeerIdentity(value['peerIdentity'] as String?),
      mining: mining,
      patch: patch,
    );
  }

  static Map<String, dynamic> _encodeContext(AnkiMiningContext context) =>
      <String, dynamic>{
        'sentence': context.sentence,
        'cueSentence': context.cueSentence,
        'documentTitle': context.documentTitle,
        'coverPath': context.coverPath,
        'sentenceAudioPath': context.sentenceAudioPath,
        'sentenceOffset': context.sentenceOffset,
        'source': context.source?.name,
        'bookTitleTag': context.bookTitleTag,
        'collectionTag': context.collectionTag,
        'charPositionTag': context.charPositionTag,
        'clipStartMs': context.clipStartMs,
        'clipEndMs': context.clipEndMs,
        'sourceLink': context.sourceLink?.toUri().toString(),
      };

  static AnkiMiningContext _decodeContext(
    Map<String, dynamic> json,
    CardSourceLink link,
  ) {
    if (json['sourceLink'] != link.toUri().toString()) {
      throw const FormatException('Draft context source mismatch');
    }
    return AnkiMiningContext(
      sentence: json['sentence'] as String,
      cueSentence: json['cueSentence'] as String?,
      documentTitle: json['documentTitle'] as String?,
      coverPath: json['coverPath'] as String?,
      sentenceAudioPath: json['sentenceAudioPath'] as String?,
      sentenceOffset: json['sentenceOffset'] as int?,
      source: json['source'] == null
          ? null
          : AnkiMiningSource.values.byName(json['source'] as String),
      bookTitleTag: json['bookTitleTag'] as String?,
      collectionTag: json['collectionTag'] as String?,
      charPositionTag: json['charPositionTag'] as String?,
      clipStartMs: json['clipStartMs'] as int?,
      clipEndMs: json['clipEndMs'] as int?,
      sourceLink: link,
    );
  }
}
