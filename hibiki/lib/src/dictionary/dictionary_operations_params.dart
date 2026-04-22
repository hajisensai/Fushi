import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:hibiki/dictionary.dart';

class IsolateParams {
  IsolateParams({
    required this.sendPort,
    required this.directoryPath,
  });

  final SendPort sendPort;
  final String directoryPath;

  void send(Object? message) {
    sendPort.send(message);
  }
}

class PrepareDirectoryParams extends IsolateParams {
  PrepareDirectoryParams({
    required this.file,
    required this.charset,
    required this.resourceDirectory,
    required this.dictionaryFormat,
    required super.sendPort,
    required super.directoryPath,
  });

  final File file;
  final String charset;
  final Directory resourceDirectory;
  final DictionaryFormat dictionaryFormat;
}

class PrepareDictionaryParams extends IsolateParams {
  PrepareDictionaryParams({
    required this.dictionary,
    required this.dictionaryFormat,
    required this.resourceDirectory,
    required this.alertSendPort,
    required super.sendPort,
    required super.directoryPath,
  });

  final Dictionary dictionary;
  final DictionaryFormat dictionaryFormat;
  final Directory resourceDirectory;
  final SendPort alertSendPort;

  void sendAlert({required String message}) {
    alertSendPort.send(message);
  }
}

class DeleteDictionaryParams extends IsolateParams {
  DeleteDictionaryParams({
    required super.sendPort,
    required super.directoryPath,
    this.dictionaryName,
  });

  final String? dictionaryName;
}

class UpdateDictionaryHistoryParams extends IsolateParams {
  UpdateDictionaryHistoryParams({
    required this.resultId,
    required this.newPosition,
    required this.maximumDictionaryHistoryItems,
    required super.sendPort,
    required super.directoryPath,
  });

  final int resultId;
  final int newPosition;
  final int maximumDictionaryHistoryItems;
}

class DictionarySearchParams extends IsolateParams {
  DictionarySearchParams({
    required this.searchTerm,
    required this.maximumDictionarySearchResults,
    required this.maximumDictionaryTermsInResult,
    required this.searchWithWildcards,
    required this.dictionaryPaths,
    required super.sendPort,
    required super.directoryPath,
  });

  final String searchTerm;
  final int maximumDictionarySearchResults;
  final int maximumDictionaryTermsInResult;
  final bool searchWithWildcards;
  final List<String> dictionaryPaths;

  @override
  bool operator ==(Object other) =>
      other is DictionarySearchParams &&
      searchTerm == other.searchTerm &&
      maximumDictionaryTermsInResult == other.maximumDictionaryTermsInResult &&
      searchWithWildcards == other.searchWithWildcards;

  @override
  int get hashCode => searchTerm.hashCode;
}
