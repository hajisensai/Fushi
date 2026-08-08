import 'dart:convert';

import 'package:flutter/foundation.dart';

@immutable
class MihonCapabilities {
  const MihonCapabilities({
    required this.bridgeVersion,
    required this.sourceFactory,
    required this.preferenceCallbacks,
    required this.imageProxy,
    required this.sourceUrls,
  });

  factory MihonCapabilities.fromJson(Map<String, Object?> json) =>
      MihonCapabilities(
        bridgeVersion: (json['fushiMihonBridge'] ??
            json['mangatanMihonBridge'] ??
            0) as int,
        sourceFactory: json['sourceFactory'] == true,
        preferenceCallbacks: json['preferenceCallbacks'] == true,
        imageProxy: json['imageProxy'] == true,
        sourceUrls: json['sourceUrls'] == true,
      );

  final int bridgeVersion;
  final bool sourceFactory;
  final bool preferenceCallbacks;
  final bool imageProxy;
  final bool sourceUrls;

  bool get isUsable =>
      bridgeVersion >= 1 &&
      sourceFactory &&
      preferenceCallbacks &&
      imageProxy &&
      sourceUrls;
}

@immutable
class MihonExtensionInspection {
  const MihonExtensionInspection({
    required this.packageName,
    required this.name,
    required this.versionCode,
    required this.versionName,
    required this.libVersion,
    required this.signerSha256,
    required this.sourceClasses,
  });

  factory MihonExtensionInspection.fromJson(Map<String, Object?> json) =>
      MihonExtensionInspection(
        packageName: json['packageName']! as String,
        name: json['name']! as String,
        versionCode: (json['versionCode']! as num).toInt(),
        versionName: json['versionName']! as String,
        libVersion: json['libVersion']! as String,
        signerSha256: json['signerSha256']! as String,
        sourceClasses:
            (json['sourceClasses'] as List<Object?>? ?? const <Object?>[])
                .cast<String>(),
      );

  final String packageName;
  final String name;
  final int versionCode;
  final String versionName;
  final String libVersion;
  final String signerSha256;
  final List<String> sourceClasses;
}

@immutable
class MihonExtensionRef {
  const MihonExtensionRef({
    required this.packageName,
    required this.apkPath,
  });

  final String packageName;
  final String apkPath;
}

@immutable
class MihonSource {
  const MihonSource({
    required this.extensionPackage,
    required this.id,
    required this.name,
    required this.language,
    required this.baseUrl,
  });

  factory MihonSource.fromJson(
    String extensionPackage,
    Map<String, Object?> json,
  ) =>
      MihonSource(
        extensionPackage: extensionPackage,
        id: json['id'].toString(),
        name: json['name']?.toString() ?? '',
        language: (json['lang'] ?? json['language'])?.toString() ?? '',
        baseUrl: (json['baseUrl'] ?? json['homeUrl'])?.toString() ?? '',
      );

  final String extensionPackage;
  final String id;
  final String name;
  final String language;
  final String baseUrl;
}

@immutable
class MihonManga {
  const MihonManga({
    required this.url,
    required this.title,
    this.coverUrl,
    this.artist,
    this.author,
    this.description,
    this.genre,
    this.status = 0,
    this.initialized = false,
  });

  factory MihonManga.fromJson(Map<String, Object?> json) => MihonManga(
        url: json['url']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        coverUrl: (json['thumbnail_url'] ?? json['coverUrl'])?.toString(),
        artist: json['artist']?.toString(),
        author: json['author']?.toString(),
        description: json['description']?.toString(),
        genre: json['genre']?.toString(),
        status: (json['status'] as num?)?.toInt() ?? 0,
        initialized: json['initialized'] == true,
      );

  final String url;
  final String title;
  final String? coverUrl;
  final String? artist;
  final String? author;
  final String? description;
  final String? genre;
  final int status;
  final bool initialized;

  Map<String, Object?> toJson() => <String, Object?>{
        'url': url,
        'title': title,
        'thumbnail_url': coverUrl,
        'artist': artist,
        'author': author,
        'description': description,
        'genre': genre,
        'status': status,
        'initialized': initialized,
      };
}

@immutable
class MihonMangaPage {
  const MihonMangaPage({
    required this.items,
    required this.hasNextPage,
  });

  factory MihonMangaPage.fromJson(Map<String, Object?> json) => MihonMangaPage(
        items: (json['mangas'] as List<Object?>? ?? const <Object?>[])
            .cast<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> value) =>
                MihonManga.fromJson(value.cast<String, Object?>()))
            .toList(growable: false),
        hasNextPage: json['hasNextPage'] == true,
      );

  final List<MihonManga> items;
  final bool hasNextPage;
}

@immutable
class MihonChapter {
  const MihonChapter({
    required this.url,
    required this.name,
    required this.uploadedAt,
    required this.number,
    this.scanlator,
  });

  factory MihonChapter.fromJson(Map<String, Object?> json) => MihonChapter(
        url: json['url']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        uploadedAt: (json['date_upload'] as num?)?.toInt() ?? 0,
        number: (json['chapter_number'] as num?)?.toDouble() ?? 0,
        scanlator: json['scanlator']?.toString(),
      );

  final String url;
  final String name;
  final int uploadedAt;
  final double number;
  final String? scanlator;

  Map<String, Object?> toJson() => <String, Object?>{
        'url': url,
        'name': name,
        'date_upload': uploadedAt,
        'chapter_number': number,
        'scanlator': scanlator,
      };
}

@immutable
class MihonPage {
  const MihonPage({
    required this.index,
    required this.url,
    this.imageUrl,
  });

  factory MihonPage.fromJson(Map<String, Object?> json) => MihonPage(
        index: (json['index'] as num?)?.toInt() ?? 0,
        url: json['url']?.toString() ?? '',
        imageUrl: json['imageUrl']?.toString(),
      );

  final int index;
  final String url;
  final String? imageUrl;

  String get resolvedUrl => imageUrl?.isNotEmpty == true ? imageUrl! : url;
}

enum MihonFilterKind {
  header,
  separator,
  select,
  text,
  checkBox,
  triState,
  group,
  sort,
  unsupported,
}

@immutable
class MihonFilter {
  const MihonFilter({
    required this.name,
    required this.kind,
    this.state,
    this.values = const <String>[],
    this.children = const <MihonFilter>[],
  });

  final String name;
  final MihonFilterKind kind;
  final Object? state;
  final List<String> values;
  final List<MihonFilter> children;

  Map<String, Object?> toBridgeJson() {
    final Map<Object?, Object?>? sortState =
        state is Map<Object?, Object?> ? state as Map<Object?, Object?> : null;
    return <String, Object?>{
      'name': name,
      'type': kind.name,
      if (state is String) 'stateString': state,
      if (state is int) 'stateInt': state,
      if (kind == MihonFilterKind.checkBox)
        'stateList': <Map<String, Object?>>[
          <String, Object?>{'name': name, 'stateBoolean': state == true},
        ],
      if (kind == MihonFilterKind.sort)
        'stateSort': <String, Object?>{
          'index': (sortState?['index'] as num?)?.toInt() ?? 0,
          'ascending': sortState?['ascending'] != false,
        },
      if (children.isNotEmpty)
        'stateList': children
            .map(
              (MihonFilter child) => <String, Object?>{
                'name': child.name,
                'type': child.kind.name,
                if (child.state is bool) 'stateBoolean': child.state,
                if (child.state is int) 'stateInt': child.state,
                if (child.state is String) 'stateString': child.state,
              },
            )
            .toList(growable: false),
    };
  }
}

enum MihonPreferenceKind {
  checkBox,
  switchControl,
  text,
  list,
  multiSelect,
  unsupported,
}

@immutable
class MihonPreference {
  const MihonPreference({
    required this.key,
    required this.kind,
    required this.title,
    required this.value,
    this.summary = '',
    this.entries = const <String>[],
    this.entryValues = const <String>[],
  });

  factory MihonPreference.fromBridgeJson(Map<String, Object?> json) {
    const Map<String, MihonPreferenceKind> kinds =
        <String, MihonPreferenceKind>{
      'checkBoxPreference': MihonPreferenceKind.checkBox,
      'switchPreferenceCompat': MihonPreferenceKind.switchControl,
      'editTextPreference': MihonPreferenceKind.text,
      'listPreference': MihonPreferenceKind.list,
      'multiSelectListPreference': MihonPreferenceKind.multiSelect,
    };
    final String payloadKey = kinds.keys.firstWhere(
      json.containsKey,
      orElse: () => '',
    );
    final Map<String, Object?> props =
        (json[payloadKey] as Map<Object?, Object?>? ??
                const <Object?, Object?>{})
            .cast<String, Object?>();
    final MihonPreferenceKind decodedKind =
        kinds[payloadKey] ?? MihonPreferenceKind.unsupported;
    final List<String> entries =
        (props['entries'] as List<Object?>? ?? const <Object?>[])
            .map((Object? entry) => entry.toString())
            .toList(growable: false);
    final List<String> entryValues =
        (props['entryValues'] as List<Object?>? ?? const <Object?>[])
            .map((Object? entry) => entry.toString())
            .toList(growable: false);
    final MihonPreferenceKind kind =
        (decodedKind == MihonPreferenceKind.list && entries.isEmpty) ||
                (decodedKind == MihonPreferenceKind.multiSelect &&
                    (entries.isEmpty || entryValues.length != entries.length))
            ? MihonPreferenceKind.unsupported
            : decodedKind;
    final Object? value = switch (kind) {
      MihonPreferenceKind.checkBox ||
      MihonPreferenceKind.switchControl =>
        props['value'] ?? false,
      MihonPreferenceKind.text => props['value'] ?? '',
      MihonPreferenceKind.list => props['valueIndex'] ?? 0,
      MihonPreferenceKind.multiSelect =>
        (props['values'] as List<Object?>? ?? const <Object?>[])
            .map((Object? value) => value.toString())
            .toList(growable: false),
      MihonPreferenceKind.unsupported => null,
    };
    return MihonPreference(
      key: json['key']?.toString() ?? '',
      kind: kind,
      title: props['title']?.toString() ?? json['key']?.toString() ?? '',
      summary: props['summary']?.toString() ?? '',
      value: value,
      entries: entries,
      entryValues: entryValues,
    );
  }

  final String key;
  final MihonPreferenceKind kind;
  final String title;
  final String summary;
  final Object? value;
  final List<String> entries;
  final List<String> entryValues;

  String encodeValue() => jsonEncode(value);

  Map<String, Object?> toBridgeJson() {
    final String payloadKey = switch (kind) {
      MihonPreferenceKind.checkBox => 'checkBoxPreference',
      MihonPreferenceKind.switchControl => 'switchPreferenceCompat',
      MihonPreferenceKind.text => 'editTextPreference',
      MihonPreferenceKind.list => 'listPreference',
      MihonPreferenceKind.multiSelect => 'multiSelectListPreference',
      MihonPreferenceKind.unsupported => 'unsupportedPreference',
    };
    return <String, Object?>{
      'key': key,
      payloadKey: <String, Object?>{
        'title': title,
        'summary': summary,
        if (kind == MihonPreferenceKind.checkBox ||
            kind == MihonPreferenceKind.switchControl ||
            kind == MihonPreferenceKind.text)
          'value': value,
        if (kind == MihonPreferenceKind.list) 'valueIndex': value,
        if (kind == MihonPreferenceKind.multiSelect) 'values': value,
        if (entries.isNotEmpty) 'entries': entries,
        if (entryValues.isNotEmpty) 'entryValues': entryValues,
      },
    };
  }
}

class MihonRuntimeException implements Exception {
  const MihonRuntimeException(this.code, this.message, {this.cause});

  final String code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'MihonRuntimeException($code): $message';
}
