import 'package:test/test.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/media/manga/mokuro_sidecar.dart';

void main() {
  test('matches by page identity and retains unmatched pages', () {
    const MokuroPayload downloaded = MokuroPayload(
      images: <MokuroImage>[
        MokuroImage(
          url: 'images/page-000001.jpg',
          size: MokuroSize(100, 200),
          blocks: <MokuroBlock>[],
        ),
        MokuroImage(
          url: 'images/page-000002.jpg',
          size: MokuroSize(120, 220),
          blocks: <MokuroBlock>[],
        ),
      ],
    );
    final MokuroSidecarMergeResult result = mergeMokuroSidecar(
      downloaded: downloaded,
      sourceUrls: const <String>['https://cdn.test/001.jpg', 'https://cdn.test/002.jpg'],
      sidecarJson: '{"pages":[{"img_path":"002.jpg","img_width":120,"img_height":220,"blocks":[{"box":[1,2,10,20],"lines":["ok"]}]},{"img_path":"missing.jpg","img_width":100,"img_height":200,"blocks":[]}]}'
    );
    expect(result.matchedPages, 1);
    expect(result.payload.images[0].blocks, isEmpty);
    expect(result.payload.images[1].blocks, hasLength(1));
  });

  test('rejects wrong dimensions and invalid rectangles', () {
    const MokuroPayload downloaded = MokuroPayload(
      images: <MokuroImage>[
        MokuroImage(url: 'images/page-000001.jpg', size: MokuroSize(100, 200), blocks: <MokuroBlock>[]),
      ],
    );
    final MokuroSidecarMergeResult result = mergeMokuroSidecar(
      downloaded: downloaded,
      sidecarJson: '{"pages":[{"img_path":"001.jpg","img_width":99,"img_height":200,"blocks":[{"box":[-1,0,10,10],"lines":["bad"]}]}]}',
    );
    expect(result.accepted, isFalse);
  });
}
