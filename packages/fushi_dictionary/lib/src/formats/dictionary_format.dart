import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import '../models/dictionary_operations_params.dart';

abstract class DictionaryFormat {
  DictionaryFormat({
    required this.uniqueKey,
    required this.name,
    required this.icon,
    required this.allowedExtensions,
    required this.isTextFormat,
    required this.fileType,
    required this.prepareDirectory,
    required this.prepareName,
    required this.prepareEntries,
  });

  late String uniqueKey;
  late String name;
  late IconData icon;
  late List<String> allowedExtensions;
  late bool isTextFormat;
  final FileType fileType;

  Future<void> Function(PrepareDirectoryParams params) prepareDirectory;
  Future<String> Function(PrepareDirectoryParams params) prepareName;

  /// Prepare dictionary entries for import.
  ///
  /// Previously took an Isar instance; will be replaced by hoshidicts (C++ FFI).
  /// The [database] parameter is a dynamic placeholder for the future backend.
  void Function({
    required PrepareDictionaryParams params,
    required dynamic database,
  }) prepareEntries;
}
