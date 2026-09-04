import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_dynamic_range.dart';
import 'package:fushi/src/media/video/video_hdr_output.dart';

/// 动态范围归一的值域与判据。
///
/// 取值不是查文档抄的，是拿捆绑的 ffprobe n7.1.5 探三个真实样本得到的（分别用
/// x265 `colorprim=bt2020:transfer=smpte2084` / `transfer=arib-std-b67` 与 x264
/// `colorprim=bt709` 编出来）。其中「未标注时两个键整个不出现」这条尤其重要，
/// 是第一批样本（没往 VUI 写色彩标签）实测出来的。
void main() {
  group('ffprobe 归一', () {
    test('HDR10：bt2020 + smpte2084', () {
      expect(
        dynamicRangeFromFfprobe(
          colorPrimaries: 'bt2020',
          colorTransfer: 'smpte2084',
        ),
        VideoDynamicRange.hdr10,
      );
    });

    test('HLG：bt2020 + arib-std-b67', () {
      expect(
        dynamicRangeFromFfprobe(
          colorPrimaries: 'bt2020',
          colorTransfer: 'arib-std-b67',
        ),
        VideoDynamicRange.hlg,
      );
    });

    test('SDR：bt709 + bt709', () {
      expect(
        dynamicRangeFromFfprobe(
          colorPrimaries: 'bt709',
          colorTransfer: 'bt709',
        ),
        VideoDynamicRange.sdr,
      );
    });

    test('两个键都缺 → unknown，而不是 sdr', () {
      // 回归护栏：把「没写色彩标签」当成 SDR，会给真 HDR 片源打上 SDR 标。
      final VideoDynamicRange r = dynamicRangeFromFfprobe();
      expect(r, VideoDynamicRange.unknown);
      expect(r, isNot(VideoDynamicRange.sdr));
      expect(r.isHdr, isFalse);
      expect(r.badgeLabel, isNull, reason: '不知道就不该占角标位');
    });

    test('只有 primaries 没有 transfer → unknown（BT.2020 也有 SDR 素材）', () {
      expect(
        dynamicRangeFromFfprobe(colorPrimaries: 'bt2020'),
        VideoDynamicRange.unknown,
      );
    });

    test('空串 / unknown / unspecified 等同于没写', () {
      for (final String blank in <String>['', '  ', 'unknown', 'unspecified']) {
        expect(
          dynamicRangeFromFfprobe(colorPrimaries: blank, colorTransfer: blank),
          VideoDynamicRange.unknown,
          reason: 'primaries=transfer="$blank"',
        );
      }
    });

    test('大小写与空白不影响判定', () {
      expect(
        dynamicRangeFromFfprobe(
          colorPrimaries: ' BT2020 ',
          colorTransfer: 'SMPTE2084',
        ),
        VideoDynamicRange.hdr10,
      );
    });
  });

  group('mpv 归一', () {
    test('bt.2020 + pq → HDR10（注意 mpv 的色域带点）', () {
      expect(
        dynamicRangeFromMpv(primaries: 'bt.2020', gamma: 'pq'),
        VideoDynamicRange.hdr10,
      );
    });

    test('bt.2020 + hlg → HLG', () {
      expect(
        dynamicRangeFromMpv(primaries: 'bt.2020', gamma: 'hlg'),
        VideoDynamicRange.hlg,
      );
    });

    test('bt.709 + bt.1886 → SDR', () {
      expect(
        dynamicRangeFromMpv(primaries: 'bt.709', gamma: 'bt.1886'),
        VideoDynamicRange.sdr,
      );
    });

    test('属性未就绪（null / 空串）→ unknown', () {
      expect(dynamicRangeFromMpv(), VideoDynamicRange.unknown);
      expect(
        dynamicRangeFromMpv(primaries: '', gamma: ''),
        VideoDynamicRange.unknown,
      );
    });
  });

  group('跨来源一致性', () {
    // 收口的意义：同一个片源，无论从 ffprobe 还是从 mpv 得到色彩标签，结论必须相同。
    // 否则库页卡片与播放器会对同一文件给出互相矛盾的 HDR 判断。
    const List<(String, String, String, String, VideoDynamicRange)> cases =
        <(String, String, String, String, VideoDynamicRange)>[
      ('bt2020', 'smpte2084', 'bt.2020', 'pq', VideoDynamicRange.hdr10),
      ('bt2020', 'arib-std-b67', 'bt.2020', 'hlg', VideoDynamicRange.hlg),
      ('bt709', 'bt709', 'bt.709', 'bt.1886', VideoDynamicRange.sdr),
    ];

    for (final (
          String ffPrimaries,
          String ffTransfer,
          String mpvPrimaries,
          String mpvGamma,
          VideoDynamicRange expected,
        ) in cases) {
      test('$ffTransfer / $mpvGamma 两侧同判 ${expected.name}', () {
        final VideoDynamicRange fromFfprobe = dynamicRangeFromFfprobe(
          colorPrimaries: ffPrimaries,
          colorTransfer: ffTransfer,
        );
        final VideoDynamicRange fromMpv = dynamicRangeFromMpv(
          primaries: mpvPrimaries,
          gamma: mpvGamma,
        );
        expect(fromFfprobe, expected);
        expect(fromMpv, expected);
        expect(fromFfprobe, fromMpv, reason: '两个来源必须给出同一结论');
      });
    }
  });

  group('isHdrVideoParams 薄壳与归一等价', () {
    // 直通链路的既有行为不能变（Never break userspace）。
    //
    // **期望值必须是字面量**：`isHdrVideoParams` 的实现就是
    // `dynamicRangeFromMpv(...).isHdr`，拿它俩互相比对是同源恒真——把
    // `dynamicRangeFromMpv` 改成恒返回 sdr，这一组照样全绿。钉死第三方期望值之后，
    // 这组同时承住了薄壳等价性**和**归一判据本身。
    const List<(String?, String?, bool)> inputs = <(String?, String?, bool)>[
      ('bt.2020', 'pq', true),
      ('bt.2020', 'hlg', true),
      ('bt.2020', 'bt.1886', false),
      ('bt.2020', null, false),
      ('bt.709', 'pq', false),
      ('bt.709', 'bt.1886', false),
      (null, 'pq', false),
      (null, null, false),
      ('', '', false),
    ];

    for (final (String? primaries, String? gamma, bool expected) in inputs) {
      test('primaries=$primaries gamma=$gamma -> hdr=$expected', () {
        expect(
          dynamicRangeFromMpv(primaries: primaries, gamma: gamma).isHdr,
          expected,
          reason: '归一判据变了',
        );
        expect(
          isHdrVideoParams(primaries: primaries, gamma: gamma),
          expected,
          reason: '薄壳与归一判据脱钩了',
        );
      });
    }

    test('只有 bt.2020 + PQ/HLG 为真（钉住原判据）', () {
      expect(isHdrVideoParams(primaries: 'bt.2020', gamma: 'pq'), isTrue);
      expect(isHdrVideoParams(primaries: 'bt.2020', gamma: 'hlg'), isTrue);
      expect(isHdrVideoParams(primaries: 'bt.2020', gamma: 'bt.1886'), isFalse);
      expect(isHdrVideoParams(primaries: 'bt.709', gamma: 'pq'), isFalse);
      expect(isHdrVideoParams(primaries: null, gamma: null), isFalse);
    });
  });

  group('storageValue 往返', () {
    test('每个值都能原样往返', () {
      for (final VideoDynamicRange r in VideoDynamicRange.values) {
        expect(VideoDynamicRange.fromStorage(r.storageValue), r);
      }
    });

    test('未知字符串落回 unknown', () {
      expect(VideoDynamicRange.fromStorage('dolby_vision'),
          VideoDynamicRange.unknown);
      expect(VideoDynamicRange.fromStorage(null), VideoDynamicRange.unknown);
    });
  });
}
