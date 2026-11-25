// 出处「系列 → 集」（反馈 MCJLSBR5Wg）的标题：组头是系列名，系列下的一集去掉「系列名 - 」前缀。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_card_tile.dart';
import 'package:fushi_srs/fushi_srs.dart';

SrsSourceRef _video(String title, {String? series}) => SrsSourceRef.media(
  kind: SrsSourceKind.video,
  mediaKey: 'e1',
  startMs: 0,
  title: title,
  seriesTitle: series,
);

void main() {
  test('组头：带系列的出处显示系列名，不带的显示出处标题', () {
    expect(
      srsBrowseSourceGroupTitle(
        _video('RWBY - S01E01', series: 'RWBY'),
        SrsSourceKind.video,
      ),
      'RWBY',
    );
    expect(
      srsBrowseSourceGroupTitle(_video('Solo'), SrsSourceKind.video),
      'Solo',
    );
  });

  test('系列下的一集：去掉「系列名 - 」前缀；没有前缀或去完为空时保留原标题', () {
    expect(
      srsBrowseSourceItemTitle(
        _video('RWBY - S01E01', series: 'RWBY'),
        SrsSourceKind.video,
      ),
      'S01E01',
    );
    expect(
      srsBrowseSourceItemTitle(
        _video('Episode 3', series: 'RWBY'),
        SrsSourceKind.video,
      ),
      'Episode 3',
    );
    expect(
      srsBrowseSourceItemTitle(
        _video('RWBY - ', series: 'RWBY'),
        SrsSourceKind.video,
      ),
      'RWBY -',
      reason: '出处标题本身去了两侧空白；去掉前缀后为空就用原标题',
    );
    expect(
      srsBrowseSourceItemTitle(_video('Solo'), SrsSourceKind.video),
      'Solo',
    );
  });
}
