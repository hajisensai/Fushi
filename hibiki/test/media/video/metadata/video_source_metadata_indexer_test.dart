import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';
import 'package:hibiki/src/media/video/metadata/video_source_metadata_indexer.dart';

void main() {
  test('Kodi local extra names are classified without matching normal episodes',
      () {
    expect(
      classifyLocalVideoExtra(r'D:\Shows\Title\Trailers\official.mkv')?.kind,
      VideoMetadataExtraKind.trailer,
    );
    expect(
      classifyLocalVideoExtra(r'D:\Shows\Title\Behind The Scenes\making-of.mkv')
          ?.kind,
      VideoMetadataExtraKind.behindTheScenes,
    );
    expect(
      classifyLocalVideoExtra(r'D:\Movies\Film-trailer.mp4')?.kind,
      VideoMetadataExtraKind.trailer,
    );
    expect(classifyLocalVideoExtra(r'D:\Shows\Title\Title.S01E01.mkv'), isNull);
  });
}
