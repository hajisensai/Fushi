import 'dart:convert';

import 'package:path/path.dart' as p;

class FontCatalogState {
  const FontCatalogState({
    required this.fonts,
    required this.targets,
  });

  static const int version = 1;

  final List<FontCatalogEntry> fonts;
  final Map<String, List<FontTargetFont>> targets;

  static FontCatalogState? tryParse({
    required String catalogJson,
    required String targetsJson,
    required Iterable<String> targetKeys,
  }) {
    try {
      final Map<String, dynamic> catalog =
          (jsonDecode(catalogJson) as Map<dynamic, dynamic>)
              .cast<String, dynamic>();
      final Map<String, dynamic> targetRoot =
          (jsonDecode(targetsJson) as Map<dynamic, dynamic>)
              .cast<String, dynamic>();
      if (catalog['version'] != version || targetRoot['version'] != version) {
        return null;
      }
      final List<dynamic> fontRows = catalog['fonts'] as List<dynamic>;
      final List<FontCatalogEntry> fonts = <FontCatalogEntry>[];
      final Set<String> ids = <String>{};
      for (final dynamic row in fontRows) {
        final FontCatalogEntry? entry = FontCatalogEntry.fromJson(row);
        if (entry == null || ids.contains(entry.id)) return null;
        ids.add(entry.id);
        fonts.add(entry);
      }

      final Map<String, dynamic> targetRows =
          (targetRoot['targets'] as Map<dynamic, dynamic>)
              .cast<String, dynamic>();
      final Map<String, List<FontTargetFont>> targets =
          <String, List<FontTargetFont>>{};
      for (final String key in targetKeys) {
        final dynamic rawRows = targetRows[key];
        if (rawRows == null) {
          continue;
        }
        if (rawRows is! List<dynamic>) return null;
        final List<FontTargetFont> parsedRows = <FontTargetFont>[];
        for (final dynamic row in rawRows) {
          final FontTargetFont? parsed =
              FontTargetFont.fromJson(row, knownFontIds: ids);
          if (parsed != null) parsedRows.add(parsed);
        }
        targets[key] = parsedRows;
      }
      return FontCatalogState(fonts: fonts, targets: targets);
    } catch (_) {
      return null;
    }
  }

  factory FontCatalogState.empty() {
    return FontCatalogState(
      fonts: <FontCatalogEntry>[],
      targets: <String, List<FontTargetFont>>{},
    );
  }

  factory FontCatalogState.fromLegacy(
    Map<String, List<Map<String, dynamic>>> legacyByTarget,
  ) {
    final List<FontCatalogEntry> fonts = <FontCatalogEntry>[];
    final Map<String, String> idByIdentity = <String, String>{};
    final Set<String> ids = <String>{};
    int nextId = 1;

    String reserveId() {
      while (ids.contains('font_$nextId')) {
        nextId += 1;
      }
      final String id = 'font_$nextId';
      ids.add(id);
      nextId += 1;
      return id;
    }

    final Map<String, List<FontTargetFont>> targets =
        <String, List<FontTargetFont>>{};
    for (final MapEntry<String, List<Map<String, dynamic>>> target
        in legacyByTarget.entries) {
      final List<FontTargetFont> rows = <FontTargetFont>[];
      for (final Map<String, dynamic> font in target.value) {
        final FontListFont? listFont = FontListFont.fromMap(font);
        if (listFont == null) continue;
        final String identity =
            FontCatalogEntry.identityOf(listFont.name, listFont.path);
        String? id = idByIdentity[identity];
        if (id == null) {
          id = reserveId();
          idByIdentity[identity] = id;
          fonts.add(FontCatalogEntry(
            id: id,
            name: listFont.name,
            path: listFont.path,
          ));
        }
        rows.add(FontTargetFont(fontId: id, enabled: listFont.enabled));
      }
      targets[target.key] = rows;
    }

    return FontCatalogState(fonts: fonts, targets: targets);
  }

  FontCatalogState withTargetFonts(
    String targetKey,
    List<Map<String, dynamic>> targetFonts,
  ) {
    final List<FontCatalogEntry> nextFonts = <FontCatalogEntry>[...fonts];
    final Set<String> ids =
        nextFonts.map((FontCatalogEntry font) => font.id).toSet();
    final Map<String, String> idByIdentity = <String, String>{
      for (final FontCatalogEntry font in nextFonts) font.identity: font.id,
    };
    int nextId = _nextGeneratedId(ids);

    String reserveId() {
      while (ids.contains('font_$nextId')) {
        nextId += 1;
      }
      final String id = 'font_$nextId';
      ids.add(id);
      nextId += 1;
      return id;
    }

    final List<FontTargetFont> rows = <FontTargetFont>[];
    for (final Map<String, dynamic> font in targetFonts) {
      final FontListFont? listFont = FontListFont.fromMap(font);
      if (listFont == null) continue;
      final String identity =
          FontCatalogEntry.identityOf(listFont.name, listFont.path);
      String? id = idByIdentity[identity];
      if (id == null) {
        id = reserveId();
        idByIdentity[identity] = id;
        nextFonts.add(FontCatalogEntry(
          id: id,
          name: listFont.name,
          path: listFont.path,
        ));
      }
      rows.add(FontTargetFont(fontId: id, enabled: listFont.enabled));
    }

    return FontCatalogState(
      fonts: nextFonts,
      targets: <String, List<FontTargetFont>>{
        ...targets,
        targetKey: rows,
      },
    );
  }

  List<Map<String, dynamic>> fontListForTarget(String targetKey) {
    final Map<String, FontCatalogEntry> fontsById = <String, FontCatalogEntry>{
      for (final FontCatalogEntry font in fonts) font.id: font,
    };
    return <Map<String, dynamic>>[
      for (final FontTargetFont row
          in targets[targetKey] ?? const <FontTargetFont>[])
        if (fontsById[row.fontId] != null)
          fontsById[row.fontId]!.toFontListMap(enabled: row.enabled),
    ];
  }

  bool hasTarget(String targetKey) => targets.containsKey(targetKey);

  Map<String, dynamic> toCatalogJson() {
    return <String, dynamic>{
      'version': version,
      'fonts': <Map<String, dynamic>>[
        for (final FontCatalogEntry font in fonts) font.toJson(),
      ],
    };
  }

  Map<String, dynamic> toTargetsJson() {
    return <String, dynamic>{
      'version': version,
      'targets': <String, dynamic>{
        for (final MapEntry<String, List<FontTargetFont>> target
            in targets.entries)
          target.key: <Map<String, dynamic>>[
            for (final FontTargetFont row in target.value) row.toJson(),
          ],
      },
    };
  }

  static int _nextGeneratedId(Set<String> ids) {
    final RegExp generatedId = RegExp(r'^font_(\d+)$');
    int next = 1;
    for (final String id in ids) {
      final RegExpMatch? match = generatedId.firstMatch(id);
      final int? value =
          match == null ? null : int.tryParse(match.group(1) ?? '');
      if (value != null && value >= next) {
        next = value + 1;
      }
    }
    return next;
  }
}

class FontCatalogEntry {
  const FontCatalogEntry({
    required this.id,
    required this.name,
    required this.path,
  });

  final String id;
  final String name;
  final String? path;

  String get identity => identityOf(name, path);

  static FontCatalogEntry? fromJson(dynamic row) {
    if (row is! Map<dynamic, dynamic>) return null;
    final String? id = _stringOrNull(row['id']);
    final String? name = _stringOrNull(row['name']);
    if (id == null || id.isEmpty || name == null || name.isEmpty) {
      return null;
    }
    return FontCatalogEntry(
      id: id,
      name: name,
      path: _nullableString(row['path']),
    );
  }

  static String identityOf(String name, String? path) {
    return '$name\u0000${path ?? ''}';
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'path': path,
    };
  }

  Map<String, dynamic> toFontListMap({required bool enabled}) {
    return <String, dynamic>{
      'name': name,
      'path': path,
      'enabled': enabled,
    };
  }
}

class FontTargetFont {
  const FontTargetFont({
    required this.fontId,
    required this.enabled,
  });

  final String fontId;
  final bool enabled;

  static FontTargetFont? fromJson(
    dynamic row, {
    required Set<String> knownFontIds,
  }) {
    if (row is! Map<dynamic, dynamic>) return null;
    final String? fontId = _stringOrNull(row['fontId']);
    if (fontId == null || !knownFontIds.contains(fontId)) return null;
    final dynamic enabled = row['enabled'];
    return FontTargetFont(
      fontId: fontId,
      enabled: enabled is bool ? enabled : true,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'fontId': fontId,
      'enabled': enabled,
    };
  }
}

class FontListFont {
  const FontListFont({
    required this.name,
    required this.path,
    required this.enabled,
  });

  final String name;
  final String? path;
  final bool enabled;

  static FontListFont? fromMap(Map<String, dynamic> row) {
    final String? name = _stringOrNull(row['name']);
    if (name == null || name.isEmpty) return null;
    final dynamic enabled = row['enabled'];
    return FontListFont(
      name: name,
      path: _nullableString(row['path']),
      enabled: enabled is bool ? enabled : true,
    );
  }
}

String? _stringOrNull(dynamic value) {
  return value is String ? value : null;
}

String? _nullableString(dynamic value) {
  if (value == null) return null;
  return value is String ? value : null;
}

/// Extracts a file's basename from [path] regardless of separator style. Font
/// paths are created and consumed on the same device, but a stored value may use
/// `\` (Windows) or `/` (POSIX); split on whichever separator appears last so
/// relocation still works if the value crossed a separator boundary (e.g. a
/// profile export stripped the root to a leading-separator relative path).
String fontPathBasename(String path) {
  final int slash = path.lastIndexOf('/');
  final int back = path.lastIndexOf('\\');
  final int cut = slash > back ? slash : back;
  return cut < 0 ? path : path.substring(cut + 1);
}

/// TODO-1393 self-heal: relocates every file-font `path` inside the canonical
/// font-catalog JSON (`{version, fonts:[{id, name, path}]}`) whose stored file no
/// longer resolves ([fileExists] returns false) onto a same-basename file that
/// DOES exist under [currentFontsDir]. Entries whose path still resolves, system
/// fonts (`path == null`), and entries with no recoverable same-basename file are
/// left untouched. A malformed value is returned verbatim (relocated: 0) so a
/// corrupt pref never aborts the heal.
///
/// This is the read-side counterpart to `rebaseFontCatalogJson`: rebase runs once
/// during an explicit data-root move / backup import / profile export; relocate is
/// an idempotent startup self-heal that recovers paths the forward rebase did not
/// (or could not) cover — a pre-fix backup restore (the 2026-06-11..13 shadow-only
/// window that never rebased `font_catalog`), a partially-failed migration, an iOS
/// reinstall's new container UUID, or a profile-import stripped path. Because the
/// import copies every font as `<name>_<ms>.<ext>` the basename is unique, so the
/// match is unambiguous.
({String json, int relocated}) relocateMissingFontCatalogPaths(
  String json,
  String currentFontsDir,
  bool Function(String path) fileExists,
) {
  try {
    final dynamic decoded = jsonDecode(json);
    if (decoded is! Map) return (json: json, relocated: 0);
    final Map<String, dynamic> root = Map<String, dynamic>.from(decoded);
    final dynamic fonts = root['fonts'];
    if (fonts is! List) return (json: json, relocated: 0);
    int relocated = 0;
    root['fonts'] = fonts.map<dynamic>((dynamic e) {
      if (e is! Map) return e;
      final Map<String, dynamic> row = Map<String, dynamic>.from(e);
      final String? next =
          _relocatedFontPath(row['path'], currentFontsDir, fileExists);
      if (next != null) {
        row['path'] = next;
        relocated += 1;
      }
      return row;
    }).toList();
    if (relocated == 0) return (json: json, relocated: 0);
    return (json: jsonEncode(root), relocated: relocated);
  } catch (_) {
    return (json: json, relocated: 0); // never throw on a corrupt pref value
  }
}

/// Same TODO-1393 self-heal for a legacy shadow font-list JSON
/// (`[{name, path, enabled}, ...]`). Kept in lock-step with
/// [relocateMissingFontCatalogPaths] so the catalog and its shadow lists relocate
/// to the same recovered paths and stay consistent.
({String json, int relocated}) relocateMissingFontListPaths(
  String json,
  String currentFontsDir,
  bool Function(String path) fileExists,
) {
  try {
    final dynamic decoded = jsonDecode(json);
    if (decoded is! List) return (json: json, relocated: 0);
    int relocated = 0;
    final List<dynamic> out = decoded.map<dynamic>((dynamic e) {
      if (e is! Map) return e;
      final Map<String, dynamic> row = Map<String, dynamic>.from(e);
      final String? next =
          _relocatedFontPath(row['path'], currentFontsDir, fileExists);
      if (next != null) {
        row['path'] = next;
        relocated += 1;
      }
      return row;
    }).toList();
    if (relocated == 0) return (json: json, relocated: 0);
    return (json: jsonEncode(out), relocated: relocated);
  } catch (_) {
    return (json: json, relocated: 0); // never throw on a corrupt pref value
  }
}

/// Returns the recovered absolute path for a stored font [rawPath] when it is a
/// non-empty string that does NOT currently resolve but a same-basename file DOES
/// exist under [currentFontsDir]; otherwise null (leave the entry as-is — a still
/// valid path is never touched, and an unrecoverable one stays so the loader keeps
/// its existing skip-missing behavior with no data loss).
String? _relocatedFontPath(
  Object? rawPath,
  String currentFontsDir,
  bool Function(String path) fileExists,
) {
  if (rawPath is! String || rawPath.isEmpty) return null; // system font / odd
  if (fileExists(rawPath)) return null; // still valid — never relocate
  final String candidate = p.join(currentFontsDir, fontPathBasename(rawPath));
  if (candidate == rawPath) return null; // already points here, still missing
  if (!fileExists(candidate)) return null; // no recoverable file — leave as-is
  return candidate;
}
