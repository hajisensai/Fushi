// 蓝光盘 `BDMV/META/DL/bdmt_<lang>.xml`（disclib）的文件挑选：盘名
// （[readBlurayDiscName]）与盘面图（[readBlurayDiscArtwork]）读同一批文件，选文件
// 的顺序只在这里写一次。

/// `bdmt_<三字母语言码>.xml`；盘上大小写不一（`BDMT_JPN.XML` 也见过）。
final RegExp _metadataFileName = RegExp(
  r'^bdmt_[a-z]{3}\.xml$',
  caseSensitive: false,
);

/// ISO 639-2 codes (bibliographic and terminology forms) a disc may use in
/// `bdmt_<lang>.xml` for a UI language given as an ISO 639-1 code. Unknown
/// languages map to nothing, so the disc's own order decides.
List<String> blurayLanguageCodes(String languageCode) =>
    switch (languageCode.toLowerCase()) {
      'ar' => const <String>['ara'],
      'de' => const <String>['ger', 'deu'],
      'en' => const <String>['eng'],
      'es' => const <String>['spa'],
      'fr' => const <String>['fre', 'fra'],
      'id' => const <String>['ind'],
      'it' => const <String>['ita'],
      'ja' => const <String>['jpn'],
      'ko' => const <String>['kor'],
      'nl' => const <String>['dut', 'nld'],
      'pt' => const <String>['por'],
      'ru' => const <String>['rus'],
      'th' => const <String>['tha'],
      'tr' => const <String>['tur'],
      'vi' => const <String>['vie'],
      'zh' => const <String>['chi', 'zho'],
      _ => const <String>[],
    };

/// Orders `bdmt_<lang>.xml` names (case-insensitive): [preferredLanguages]
/// first, in order, then the rest by file name (libbluray likewise falls back
/// to the first entry when the player language has none). Other names are
/// dropped.
List<String> orderBlurayDiscMetadataFiles(
  Iterable<String> fileNames, {
  required List<String> preferredLanguages,
}) {
  int rank(String name) {
    final String lang = name.substring(5, name.length - 4).toLowerCase();
    final int index = preferredLanguages.indexOf(lang);
    return index < 0 ? preferredLanguages.length : index;
  }

  final List<String> names = <String>[
    for (final String name in fileNames)
      if (_metadataFileName.hasMatch(name)) name,
  ];
  names.sort((String a, String b) {
    final int byRank = rank(a).compareTo(rank(b));
    return byRank != 0 ? byRank : a.compareTo(b);
  });
  return names;
}
