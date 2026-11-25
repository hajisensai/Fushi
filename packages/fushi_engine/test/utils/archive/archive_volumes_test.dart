// 分卷归档的文件名判据，以及导入入口（发现页 / torrent 整包分类）怎么用它：第一卷当整个包，
// 后续卷不单独导入。
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/discovery/import/discovery_import_plan.dart';
import 'package:fushi_engine/utils/archive/archive_volumes.dart';
import 'package:test/test.dart';

void main() {
  test('认出 7z / zip 分卷，返回去掉编号的路径与编号', () {
    expect(splitArchiveVolume('/dl/合集.7z.001'), (
      archivePath: '/dl/合集.7z',
      number: 1,
    ));
    expect(splitArchiveVolume(r'C:\dl\book.ZIP.0012'), (
      archivePath: r'C:\dl\book.ZIP',
      number: 12,
    ));
    expect(splitArchiveVolume('/dl/book.7z'), isNull);
    expect(splitArchiveVolume('/dl/book.001'), isNull);
    expect(splitArchiveVolume('/dl/book.7z.01'), isNull);
    expect(splitArchiveVolume('/dl/.7z.001'), isNull);
    // RAR 自有分卷格式（.part1.rar），不按字节拼。
    expect(splitArchiveVolume('/dl/book.rar.001'), isNull);
  });

  test('第一卷 / 后续卷', () {
    expect(isFirstSplitArchiveVolume('a/b.7z.001'), isTrue);
    expect(isLaterSplitArchiveVolume('a/b.7z.001'), isFalse);
    expect(isFirstSplitArchiveVolume('a/b.7z.002'), isFalse);
    expect(isLaterSplitArchiveVolume('a/b.7z.002'), isTrue);
    expect(isLaterSplitArchiveVolume('a/b.7z'), isFalse);
  });

  test('发现页导入：第一卷当压缩包解开，后续卷不当压缩包', () {
    expect(isDiscoveryArchivePath('/dl/合集.7z.001'), isTrue);
    expect(isDiscoveryArchivePath('/dl/合集.zip.001'), isTrue);
    expect(isDiscoveryArchivePath('/dl/合集.7z.002'), isFalse);
    expect(isDiscoveryArchivePath('/dl/合集.7z'), isTrue);
    expect(
      classifyDiscoveryFile(
        DiscoveryMediaKind.novel,
        '/dl/合集.7z.001',
        subtitleLangCode: 'ja',
      ),
      isA<ExtractArchivePlan>(),
    );
  });
}
