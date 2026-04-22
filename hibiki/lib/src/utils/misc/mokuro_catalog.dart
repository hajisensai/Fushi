/// Used to persist online catalogs of Mokuro manga.
class MokuroCatalog {
  /// Initialise this object.
  MokuroCatalog({
    required this.name,
    required this.url,
    required this.order,
    this.id,
  });

  /// Used for database purposes.
  int? id;

  /// Name of the catalog.
  final String name;

  /// The URL pertaining to the catalog.
  final String url;

  /// The order of this dictionary in terms of user sorting, relative to other
  /// dictionaries.
  int order;

  @override
  bool operator ==(Object other) => other is MokuroCatalog && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
