import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_controller.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/mining/sentence_audio_source.dart';

import 'advanced_mining_test_host.dart';

/// 高级制卡里临时切换句子音频来源（反馈 pNF2ZL7Kfc）：只进这一张卡的覆盖项，与设置
/// 相同就不写（= 一键「+」）。
void main() {
  late FakeAdvancedMiningHost host;

  setUp(() => host = FakeAdvancedMiningHost());

  Future<AdvancedMiningController> loaded({
    SentenceAudioSourcePick defaultPick = SentenceAudioSourcePick.currentTrack,
    bool withSources = true,
  }) async {
    final AdvancedMiningAudioSection base = host.audio();
    final AdvancedMiningController c = AdvancedMiningController(
      host.capabilities(
        deck: host.deck(),
        audio: AdvancedMiningAudioSection(
          describe: base.describe,
          preview: base.preview,
          stopPreview: base.stopPreview,
          sources: withSources
              ? AdvancedMiningAudioSources(
                  choices: <SentenceAudioSourcePick>[
                    SentenceAudioSourcePick.currentTrack,
                    SentenceAudioSourcePick.frontCenter,
                    SentenceAudioSourcePick.track(0),
                    SentenceAudioSourcePick.track(1),
                  ],
                  defaultPick: defaultPick,
                )
              : null,
        ),
      ),
    );
    await c.load();
    return c;
  }

  test('打开时选中设置里的来源；不动 = 覆盖项为空', () async {
    final AdvancedMiningController c = await loaded(
      defaultPick: SentenceAudioSourcePick.frontCenter,
    );
    expect(c.audioSource, SentenceAudioSourcePick.frontCenter);
    expect(c.buildOverrides().isEmpty, isTrue);
  });

  test('改了来源才写进覆盖项；改回设置值就不写', () async {
    final AdvancedMiningController c = await loaded();
    c.setAudioSource(SentenceAudioSourcePick.track(1));
    expect(c.buildOverrides().audioSource, 'track:1');
    c.setAudioSource(SentenceAudioSourcePick.frontCenter);
    expect(c.buildOverrides().audioSource, 'front_center');
    c.setAudioSource(SentenceAudioSourcePick.currentTrack);
    expect(c.buildOverrides().audioSource, isNull);
  });

  test('不要音频时不带来源；恢复默认回到设置值', () async {
    final AdvancedMiningController c = await loaded();
    c.setAudioSource(SentenceAudioSourcePick.frontCenter);
    c.setOmitAudio(true);
    final MiningRequestOverrides o = c.buildOverrides();
    expect(o.omitAudio, isTrue);
    expect(o.audioSource, isNull);
    c.setOmitAudio(false);
    await c.resetToDefaults();
    expect(c.audioSource, SentenceAudioSourcePick.currentTrack);
  });

  test('页面不给来源选项时恒不写', () async {
    final AdvancedMiningController c = await loaded(withSources: false);
    expect(c.audioSource, isNull);
    expect(c.buildOverrides().audioSource, isNull);
  });
}
