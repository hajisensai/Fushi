import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// SourceLibraryKind(来源库 mediaKind 值域)冻结守卫:dbValue 是
/// `MediaSources.mediaKind` 的落库串,改一个字符存量来源库全部失配。
void main() {
  test('dbValue 逐字节冻结', () {
    expect(SourceLibraryKind.book.dbValue, 'book');
    expect(SourceLibraryKind.video.dbValue, 'video');
    expect(SourceLibraryKind.manga.dbValue, 'manga');
    expect(SourceLibraryKind.values, hasLength(3),
        reason: '新增来源库种类必须同步扫描/统计/对话框的穷尽 switch 与本守卫');
  });

  test('tryParse:落库串双向、未知/跨域串拒斥', () {
    expect(SourceLibraryKind.tryParse('book'), SourceLibraryKind.book);
    expect(SourceLibraryKind.tryParse('video'), SourceLibraryKind.video);
    expect(SourceLibraryKind.tryParse('manga'), SourceLibraryKind.manga);
    expect(SourceLibraryKind.tryParse('epub'), isNull,
        reason: 'MediaKind 的值域串不属于来源库值域(book≠epub 是真实语义差)');
    expect(SourceLibraryKind.tryParse('game'), isNull);
    expect(SourceLibraryKind.tryParse(''), isNull);
    expect(SourceLibraryKind.tryParse(null), isNull);
  });
}
