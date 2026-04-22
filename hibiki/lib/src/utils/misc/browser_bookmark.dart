/// Used to persist online catalogs of Mokuro manga.
class BrowserBookmark {
  /// Initialise this object.
  BrowserBookmark({
    required this.name,
    required this.url,
    this.id,
  });

  /// Used for database purposes.
  int? id;

  /// Name of the catalog.
  final String name;

  /// The URL pertaining to the catalog.
  final String url;

  @override
  bool operator ==(Object other) => other is BrowserBookmark && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
