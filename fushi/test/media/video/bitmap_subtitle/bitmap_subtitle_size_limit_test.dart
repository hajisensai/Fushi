// 位图字幕的尺寸上限：码流声明的对象 / 区域宽高（PGS ODS、DVB RCS 都是 u16）超过
// kBitmapSubtitleMaxDimension 时当损坏数据丢掉，不按 65535×65535 去分配 4 GB 平面。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_cue.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/dvb_subtitle_decoder.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/mpegts_subtitle_demuxer.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/pgs_subtitle_parser.dart';

import 'bitmap_subtitle_fixtures.dart';

Uint8List _dvbShow({required int width, required int height}) =>
    buildDvbDisplaySet(
      pageId: 1,
      display: (width: 1920, height: 1080),
      regions: <DvbRegionSpec>[
        DvbRegionSpec(
          id: 0,
          x: 0,
          y: 0,
          width: width,
          height: height,
          objects: const <DvbObjectSpec>[
            DvbObjectSpec(
              id: 7,
              x: 0,
              y: 0,
              pixels: <List<int>>[
                <int>[1, 1],
                <int>[1, 1],
              ],
            ),
          ],
        ),
      ],
      cluts: const <int, List<DvbClutEntry>>{
        0: <DvbClutEntry>[(1, 235, 128, 128, 0)],
      },
    );

void main() {
  test('尺寸判据：正数且两边不超过上限', () {
    expect(isDecodableBitmapSubtitleSize(1920, 1080), isTrue);
    expect(
      isDecodableBitmapSubtitleSize(
        kBitmapSubtitleMaxDimension,
        kBitmapSubtitleMaxDimension,
      ),
      isTrue,
    );
    expect(isDecodableBitmapSubtitleSize(0, 10), isFalse);
    expect(
      isDecodableBitmapSubtitleSize(kBitmapSubtitleMaxDimension + 1, 10),
      isFalse,
    );
    expect(isDecodableBitmapSubtitleSize(65535, 65535), isFalse);
  });

  test('PGS：声明 65535×65535 的对象不解码（返回 null，不分配平面）', () {
    expect(decodePgsRle(Uint8List(0), 65535, 65535), isNull);
    expect(decodePgsRle(Uint8List(0), 4, 2), hasLength(8));
  });

  test('DVB：声明超大尺寸的区域被丢掉，不进 cue；正常区域照常出 cue', () {
    BitmapSubtitlePacket packet(int ms, Uint8List data) =>
        BitmapSubtitlePacket(pts90k: ms * 90, data: data);
    final List<DvbSubtitleCue> huge = decodeDvbSubtitlePackets(
      <BitmapSubtitlePacket>[packet(0, _dvbShow(width: 65535, height: 65535))],
    );
    expect(huge, isEmpty);
    final List<DvbSubtitleCue> ok = decodeDvbSubtitlePackets(
      <BitmapSubtitlePacket>[packet(0, _dvbShow(width: 100, height: 20))],
    );
    expect(ok, hasLength(1));
  });
}
