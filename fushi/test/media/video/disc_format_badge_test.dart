// 原盘规格角标（交接文档第 3 项）与规格筛选判据（第 9 项）的组件 / 纯函数层。

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/cover_ui/disc_format_badge.dart';
import 'package:fushi/src/media/video/video_home_layout.dart';
import 'package:fushi/src/pages/implementations/library_filter_panel.dart';
import 'package:fushi_engine/media/video/disc/disc_format.dart';
import 'package:fushi_engine/media/video/dvd/dvd_disc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

String _mpls(String disc, [String id = '00001']) =>
    p.join('/lib', disc, 'BDMV', 'PLAYLIST', '$id.mpls');

/// 不碰磁盘的解析器：盘根名含 `UHD` 的判 UHD，其余判 BD。
DiscFormatResolver _fakeResolver() => DiscFormatResolver(
  readFormat: (String root) async => p.basename(root).contains('UHD')
      ? DiscFormat.uhdBluray
      : DiscFormat.bluray,
);

Future<void> _pumpBadge(
  WidgetTester tester,
  DiscFormatResolver? resolver,
  List<String> paths,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: DiscFormatBadge(resolver: resolver, memberPaths: paths),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('角标文字', () {
    test('单盘 / 多盘 / 混合', () {
      expect(
        discFormatBadgeLabel(<DiscFormat, int>{DiscFormat.bluray: 1}),
        'BD',
      );
      expect(
        discFormatBadgeLabel(<DiscFormat, int>{DiscFormat.bluray: 3}),
        'BD ×3',
      );
      expect(
        discFormatBadgeLabel(<DiscFormat, int>{
          DiscFormat.bluray: 2,
          DiscFormat.uhdBluray: 1,
        }),
        'UHD + BD ×2',
      );
      expect(discFormatBadgeLabel(const <DiscFormat, int>{}), isNull);
    });
  });

  group('DiscFormatBadge', () {
    testWidgets('单张 BD 盘的多条标题：BD（按盘根计，不是按标题数）', (WidgetTester tester) async {
      await _pumpBadge(tester, _fakeResolver(), <String>[
        _mpls('Movie', '00001'),
        _mpls('Movie', '00002'),
      ]);
      expect(find.text('BD'), findsOneWidget);
    });

    testWidgets('三张盘的合集：BD ×3', (WidgetTester tester) async {
      await _pumpBadge(tester, _fakeResolver(), <String>[
        _mpls('Vol1'),
        _mpls('Vol2'),
        _mpls('Vol3'),
      ]);
      expect(find.text('BD ×3'), findsOneWidget);
    });

    testWidgets('UHD 盘解析完显示 UHD，从不先闪 BD', (WidgetTester tester) async {
      final DiscFormatResolver resolver = _fakeResolver();
      await tester.pumpWidget(
        MaterialApp(
          home: DiscFormatBadge(
            resolver: resolver,
            memberPaths: <String>[_mpls('Movie UHD')],
          ),
        ),
      );
      // 首帧：还没读 index.bdmv，什么都不画（不是 BD）。
      expect(find.text('BD'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('UHD'), findsOneWidget);
      expect(find.text('BD'), findsNothing);
    });

    testWidgets('DVD 不需要 IO，直接 DVD', (WidgetTester tester) async {
      await _pumpBadge(tester, _fakeResolver(), <String>[
        dvdTitlePath(p.join('/lib', 'Show'), 2),
        dvdTitlePath(p.join('/lib', 'Show'), 3),
      ]);
      expect(find.text('DVD'), findsOneWidget);
    });

    testWidgets('普通文件 / 没有解析器：不占位', (WidgetTester tester) async {
      await _pumpBadge(tester, _fakeResolver(), <String>['/lib/a.mkv']);
      expect(find.byType(Text), findsNothing);
      await _pumpBadge(tester, null, <String>[_mpls('Movie')]);
      expect(find.byType(Text), findsNothing);
    });
  });

  group('规格筛选判据', () {
    bool hit(
      Set<VideoSpecFilter> selected, {
      DiscFormat? format,
      bool disc = false,
      bool is4k = false,
      bool hdr = false,
    }) => matchesVideoSpecFilter(
      selected: selected,
      discFormat: format,
      isDiscMember: disc || format != null,
      is4k: is4k,
      isHdr: hdr,
    );

    test('不勾 = 不设限', () {
      expect(hit(const <VideoSpecFilter>{}), isTrue);
    });

    test('载体组内「或」：BD / UHD / DVD / 普通文件各自精确', () {
      const Set<VideoSpecFilter> bdOrDvd = <VideoSpecFilter>{
        VideoSpecFilter.bluray,
        VideoSpecFilter.dvd,
      };
      expect(hit(bdOrDvd, format: DiscFormat.bluray), isTrue);
      expect(hit(bdOrDvd, format: DiscFormat.dvd), isTrue);
      expect(hit(bdOrDvd, format: DiscFormat.uhdBluray), isFalse);
      expect(hit(bdOrDvd), isFalse);
      expect(hit(const <VideoSpecFilter>{VideoSpecFilter.plainFile}), isTrue);
      expect(
        hit(const <VideoSpecFilter>{
          VideoSpecFilter.plainFile,
        }, format: DiscFormat.bluray),
        isFalse,
      );
    });

    test('还没分出 UHD 的蓝光：既不算 BD / UHD，也不算普通文件', () {
      for (final VideoSpecFilter f in kVideoSpecCarrierFilters) {
        expect(hit(<VideoSpecFilter>{f}, disc: true), isFalse, reason: '$f');
      }
    });

    test('画质组内「或」，与载体组之间「与」', () {
      const Set<VideoSpecFilter> q = <VideoSpecFilter>{
        VideoSpecFilter.uhd4k,
        VideoSpecFilter.hdr,
      };
      expect(hit(q, is4k: true), isTrue);
      expect(hit(q, hdr: true), isTrue);
      expect(hit(q), isFalse);
      const Set<VideoSpecFilter> uhdHdr = <VideoSpecFilter>{
        VideoSpecFilter.uhdBluray,
        VideoSpecFilter.hdr,
      };
      expect(hit(uhdHdr, format: DiscFormat.uhdBluray, hdr: true), isTrue);
      expect(hit(uhdHdr, format: DiscFormat.uhdBluray), isFalse);
      expect(hit(uhdHdr, hdr: true), isFalse);
    });
  });

  testWidgets('多选分组：点一下勾上、再点取消，回调拿到新集合', (WidgetTester tester) async {
    Set<VideoSpecFilter> selected = const <VideoSpecFilter>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) =>
                LibraryFilterMultiChoiceSection<VideoSpecFilter>(
                  title: 'Format',
                  values: VideoSpecFilter.values,
                  selected: selected,
                  labelOf: (VideoSpecFilter f) => f.name,
                  onChanged: (Set<VideoSpecFilter> next) =>
                      setState(() => selected = next),
                ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('dvd'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('hdr'));
    await tester.pumpAndSettle();
    expect(selected, <VideoSpecFilter>{
      VideoSpecFilter.dvd,
      VideoSpecFilter.hdr,
    });
    await tester.tap(find.text('dvd'));
    await tester.pumpAndSettle();
    expect(selected, <VideoSpecFilter>{VideoSpecFilter.hdr});
  });
}
