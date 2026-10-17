import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/mining_sentence_draft.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_controller.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart'
    show VideoMiningImageMode;

import 'advanced_mining_test_host.dart';

/// 「高级制卡」的选择 → 覆盖项（[MiningRequestOverrides]）编码，以及句子 / 音频的
/// 宿主往返。对话框只是这份状态的投影，产出什么由这里一处决定。
void main() {
  late FakeAdvancedMiningHost host;

  setUp(() => host = FakeAdvancedMiningHost());

  Future<AdvancedMiningController> loaded(AdvancedMiningController c) async {
    await c.load();
    return c;
  }

  test('什么都不动：覆盖项为空，与一键「+」等价', () async {
    final AdvancedMiningController c = await loaded(
      AdvancedMiningController(host.videoPage()),
    );
    expect(c.buildOverrides().isEmpty, isTrue);
  });

  test('卡组：只有与默认不同时才写，选回默认就不写', () async {
    final AdvancedMiningController c = await loaded(
      AdvancedMiningController(host.videoPage()),
    );
    c.selectDeck('日语::动画');
    expect(c.buildOverrides().deckName, '日语::动画');
    c.selectDeck('日语::挖矿');
    expect(c.buildOverrides().deckName, isNull);
  });

  test('没有默认卡组时预选第一个，并如实写进覆盖项', () async {
    final AdvancedMiningController c = await loaded(
      AdvancedMiningController(
        host.capabilities(deck: host.deck(defaultDeck: null)),
      ),
    );
    expect(c.deckName, '日语::挖矿');
    expect(c.buildOverrides().deckName, '日语::挖矿');
  });

  test('音频起止偏移：每次微调都重新 describe，偏移进覆盖项', () async {
    final AdvancedMiningController c = await loaded(
      AdvancedMiningController(host.videoPage()),
    );
    c.nudgeAudioEdge(start: false, deltaMs: 250);
    c.nudgeAudioEdge(start: true, deltaMs: -250);
    await pumpEventQueue();
    expect(host.describeCalls.last, <int>[-250, 250]);
    final MiningRequestOverrides o = c.buildOverrides();
    expect(o.audioStartDeltaMs, -250);
    expect(o.audioEndDeltaMs, 250);
    expect(
      c.audioWindow!.startMs,
      FakeAdvancedMiningHost.sentenceStartMs - 250,
    );
  });

  test('不要音频：视频片段不可选，已选片段时退回动图', () async {
    final AdvancedMiningController c = await loaded(
      AdvancedMiningController(
        host.videoPage(defaultMode: VideoMiningImageMode.videoClip),
      ),
    );
    expect(c.videoImageMode, VideoMiningImageMode.videoClip);
    c.setOmitAudio(true);
    expect(c.isImageModeEnabled(VideoMiningImageMode.videoClip), isFalse);
    expect(c.videoImageMode, VideoMiningImageMode.gif);
    c.selectVideoImageMode(VideoMiningImageMode.videoClip);
    expect(c.videoImageMode, VideoMiningImageMode.gif, reason: '禁用的方式点不上');
    final MiningRequestOverrides o = c.buildOverrides();
    expect(o.omitAudio, isTrue);
    expect(o.videoImageMode, VideoMiningImageMode.gif.wireName);
  });

  test('动图首尾帧逐帧挪动 = 挪同一对音频偏移（步长 frameStepMs）', () async {
    final AdvancedMiningController c = await loaded(
      AdvancedMiningController(host.videoPage()),
    );
    c.nudgeVideoEdge(first: true, forward: true);
    c.nudgeVideoEdge(first: false, forward: false);
    final MiningRequestOverrides o = c.buildOverrides();
    expect(o.audioStartDeltaMs, 42);
    expect(o.audioEndDeltaMs, -42);
    expect(o.videoImageMode, isNull, reason: '方式没变');
  });

  test('静态帧：挪过才写 coverFrameAtMs；切方式写 wireName', () async {
    final AdvancedMiningController c = await loaded(
      AdvancedMiningController(host.videoPage()),
    );
    c.selectVideoImageMode(VideoMiningImageMode.currentFrame);
    expect(c.buildOverrides().coverFrameAtMs, isNull);
    expect(
      c.buildOverrides().videoImageMode,
      VideoMiningImageMode.currentFrame.wireName,
    );
    c.nudgeStillFrame(forward: true);
    c.nudgeStillFrame(forward: true);
    expect(c.buildOverrides().coverFrameAtMs, 725000 + 84);
    c.nudgeStillFrame(forward: false);
    c.nudgeStillFrame(forward: false);
    expect(c.buildOverrides().coverFrameAtMs, isNull, reason: '挪回原处 = 没挪');
  });

  test('图片选「不要」→ omitImage', () async {
    final AdvancedMiningController c = await loaded(
      AdvancedMiningController(host.videoPage()),
    );
    c.selectVideoImageMode(null);
    final MiningRequestOverrides o = c.buildOverrides();
    expect(o.omitImage, isTrue);
    expect(o.videoImageMode, isNull);
  });

  test('基准时刻不可用的静态方式不出现', () async {
    final AdvancedMiningController c = await loaded(
      AdvancedMiningController(
        host.capabilities(
          // 没有查词瞬间那一帧的视频来源（例如远端流）。
          video: const AdvancedMiningVideoImageSection(
            modes: VideoMiningImageMode.values,
            defaultMode: VideoMiningImageMode.gif,
            subtitleStartMs: 1000,
          ),
        ),
      ),
    );
    expect(
      c.availableImageModes,
      isNot(contains(VideoMiningImageMode.currentFrame)),
    );
  });

  group('漫画裁切', () {
    test('模型可用：默认所在分镜，确认带 crop + 页号', () async {
      final AdvancedMiningController c = await loaded(
        AdvancedMiningController(host.mangaPage()),
      );
      expect(c.cropChoice, MangaCropChoice.panel);
      final MiningImageCrop crop = c.buildOverrides().crop!;
      expect(crop.pageIndex, 46);
      expect(crop.left, closeTo(0.51, 1e-9));
      expect(crop.bottom, closeTo(0.67, 1e-9));
    });

    test('整页也带 crop（0,0,1,1）：用户明确不裁，压过默认裁分镜设置', () async {
      final AdvancedMiningController c = await loaded(
        AdvancedMiningController(host.mangaPage()),
      );
      c.selectCropChoice(MangaCropChoice.wholePage);
      final MiningRequestOverrides o = c.buildOverrides();
      expect(o.isEmpty, isFalse);
      expect(o.crop!.isWholePage, isTrue);
    });

    test('无模型：默认文字周围；「不要」→ omitImage 不带 crop', () async {
      final AdvancedMiningController c = await loaded(
        AdvancedMiningController(host.mangaPage(modelAvailable: false)),
      );
      expect(c.cropChoice, MangaCropChoice.textArea);
      c.selectCropChoice(MangaCropChoice.none);
      final MiningRequestOverrides o = c.buildOverrides();
      expect(o.omitImage, isTrue);
      expect(o.crop, isNull);
    });

    test('在图上动框 → 自定义；Tab 切到所在分镜 → 记成所在分镜', () async {
      final AdvancedMiningController c = await loaded(
        AdvancedMiningController(host.mangaPage()),
      );
      c.setCropRect(const Rect.fromLTRB(0.1, 0.1, 0.5, 0.5));
      expect(c.cropChoice, MangaCropChoice.custom);
      expect(c.buildOverrides().crop!.right, closeTo(0.5, 1e-9));
      c.setCropRect(
        FakeAdvancedMiningHost.mangaSuggestions.containingPanel!,
        fromPanelCycle: true,
      );
      expect(c.cropChoice, MangaCropChoice.panel);
      c.setCropRect(
        FakeAdvancedMiningHost.mangaSuggestions.panels.first,
        fromPanelCycle: true,
      );
      expect(c.cropChoice, MangaCropChoice.custom);
    });

    test('下载模型：完成后重拿建议并切到所在分镜', () async {
      final AdvancedMiningController c = await loaded(
        AdvancedMiningController(host.mangaPage(modelAvailable: false)),
      );
      final Future<bool> done = c.downloadPanelModel();
      await pumpEventQueue();
      host.downloadController!.add(4000000);
      await pumpEventQueue();
      expect(c.downloadedBytes, 4000000);
      await host.downloadController!.close();
      expect(await done, isTrue);
      expect(c.panelModelAvailable, isTrue);
      expect(host.suggestionLoads.length, 2);
      expect(c.cropChoice, MangaCropChoice.panel);
    });
  });

  group('句子', () {
    test('× 最外侧前文 = 句数减一；中间句 = 移除', () async {
      host.prevCount = 2;
      final AdvancedMiningController c = await loaded(
        AdvancedMiningController(host.videoPage()),
      );
      await c.dismissSentence(SentenceContextSlot.prev, 1);
      expect(host.removeCalls.single, <Object>[
        SentenceContextSlot.prev,
        1,
        true,
      ]);
      expect(c.prevRemoved, <bool>[false, true]);
      await c.dismissSentence(SentenceContextSlot.prev, 0);
      expect(host.setContextCalls.last, <int>[1, 1]);
    });

    test('「恢复默认」：上下文回到打开时的快照，选择全部归位', () async {
      final AdvancedMiningController c = await loaded(
        AdvancedMiningController(host.videoPage()),
      );
      await c.adjustContext(prevDir: true, plus: true);
      c.selectDeck('日语::听力');
      c.nudgeAudioEdge(start: true, deltaMs: 250);
      c.selectVideoImageMode(VideoMiningImageMode.subtitleStart);
      expect(c.buildOverrides().isEmpty, isFalse);
      await c.resetToDefaults();
      expect(host.setContextCalls.last, <int>[1, 1]);
      expect(c.prev.length, 1);
      expect(c.buildOverrides().isEmpty, isTrue);
    });

    test('加到封顶：宿主不再给更多句时禁用「加一句」', () async {
      final FakeAdvancedMiningHost capped = FakeAdvancedMiningHost(maxPrev: 1);
      final AdvancedMiningController c = await loaded(
        AdvancedMiningController(capped.videoPage()),
      );
      await c.adjustContext(prevDir: true, plus: true);
      expect(c.prevAtMax, isTrue);
    });
  });
  group('打码', () {
    const MiningMosaicRegion a = MiningMosaicRegion(
      left: 0.1,
      top: 0.1,
      right: 0.4,
      bottom: 0.3,
    );
    const MiningMosaicRegion b = MiningMosaicRegion(
      left: 0.5,
      top: 0.5,
      right: 0.9,
      bottom: 0.8,
    );

    test('视频：静态方式对着那一帧；动图 / 片段也能打码（降级为字幕开头静帧并提示）', () async {
      final AdvancedMiningController c = await loaded(
        AdvancedMiningController(host.videoPage()),
      );
      c.selectVideoImageMode(VideoMiningImageMode.subtitleStart);
      expect(c.mosaicApplicable, isTrue);
      expect(c.mosaicForcesStill, isFalse);
      expect(c.mosaicFrameMs, 724100);
      c.nudgeStillFrame(forward: true);
      expect(c.mosaicFrameMs, 724100 + 42, reason: '挪了帧就对着新那一帧');
      c.setMosaicRegions(<MiningMosaicRegion>[a, b]);
      expect(c.buildOverrides().mosaic, <MiningMosaicRegion>[a, b]);

      c.selectVideoImageMode(VideoMiningImageMode.gif);
      expect(c.mosaicApplicable, isTrue);
      expect(c.mosaicForcesStill, isTrue);
      expect(c.mosaicFrameMs, 724100, reason: '降级后出的是字幕开头那一帧');
      final MiningRequestOverrides gif = c.buildOverrides();
      expect(gif.mosaic, <MiningMosaicRegion>[a, b]);
      expect(gif.videoImageMode, isNull, reason: '方式没改，降级由宿主按打码判');

      c.selectVideoImageMode(VideoMiningImageMode.currentFrame);
      expect(c.mosaicForcesStill, isFalse);
      expect(c.mosaicFrameMs, 725000);

      c.selectVideoImageMode(null);
      final MiningRequestOverrides none = c.buildOverrides();
      expect(none.omitImage, isTrue);
      expect(none.mosaic, isEmpty, reason: '不要图片时不带码');
    });

    test('视频：取不到帧的来源不能打码', () async {
      final AdvancedMiningController c = await loaded(
        AdvancedMiningController(
          host.capabilities(
            video: host.video(
              defaultMode: VideoMiningImageMode.currentFrame,
              withFrames: false,
            ),
          ),
        ),
      );
      c.setMosaicRegions(<MiningMosaicRegion>[a]);
      expect(c.mosaicApplicable, isFalse);
      expect(c.buildOverrides().mosaic, isEmpty);
    });

    test('漫画：与裁切共存（码相对整页，不随取景框变）；「不要」时不带', () async {
      final AdvancedMiningController c = await loaded(
        AdvancedMiningController(host.mangaPage()),
      );
      c.setMosaicRegions(<MiningMosaicRegion>[a]);
      MiningRequestOverrides o = c.buildOverrides();
      expect(o.crop!.pageIndex, 46);
      expect(o.mosaic, <MiningMosaicRegion>[a]);
      c.setCropRect(const Rect.fromLTRB(0.2, 0.2, 0.6, 0.6));
      o = c.buildOverrides();
      expect(o.mosaic, <MiningMosaicRegion>[a], reason: '换取景框不改打码坐标');
      c.selectCropChoice(MangaCropChoice.none);
      o = c.buildOverrides();
      expect(o.omitImage, isTrue);
      expect(o.mosaic, isEmpty);
    });

    test('静态截图分区：截图到手才能打码；清除 / 恢复默认清空', () async {
      final Uint8List png = Uint8List.fromList(<int>[1, 2, 3]);
      final AdvancedMiningController c = await loaded(
        AdvancedMiningController(
          host.capabilities(
            deck: host.deck(),
            still: AdvancedMiningStillImageSection(
              loadImage: () async => png,
              mosaicForcesStill: true,
            ),
          ),
        ),
      );
      expect(c.stillImageBytes, same(png));
      expect(c.mosaicApplicable, isTrue);
      expect(c.buildOverrides().isEmpty, isTrue, reason: '没打码 = 一键「+」');
      c.setMosaicRegions(<MiningMosaicRegion>[a, b]);
      expect(c.buildOverrides().mosaic, hasLength(2));
      c.clearMosaic();
      expect(c.buildOverrides().isEmpty, isTrue);
      c.setMosaicRegions(<MiningMosaicRegion>[b]);
      await c.resetToDefaults();
      expect(c.mosaicRegions, isEmpty);
    });

    test('静态截图分区：抓不到图时不能打码', () async {
      final AdvancedMiningController c = await loaded(
        AdvancedMiningController(
          host.capabilities(
            still: AdvancedMiningStillImageSection(loadImage: () async => null),
          ),
        ),
      );
      expect(c.stillImageBytes, isNull);
      expect(c.stillImageLoading, isFalse);
      c.setMosaicRegions(<MiningMosaicRegion>[a]);
      expect(c.buildOverrides().mosaic, isEmpty);
    });
  });
}
