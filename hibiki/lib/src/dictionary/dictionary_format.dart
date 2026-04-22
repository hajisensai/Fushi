import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';
import 'package:hibiki/dictionary.dart';
import 'package:flutter/widgets.dart';

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

  void Function({
    required PrepareDictionaryParams params,
    required Isar isar,
  }) prepareEntries;

  Widget customDefinitionWidget({
    required BuildContext context,
    required WidgetRef ref,
    required String definition,
  }) {
    return const SizedBox.shrink();
  }

  String getCustomDefinitionText(String meaning) {
    return meaning;
  }

  bool shouldUseCustomDefinitionWidget(String definition) {
    return false;
  }
}
