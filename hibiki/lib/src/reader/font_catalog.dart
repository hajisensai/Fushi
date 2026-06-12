import 'dart:convert';

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
