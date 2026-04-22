import 'package:json_annotation/json_annotation.dart';

/// A collection of search history items given a certain name.
@JsonSerializable()
class SearchHistoryItem {
  /// Initialise a model mapping with the given parameters.
  SearchHistoryItem({
    required this.historyKey,
    required this.searchTerm,
    this.id,
  });

  /// The key representing the history type of this item.
  final String historyKey;

  /// The name of the model to use when exporting with this mapping.
  final String searchTerm;

  /// Enforces the uniqueness of a search term within its history type.
  String get uniqueKey => '$historyKey/$searchTerm';

  /// A unique identifier for the purposes of database storage.
  int? id;
}
