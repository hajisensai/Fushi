/// Used for searching lyrics.
class HibikiLyrics {
  /// Initialise an instance of this class.
  const HibikiLyrics({
    required this.text,
    required this.includesArtist,
  });

  /// Text of the lyrics.
  final String? text;

  /// Whether or not the artist was used for the search.
  final bool includesArtist;
}

/// Used for searching lyrics.
class HibikiLyricsParameters {
  /// Initialise given parameters.
  const HibikiLyricsParameters({
    required this.artist,
    required this.title,
  });

  /// Artist of the song.
  final String artist;

  /// Title of the song.
  final String title;

  @override
  operator ==(Object other) =>
      other is HibikiLyricsParameters &&
      artist == other.artist &&
      title == other.title;

  @override
  int get hashCode => artist.hashCode * title.hashCode;
}
