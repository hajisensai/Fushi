import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';
import 'package:fushi/src/media/video/video_mpv_config.dart';

/// 用户问「咱们支持 hdr 吗，不支持支持一下」。
///
/// 诚实的答案分两半：
/// - **HDR 直通做不到**（本 PR 不假装做到）。Windows 侧走 `vo=libmpv` render API →
///   ANGLE → Flutter 外部纹理，共享纹理格式在 vendored 的 media_kit_video 里写死
///   `DXGI_FORMAT_B8G8R8A8_UNORM`（8-bit SDR）；Android 侧还额外强制
///   `vf=format=yuv420p` 降位（Mali 16-bit 纹理 OOM，BUG-465）。
/// - **能做的是把那次不可避免的 HDR→SDR 映射做好**：此前全链路对
///   `tone-mapping` / `hdr-compute-peak` 一个字都没下发，HDR 片源只能吃 mpv 默认值。
void main() {
  group('属性下发', () {
    test('默认配置下发 auto/auto（此前这两条属性根本不存在）', () {
      final Map<String, String> props = buildMpvProperties(
        VideoMpvConfig.defaults,
        isAndroid: false,
        isMobile: false,
        isWindows: true,
      );

      expect(props['tone-mapping'], 'auto');
      expect(props['hdr-compute-peak'], 'auto');
    });

    test('用户选的曲线原样下发', () {
      final Map<String, String> props = buildMpvProperties(
        VideoMpvConfig.defaults.copyWith(
          hdrToneMapping: 'bt.2446a',
          hdrComputePeak: 'yes',
        ),
        isAndroid: false,
        isMobile: false,
        isWindows: true,
      );

      expect(props['tone-mapping'], 'bt.2446a');
      expect(props['hdr-compute-peak'], 'yes');
    });

    test('不按平台门控：三端都下发（只在真需要色调映射时才起作用）', () {
      for (final bool android in <bool>[true, false]) {
        final Map<String, String> props = buildMpvProperties(
          VideoMpvConfig.defaults.copyWith(hdrToneMapping: 'spline'),
          isAndroid: android,
          isMobile: android,
          isWindows: !android,
        );
        expect(props['tone-mapping'], 'spline',
            reason: 'SDR 片源不受这条属性影响，没必要按平台或按片源加门控。');
      }
    });

    test('rawConf 仍然压过结构化项（用户的逃生口不能被新项挡掉）', () {
      final Map<String, String> props = buildMpvProperties(
        VideoMpvConfig.defaults.copyWith(
          hdrToneMapping: 'hable',
          rawConf: 'tone-mapping=clip',
        ),
        isAndroid: false,
        isMobile: false,
        isWindows: true,
      );

      expect(props['tone-mapping'], 'clip');
    });
  });

  group('持久化', () {
    test('encode/decode 往返保住两项', () {
      final VideoMpvConfig config = VideoMpvConfig.defaults.copyWith(
        hdrToneMapping: 'mobius',
        hdrComputePeak: 'no',
      );
      final VideoMpvConfig back =
          VideoMpvConfig.decode(VideoMpvConfig.encode(config));

      expect(back.hdrToneMapping, 'mobius');
      expect(back.hdrComputePeak, 'no');
    });

    test('不认识的曲线名退回 auto', () {
      // 往 mpv 灌一个不认识的 tone-mapping 名不会崩，但会让**整条属性下发静默
      // 失败**，用户看到的是「这个开关没用」。值域白名单必须挡在落库读回这一层。
      final VideoMpvConfig back = VideoMpvConfig.decode(
        '{"_v":2,"hdrToneMapping":"totally-not-a-curve",'
        '"hdrComputePeak":"maybe"}',
      );

      expect(back.hdrToneMapping, 'auto');
      expect(back.hdrComputePeak, 'auto');
    });

    test('旧配置（没有这两个键）读回默认值，不炸', () {
      final VideoMpvConfig back =
          VideoMpvConfig.decode('{"_v":2,"deband":true}');

      expect(back.hdrToneMapping, 'auto');
      expect(back.hdrComputePeak, 'auto');
      expect(back.deband, isTrue);
    });

    test('设置页的曲线选项从白名单派生，不得再抄第二份清单', () {
      // 原来这条用例是把 kHdrToneMappingValues 的每个元素**再念一遍**——它从头到尾
      // 没读过 settings_schema_video.dart，注释里描述的失败模式（UI 多列一条、
      // 白名单没有 → 用户选完重启被打回 auto 且零提示）一条也抓不到，是恒真空转。
      //
      // 真正的根治是消灭第二份清单，所以这里钉的就是「派生」这件事本身。
      final String schema = maskComments(
        File('lib/src/settings/settings_schema_video.dart').readAsStringSync(),
      );
      expect(
        schema,
        contains("kHdrToneMappingValues.where((String c) => c != 'auto')"),
        reason: '曲线选项必须从白名单派生；写死第二份清单必然与 decode 分叉',
      );
      // 负向：schema 里不得再出现硬写的曲线字面量。
      for (final String curve in <String>['bt.2390', 'bt.2446a', 'spline']) {
        expect(
          schema,
          isNot(contains("'$curve'")),
          reason: '$curve 只应住在 kHdrToneMappingValues 里',
        );
      }
      expect(kHdrComputePeakValues, <String>{'auto', 'yes', 'no'});
    });
  });
}
