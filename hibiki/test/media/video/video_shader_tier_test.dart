import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/video_shader_downloader.dart';
import 'package:hibiki/src/media/video/video_shader_tier.dart';

/// TODO-041 方案甲'（飞书 O54）五档画质映射守卫：钉死「无/低/中/高/极高」各自落到
/// 哪套底层状态（mpv 内置缩放开关 + GLSL 启用集），并验证档位↔状态双向投影一致。
void main() {
  group('kVideoShaderTiers 五档映射', () {
    test('恰好五档，顺序 无→低→中→高→极高，id 稳定唯一', () {
      expect(
          kVideoShaderTiers.map((VideoShaderTierSpec s) => s.tier).toList(),
          <VideoShaderTier>[
            VideoShaderTier.off,
            VideoShaderTier.low,
            VideoShaderTier.medium,
            VideoShaderTier.high,
            VideoShaderTier.ultra,
          ]);
      expect(kVideoShaderTiers.map((VideoShaderTierSpec s) => s.id).toList(),
          <String>['off', 'low', 'medium', 'high', 'ultra']);
    });

    test('无 = 关闭着色器：内置缩放 off + 空 GLSL', () {
      final VideoShaderTierSpec off = shaderTierSpec(VideoShaderTier.off);
      expect(off.highQuality, isFalse);
      expect(off.shaderFileNames, isEmpty);
    });

    test('低 = mpv 内置 ewa_lanczossharp（零下载）：内置缩放 on + 空 GLSL', () {
      final VideoShaderTierSpec low = shaderTierSpec(VideoShaderTier.low);
      expect(low.highQuality, isTrue);
      expect(low.shaderFileNames, isEmpty,
          reason: '低档只靠 mpv 内置 scale 链（buildMpvProperties highQuality 分支 '
              '= ewa_lanczossharp），不下载任何 GLSL');
    });

    test('中 = Anime4K Fast（Mode A Fast）：内置缩放 on + Anime4K Fast 链', () {
      final VideoShaderTierSpec mid = shaderTierSpec(VideoShaderTier.medium);
      expect(mid.highQuality, isTrue);
      expect(mid.preset, same(kAnime4kFastPreset));
      expect(mid.preset!.id, 'mode_a_fast');
      expect(mid.shaderFileNames, contains('Anime4K_Restore_CNN_M.glsl'));
      expect(mid.shaderFileNames, contains('Anime4K_Upscale_CNN_x2_M.glsl'));
    });

    test('高 = Anime4K HQ（Mode A HQ）：内置缩放 on + Anime4K HQ 链', () {
      final VideoShaderTierSpec high = shaderTierSpec(VideoShaderTier.high);
      expect(high.highQuality, isTrue);
      expect(high.preset, same(kAnime4kHqPreset));
      expect(high.preset!.id, 'mode_a_hq');
      expect(high.shaderFileNames, contains('Anime4K_Restore_CNN_VL.glsl'));
      expect(high.shaderFileNames, contains('Anime4K_Upscale_CNN_x2_VL.glsl'));
    });

    test('极高 = Anime4K Mode A VL + 额外去模糊修复：内置缩放 on + VL 类链（非 UL）', () {
      final VideoShaderTierSpec ultra = shaderTierSpec(VideoShaderTier.ultra);
      expect(ultra.highQuality, isTrue);
      expect(ultra.preset, same(kAnime4kUltraDeblurPreset));
      expect(ultra.preset!.id, 'mode_a_deblur_vl');
      // 极高在高档 VL 链之上叠一个 Soft_VL 去模糊 pass（双重修复，强于高档）。
      expect(ultra.shaderFileNames, contains('Anime4K_Restore_CNN_VL.glsl'));
      expect(
          ultra.shaderFileNames, contains('Anime4K_Restore_CNN_Soft_VL.glsl'));
      expect(ultra.shaderFileNames, contains('Anime4K_Upscale_CNN_x2_VL.glsl'));
    });

    // BUG-836 回归守卫：极高**绝不能**用 Anime4K UL 变体——UL 的 Restore/Upscale 大 pass
    // 绑定纹理数越过 media_kit ra_gl（Windows ANGLE / GLES）的 GL_MAX_VERTEX_ATTRIBS=16 →
    // 链接失败「Too many attributes」→ 整屏黑（Windows 实机坐实）。任何档位都不许下发 UL。
    test('BUG-836: 任何档位都不下发 Anime4K UL 变体（越 ANGLE 顶点属性上限 → 黑屏）', () {
      const List<String> banned = <String>[
        'Anime4K_Restore_CNN_UL.glsl',
        'Anime4K_Upscale_CNN_x2_UL.glsl',
      ];
      for (final VideoShaderTierSpec spec in kVideoShaderTiers) {
        for (final String bad in banned) {
          expect(spec.shaderFileNames, isNot(contains(bad)),
              reason:
                  '档位 ${spec.id} 含 $bad —— UL 在 ANGLE/GLES 后端链接失败会黑屏（BUG-836）');
        }
      }
    });
  });

  group('kAnime4kUltraDeblurPreset（极高档 VL + 去模糊链）', () {
    test('来自 bloc97/Anime4K（MIT），默认 master 分支，Mode A VL + Soft_VL 结构', () {
      expect(kAnime4kUltraDeblurPreset.repo, 'bloc97/Anime4K');
      expect(kAnime4kUltraDeblurPreset.ref, 'master');
      // Clamp → Restore_VL → Restore_Soft_VL → Upscale_VL → AutoDownscale x2/x4 → Upscale_M。
      expect(
          kAnime4kUltraDeblurPreset.shaders
              .map((Anime4kShaderFile s) => s.repoPath)
              .toList(),
          <String>[
            'glsl/Restore/Anime4K_Clamp_Highlights.glsl',
            'glsl/Restore/Anime4K_Restore_CNN_VL.glsl',
            'glsl/Restore/Anime4K_Restore_CNN_Soft_VL.glsl',
            'glsl/Upscale/Anime4K_Upscale_CNN_x2_VL.glsl',
            'glsl/Upscale/Anime4K_AutoDownscalePre_x2.glsl',
            'glsl/Upscale/Anime4K_AutoDownscalePre_x4.glsl',
            'glsl/Upscale/Anime4K_Upscale_CNN_x2_M.glsl',
          ]);
    });

    test('极高文件集与高档互异（多一个 Soft_VL）→ tierFromState 反查无歧义', () {
      final Set<String> ultra =
          shaderFilesForTier(VideoShaderTier.ultra).toSet();
      final Set<String> high = shaderFilesForTier(VideoShaderTier.high).toSet();
      expect(ultra, isNot(equals(high)));
      expect(
          ultra.difference(high), <String>{'Anime4K_Restore_CNN_Soft_VL.glsl'},
          reason: '极高应恰好比高档多一个 Soft_VL 去模糊 pass');
      // 反查：极高的底层状态命中极高档，不误判为高档或自定义。
      expect(tierFromState(highQuality: true, enabledShaders: ultra.toList()),
          VideoShaderTier.ultra);
    });

    test('镜像 URL 用 Anime4K repo + master 分支（与中/高档同源，无需覆写）', () {
      final List<String> urls = anime4kMirrorUrls(
        'glsl/Restore/Anime4K_Restore_CNN_Soft_VL.glsl',
        repo: kAnime4kUltraDeblurPreset.repo,
        ref: kAnime4kUltraDeblurPreset.ref,
      );
      expect(urls.first,
          'https://cdn.jsdelivr.net/gh/bloc97/Anime4K@master/glsl/Restore/Anime4K_Restore_CNN_Soft_VL.glsl');
      expect(urls.last,
          'https://raw.githubusercontent.com/bloc97/Anime4K/master/glsl/Restore/Anime4K_Restore_CNN_Soft_VL.glsl');
    });
  });

  group('anime4kMirrorUrls 向后兼容', () {
    test('不传 repo/ref 时仍默认 bloc97/Anime4K@master（不破坏既有调用）', () {
      final List<String> urls =
          anime4kMirrorUrls('glsl/Restore/Anime4K_Clamp_Highlights.glsl');
      expect(urls.first,
          startsWith('https://cdn.jsdelivr.net/gh/bloc97/Anime4K@master/'));
    });
  });

  group('tierFromState（状态→档位反查投影）', () {
    test('内置 off + 空集 → 无', () {
      expect(
          tierFromState(highQuality: false, enabledShaders: const <String>[]),
          VideoShaderTier.off);
    });

    test('内置 on + 空集 → 低（仅靠 highQuality 区分 off/low）', () {
      expect(tierFromState(highQuality: true, enabledShaders: const <String>[]),
          VideoShaderTier.low);
    });

    test('内置 on + Anime4K Fast 全集（顺序无关）→ 中', () {
      final List<String> shuffled =
          shaderFilesForTier(VideoShaderTier.medium).reversed.toList();
      expect(tierFromState(highQuality: true, enabledShaders: shuffled),
          VideoShaderTier.medium);
    });

    test('内置 on + Anime4K HQ 全集 → 高', () {
      expect(
          tierFromState(
              highQuality: true,
              enabledShaders: shaderFilesForTier(VideoShaderTier.high)),
          VideoShaderTier.high);
    });

    test('内置 on + 极高（VL + Soft_VL）全集 → 极高', () {
      expect(
          tierFromState(
              highQuality: true,
              enabledShaders: shaderFilesForTier(VideoShaderTier.ultra)),
          VideoShaderTier.ultra);
    });

    test('反查唯一：高/极高文件集互不相等，(highQuality, shaderSet) 两两不重复', () {
      // 极高=高档 VL 链 + Soft_VL、高=Anime4K A HQ 文件集不同（极高多一个 Soft_VL）→ 反查无歧义。
      final Set<String> highSet =
          shaderFilesForTier(VideoShaderTier.high).toSet();
      final Set<String> ultraSet =
          shaderFilesForTier(VideoShaderTier.ultra).toSet();
      expect(highSet, isNot(equals(ultraSet)));
      // (highQuality, shaderSet) 在五档间唯一：否则 tierFromState 会出现歧义命中。
      final Set<String> seen = <String>{};
      for (final VideoShaderTierSpec spec in kVideoShaderTiers) {
        final List<String> sorted = spec.shaderFileNames.toList()..sort();
        final String key = '${spec.highQuality}|${sorted.join(",")}';
        expect(seen.add(key), isTrue,
            reason: '档 ${spec.id} 的 (highQuality, shaderSet) 与另一档重复 → 反查歧义');
      }
    });

    test('内置 on + 非标准勾选（多一个文件）→ null（自定义）', () {
      final List<String> custom = shaderFilesForTier(VideoShaderTier.medium)
          .toList()
        ..add('SomeUserShader.glsl');
      expect(tierFromState(highQuality: true, enabledShaders: custom), isNull);
    });

    test('内置 off + 有 GLSL 勾选 → null（无任一档定义内置 off 还带 GLSL）', () {
      expect(
          tierFromState(
              highQuality: false,
              enabledShaders: <String>['Anime4K_Restore_CNN_VL.glsl']),
          isNull);
    });
  });

  group('orderedEnabledForTier（按目录现有文件过滤+保序）', () {
    test('全部存在 → 返回该档全集并保持叠加顺序', () {
      final List<String> want = shaderFilesForTier(VideoShaderTier.medium);
      final List<String> got =
          orderedEnabledForTier(VideoShaderTier.medium, want.toSet());
      expect(got, want);
    });

    test('部分缺失 → 只启用存在的（不引用缺失路径），仍保序', () {
      final List<String> want = shaderFilesForTier(VideoShaderTier.medium);
      final Set<String> present = <String>{want.first, want.last};
      final List<String> got =
          orderedEnabledForTier(VideoShaderTier.medium, present);
      expect(got, <String>[want.first, want.last]);
    });

    test('无 GLSL 档（低）→ 空集', () {
      expect(
          orderedEnabledForTier(
              VideoShaderTier.low, <String>{'Anime4K_Restore_CNN_M.glsl'}),
          isEmpty);
    });
  });
}
