import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/aidoku/aidoku_repository_client.dart';
import 'package:fushi/src/storage/app_paths.dart';

class AidokuSavedRepository {
  const AidokuSavedRepository({
    required this.name,
    required this.indexUrl,
    required this.addedAt,
  });

  factory AidokuSavedRepository.fromJson(Map<String, Object?> json) =>
      AidokuSavedRepository(
        name: json['name']?.toString() ?? '',
        indexUrl: json['indexUrl']?.toString() ?? '',
        addedAt: DateTime.tryParse(json['addedAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );

  factory AidokuSavedRepository.fromIndex(AidokuRepositoryIndex index) =>
      AidokuSavedRepository(
        name: index.name,
        indexUrl: index.indexUri.toString(),
        addedAt: DateTime.now().toUtc(),
      );

  final String name;
  final String indexUrl;
  final DateTime addedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'indexUrl': indexUrl,
        'addedAt': addedAt.toIso8601String(),
      };
}

class AidokuRepositoryStore {
  AidokuRepositoryStore(this.file);

  static Future<AidokuRepositoryStore> open() async {
    final Directory supportRoot = await AppPaths.supportRootDirectory();
    return AidokuRepositoryStore(
      File(
        p.join(
          supportRoot.path,
          'manga_extensions',
          'aidoku_repositories',
          'repositories.json',
        ),
      ),
    );
  }

  final File file;

  Future<List<AidokuSavedRepository>> list() async {
    if (!await file.exists()) return const <AidokuSavedRepository>[];
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! List<Object?>) return const <AidokuSavedRepository>[];
      final List<AidokuSavedRepository> repositories =
          <AidokuSavedRepository>[];
      for (final Object? entry in decoded) {
        if (entry is! Map<Object?, Object?>) continue;
        final AidokuSavedRepository repository =
            AidokuSavedRepository.fromJson(entry.cast<String, Object?>());
        if (repository.name.isEmpty || repository.indexUrl.isEmpty) continue;
        repositories.add(repository);
      }
      repositories.sort(
        (AidokuSavedRepository a, AidokuSavedRepository b) =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      return repositories;
    } on Object {
      return const <AidokuSavedRepository>[];
    }
  }

  Future<List<AidokuSavedRepository>> add(AidokuRepositoryIndex index) async {
    final List<AidokuSavedRepository> repositories =
        List<AidokuSavedRepository>.of(await list());
    final AidokuSavedRepository saved = AidokuSavedRepository.fromIndex(index);
    repositories.removeWhere(
      (AidokuSavedRepository repository) =>
          repository.indexUrl == saved.indexUrl,
    );
    repositories.add(saved);
    await _write(repositories);
    return list();
  }

  Future<List<AidokuSavedRepository>> remove(
    AidokuSavedRepository repository,
  ) async {
    final List<AidokuSavedRepository> repositories =
        List<AidokuSavedRepository>.of(await list())
          ..removeWhere(
            (AidokuSavedRepository entry) =>
                entry.indexUrl == repository.indexUrl,
          );
    await _write(repositories);
    return list();
  }

  Future<void> _write(List<AidokuSavedRepository> repositories) async {
    await file.parent.create(recursive: true);
    final File staged = File('${file.path}.new');
    await staged.writeAsString(
      jsonEncode(
        repositories
            .map((AidokuSavedRepository repository) => repository.toJson())
            .toList(growable: false),
      ),
      flush: true,
    );
    await staged.rename(file.path);
  }
}
