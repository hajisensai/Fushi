import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

void main() {
  RecommendedDictionary catalogEntry(String name) {
    return DictionaryDownloader.catalog.singleWhere(
      (RecommendedDictionary dictionary) => dictionary.name == name,
    );
  }

  test('MarvNC dictionaries use the current direct Yomitan raw host', () {
    final RecommendedDictionary surasura = catalogEntry('surasura');
    final Uri url = Uri.parse(surasura.url);

    expect(url.scheme, 'https');
    expect(url.host, 'raw.githubusercontent.com');
    expect(url.path, startsWith('/MarvNC/yomitan-dictionaries/master/dl/'));
    expect(surasura.url, isNot(contains('yomichan-dictionaries')));
  });

  test('JPDB frequency points at the published release asset', () {
    final RecommendedDictionary jpdb = catalogEntry('JPDB Frequency');
    final Uri url = Uri.parse(jpdb.url);

    expect(url.scheme, 'https');
    expect(url.host, 'github.com');
    expect(url.pathSegments, contains('jpdb-freq-list'));
    expect(url.pathSegments, contains('2022-05-09'));
    expect(jpdb.url, contains('Freq.JPDB_2022-05-10T03_27_02.930Z.zip'));
    expect(jpdb.url, isNot(contains('/releases/latest/')));
    expect(jpdb.url, isNot(contains('JPDB.Frequency.List.zip')));
  });
}
