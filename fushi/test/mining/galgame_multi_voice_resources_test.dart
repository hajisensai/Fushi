import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';

/// BUG-1605：同一句台词同时有多个角色配音（男女声优同台）时，引擎为同一条文本读入多个
/// 语音资源、hook 各 dump 一个文件，制卡必须把它们**全部**带进卡里，而不是只留一个。
///
/// 但「全取」不是无条件的：只有被证明属于同一句的资源才允许全取，纯时间邻近仍旧单取。
/// 这条界线是本文件的主要断言面——放宽它会把上一句尾音、旁白、系统音一起塞进卡。
void main() {
  group('pickPairedVoiceOggs（事件 ID 层全取）', () {
    test('同一事件 ID 的多个资源全部返回，按与文本时间戳的距离排序', () {
      final List<String> picked = pickPairedVoiceOggs(
        oggFileNames: const <String>[
          '32147150_fushi_textseq16_otoko_020.ogg',
          '32147187_fushi_textseq16_onna_015.ogg',
        ],
        textTsMs: 32147200,
        textEventId: 16,
      );
      // 距离：onna 13ms < otoko 50ms → 主语音是 onna，otoko 是同句伴音。
      expect(picked, <String>[
        '32147187_fushi_textseq16_onna_015.ogg',
        '32147150_fushi_textseq16_otoko_020.ogg',
      ]);
    });

    test('别的事件 ID 不会被顺带收进来', () {
      final List<String> picked = pickPairedVoiceOggs(
        oggFileNames: const <String>[
          '32147187_fushi_textseq16_onna_015.ogg',
          '32147188_fushi_textseq17_next_line.ogg',
        ],
        textTsMs: 32147200,
        textEventId: 16,
      );
      expect(picked, <String>['32147187_fushi_textseq16_onna_015.ogg']);
    });

    test('事件层命中后不再看精确 tick / 偏移窗层', () {
      final List<String> picked = pickPairedVoiceOggs(
        oggFileNames: const <String>[
          '32147200_same_tick_but_unmarked.ogg',
          '32147187_fushi_textseq16_onna_015.ogg',
        ],
        textTsMs: 32147200,
        textEventId: 16,
      );
      expect(picked, <String>['32147187_fushi_textseq16_onna_015.ogg']);
    });

    test('同距离时按文件名排序，结果不随目录枚举顺序漂', () {
      const List<String> names = <String>[
        '32147200_fushi_textseq16_b_voice.ogg',
        '32147200_fushi_textseq16_a_voice.ogg',
      ];
      final List<String> forward = pickPairedVoiceOggs(
        oggFileNames: names,
        textTsMs: 32147200,
        textEventId: 16,
      );
      final List<String> reversed = pickPairedVoiceOggs(
        oggFileNames: names.reversed.toList(),
        textTsMs: 32147200,
        textEventId: 16,
      );
      expect(forward, <String>[
        '32147200_fushi_textseq16_a_voice.ogg',
        '32147200_fushi_textseq16_b_voice.ogg',
      ]);
      expect(reversed, forward);
    });

    test('BGM/SE 即使带同一事件 ID 也不算配音', () {
      final List<String> picked = pickPairedVoiceOggs(
        oggFileNames: const <String>[
          '32147187_fushi_textseq16_onna_015.ogg',
          '32147188_fushi_textseq16_bgm_theme.ogg',
          '32147189_fushi_textseq16_se_door.ogg',
        ],
        textTsMs: 32147200,
        textEventId: 16,
      );
      expect(picked, <String>['32147187_fushi_textseq16_onna_015.ogg']);
    });
  });

  group('pickPairedVoiceOggs（精确 tick 层全取）', () {
    test('同一毫秒读入的多个资源全部返回', () {
      final List<String> picked = pickPairedVoiceOggs(
        oggFileNames: const <String>[
          '32147200_onna_015.ogg',
          '32147200_otoko_020.ogg',
        ],
        textTsMs: 32147200,
      );
      expect(picked, <String>[
        '32147200_onna_015.ogg',
        '32147200_otoko_020.ogg',
      ]);
    });
  });

  group('pickPairedVoiceOggs（偏移窗层仍然单取）', () {
    test('纯时间猜测层只返回最接近期望偏移的那一个', () {
      // 期望偏移 T-220；窗口 [T-330, T-130]。两个都在窗内，但没有任何归属证据，
      // 把它们都塞进卡等于把别句的语音一起带走。
      final List<String> picked = pickPairedVoiceOggs(
        oggFileNames: const <String>[
          '32146980_onna_015.ogg', // T-220，正中期望
          '32147050_otoko_020.ogg', // T-150
        ],
        textTsMs: 32147200,
      );
      expect(picked, <String>['32146980_onna_015.ogg']);
    });
  });

  group('pickPairedUnityVoiceWavs', () {
    test('带同一事件 ID 的 WAV 全取', () {
      final List<String> picked = pickPairedUnityVoiceWavs(
        wavFileNames: const <String>[
          '32147100_fushi_textseq7_onna.wav',
          '32147300_fushi_textseq7_otoko.wav',
        ],
        textTsMs: 32147200,
        textEventId: 7,
      );
      expect(picked, <String>[
        '32147100_fushi_textseq7_onna.wav',
        '32147300_fushi_textseq7_otoko.wav',
      ]);
    });

    test('无事件 ID 时仍旧只取时间窗内最近的一个', () {
      final List<String> picked = pickPairedUnityVoiceWavs(
        wavFileNames: const <String>[
          '32147100_onna.wav',
          '32147190_otoko.wav',
        ],
        textTsMs: 32147200,
      );
      expect(picked, <String>['32147190_otoko.wav']);
    });

    test('带标 WAV 在事件 ID 对不上时照旧参与时间窗兜底（Unity 层既有行为不变）', () {
      // 与 OGG 层不同：Unity 层一直是纯时间窗判定，把带标资源排除出兜底会让现有配对
      // 凭空失败。这条是防回归的负向断言。
      final List<String> picked = pickPairedUnityVoiceWavs(
        wavFileNames: const <String>['32147190_fushi_textseq99_otoko.wav'],
        textTsMs: 32147200,
        textEventId: 7,
      );
      expect(picked, <String>['32147190_fushi_textseq99_otoko.wav']);
    });
  });

  group('pickPairedGameResources / 单值版兼容', () {
    test('WAV 层命中时不再看 OGG 层', () {
      final List<String> picked = pickPairedGameResources(
        oggFileNames: const <String>['32147200_onna_015.ogg'],
        wavFileNames: const <String>['32147190_otoko.wav'],
        textTsMs: 32147200,
      );
      expect(picked, <String>['32147190_otoko.wav']);
    });

    test('没有文本时间戳时只认会话内最新资源兜底', () {
      expect(
        pickPairedGameResources(
          oggFileNames: const <String>['32147200_onna_015.ogg'],
          wavFileNames: const <String>[],
          textTsMs: 0,
          latestSessionVoiceName: '32147200_onna_015.ogg',
        ),
        <String>['32147200_onna_015.ogg'],
      );
      expect(
        pickPairedGameResources(
          oggFileNames: const <String>['32147200_onna_015.ogg'],
          wavFileNames: const <String>[],
          textTsMs: 0,
        ),
        isEmpty,
      );
    });

    test('单值版恒等于全量版的首元素（不许出现第二套判据）', () {
      const List<String> oggs = <String>[
        '32147150_fushi_textseq16_otoko_020.ogg',
        '32147187_fushi_textseq16_onna_015.ogg',
      ];
      final List<String> all = pickPairedGameResources(
        oggFileNames: oggs,
        wavFileNames: const <String>[],
        textTsMs: 32147200,
        textEventId: 16,
      );
      expect(
        pickPairedGameResource(
          oggFileNames: oggs,
          wavFileNames: const <String>[],
          textTsMs: 32147200,
          textEventId: 16,
        ),
        all.first,
      );
      expect(all.length, 2, reason: '这组样本必须真的命中多资源，否则本用例没在测东西');
    });
  });

  group('companionVoiceResourceNames', () {
    test('主资源带事件 ID：收同一事件 ID 的其余资源，不含自己', () {
      expect(
        companionVoiceResourceNames(
          primaryName: '32147187_fushi_textseq16_onna_015.ogg',
          candidateNames: const <String>[
            '32147187_fushi_textseq16_onna_015.ogg',
            '32147150_fushi_textseq16_otoko_020.ogg',
            '32147188_fushi_textseq17_next.ogg',
          ],
        ),
        <String>['32147150_fushi_textseq16_otoko_020.ogg'],
      );
    });

    test('主资源无事件 ID：只收 tick 完全相同的', () {
      expect(
        companionVoiceResourceNames(
          primaryName: '32147200_onna_015.ogg',
          candidateNames: const <String>[
            '32147200_otoko_020.ogg',
            '32147201_almost_same.ogg',
          ],
        ),
        <String>['32147200_otoko_020.ogg'],
      );
    });

    test('无事件 ID 的主资源不会把带标资源按同 tick 收走', () {
      // 带标资源已被 native 绑给某条具体文本，凑巧同 tick 不构成归属证据。
      expect(
        companionVoiceResourceNames(
          primaryName: '32147200_onna_015.ogg',
          candidateNames: const <String>[
            '32147200_fushi_textseq16_otoko_020.ogg',
          ],
        ),
        isEmpty,
      );
    });

    test('BGM/SE 不算伴音；主资源本身是 BGM 时直接空', () {
      expect(
        companionVoiceResourceNames(
          primaryName: '32147200_onna_015.ogg',
          candidateNames: const <String>['32147200_bgm_theme.ogg'],
        ),
        isEmpty,
      );
      expect(
        companionVoiceResourceNames(
          primaryName: '32147200_bgm_theme.ogg',
          candidateNames: const <String>['32147200_onna_015.ogg'],
        ),
        isEmpty,
      );
    });

    test('结果按文件名升序，不随枚举顺序漂', () {
      const List<String> candidates = <String>[
        '32147200_fushi_textseq16_c.ogg',
        '32147200_fushi_textseq16_a.ogg',
        '32147200_fushi_textseq16_b.ogg',
      ];
      final List<String> forward = companionVoiceResourceNames(
        primaryName: '32147200_fushi_textseq16_b.ogg',
        candidateNames: candidates,
      );
      expect(forward, <String>[
        '32147200_fushi_textseq16_a.ogg',
        '32147200_fushi_textseq16_c.ogg',
      ]);
      expect(
        companionVoiceResourceNames(
          primaryName: '32147200_fushi_textseq16_b.ogg',
          candidateNames: candidates.reversed.toList(),
        ),
        forward,
      );
    });

    test('主资源名不可解析时返回空（不猜）', () {
      expect(
        companionVoiceResourceNames(
          primaryName: 'not_a_dump_name.ogg',
          candidateNames: const <String>['32147200_onna_015.ogg'],
        ),
        isEmpty,
      );
    });
  });

  group('多段音频合成', () {
    test('只有自同步容器（ADTS/.aac）允许字节接续', () {
      expect(isSelfSynchronizingAudioContainer('aac'), isTrue);
      expect(isSelfSynchronizingAudioContainer('AAC'), isTrue);
      // m4a/mp4 有全局 moov，接起来是废文件。
      expect(isSelfSynchronizingAudioContainer('m4a'), isFalse);
      expect(isSelfSynchronizingAudioContainer('mp4'), isFalse);
    });

    test('concatAudioStreams 按顺序首尾相接', () {
      final Uint8List joined = concatAudioStreams(<Uint8List>[
        Uint8List.fromList(<int>[1, 2]),
        Uint8List.fromList(<int>[]),
        Uint8List.fromList(<int>[3, 4, 5]),
      ]);
      expect(joined, <int>[1, 2, 3, 4, 5]);
    });

    test('concatAudioStreams 空输入给空结果，不抛', () {
      expect(concatAudioStreams(const <Uint8List>[]), isEmpty);
    });

    test('没有可用资源时不产出音频', () async {
      expect(
        await transcodeVoiceResourcesToMiningAudio(
          resourcePaths: const <String>[],
          tempDir: '.',
          outputExtension: 'aac',
        ),
        isNull,
      );
    });
  });
}
