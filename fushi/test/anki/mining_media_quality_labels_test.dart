import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/mining_media_quality_labels.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show MiningMediaCompression;

/// 反馈 28v5dFPrr0：制卡图片 / 音频质量每档都要给出具体参数，且数值跟编码表同源。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('档名与编码表档数一致', () {
    expect(
      miningImageQualityTierNames(),
      hasLength(MiningMediaCompression.imageTierCount),
    );
    expect(
      miningAudioQualityTierNames(),
      hasLength(MiningMediaCompression.audioTierCount),
    );
  });

  test('图片各档说明读编码表的截图长边与 GIF 宽度 / 帧率', () {
    for (int i = 0; i < MiningMediaCompression.imageTierMax; i++) {
      final spec = MiningMediaCompression.imageTiers[i];
      final String detail = miningImageQualityTierDetail(i);
      expect(detail, contains('${spec.maxLongEdge} px'));
      expect(detail, contains('${spec.gifWidth} px'));
      expect(detail, contains('${spec.gifFps} fps'));
    }
    expect(
      miningImageQualityTierDetail(0),
      'Screenshots up to 720 px on the long side · GIFs 360 px wide at 6 fps',
    );
  });

  test('顶格档：截图原图直通，GIF 用封顶参数', () {
    final String detail = miningImageQualityTierDetail(
      MiningMediaCompression.imageTierMax,
    );
    expect(detail, contains('full source resolution'));
    expect(detail, contains('${MiningMediaCompression.gifMaxTierWidth} px'));
    expect(detail, contains('${MiningMediaCompression.gifMaxTierFps} fps'));
  });

  test('音频各档：声道 + kbps', () {
    expect(miningAudioQualityTierDetail(0), 'Mono, 64 kbps');
    expect(miningAudioQualityTierDetail(1), 'Stereo, 128 kbps');
    expect(miningAudioQualityTierDetail(2), 'Stereo, 192 kbps');
    // 越界档位夹到合法范围，不抛。
    expect(miningAudioQualityTierDetail(99), 'Stereo, 192 kbps');
    expect(miningImageQualityTierDetail(-1), miningImageQualityTierDetail(0));
  });
}
