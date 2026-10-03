import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/pages/implementations/home_dashboard_page.dart';

/// BUG-2918：首页「继续」区曾只按 `0 < position < duration` 判「在读」，而阅读器
/// 存的位置是末页首个可见字符——读到最后一页 position 永远 < duration、百分比四舍五入
/// 显示 100%，于是读完的书（`EpubBooks.completedAt` 已置）照样挂在「继续」里。
/// 判据收敛到书架同一条 `classifyShelfReadStatus`：已完成一律不进。
MediaItem _book(String key, {required int position, required int duration}) =>
    MediaItem(
      mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(key),
      title: key,
      mediaTypeIdentifier: ReaderFushiSource.instance.mediaType.uniqueKey,
      mediaSourceIdentifier: ReaderFushiSource.instance.uniqueKey,
      position: position,
      duration: duration,
      canDelete: false,
      canEdit: true,
    );

void main() {
  test('已标记完成的书即使末页位置 < duration 也不进「继续」区', () {
    // 用户报告的原样形态：位置停在末页首字（99.6% → 显示 100%），completedAt 已置。
    final MediaItem finished = _book('done', position: 9960, duration: 10000);
    expect(isDashboardContinueBook(finished, <String>{'done'}), isFalse);
  });

  test('未完成、0 < position < duration 的书仍进「继续」区', () {
    final MediaItem reading = _book('reading', position: 50, duration: 100);
    expect(isDashboardContinueBook(reading, <String>{'other'}), isTrue);
    expect(isDashboardContinueBook(reading, const <String>{}), isTrue);
  });

  test('未开读（position 0）或未知总长（duration 0）不进「继续」区', () {
    expect(
      isDashboardContinueBook(
        _book('fresh', position: 0, duration: 100),
        const <String>{},
      ),
      isFalse,
    );
    expect(
      isDashboardContinueBook(
        _book('nolen', position: 10, duration: 0),
        const <String>{},
      ),
      isFalse,
    );
  });

  test('位置到达 duration 视为读完，不进「继续」区', () {
    expect(
      isDashboardContinueBook(
        _book('end', position: 100, duration: 100),
        const <String>{},
      ),
      isFalse,
    );
  });

  test('完成集合按 bookKey 命中，不受同前缀 key 干扰', () {
    final MediaItem item = _book('book', position: 5, duration: 10);
    expect(isDashboardContinueBook(item, <String>{'book2', 'boo'}), isTrue);
  });
}
