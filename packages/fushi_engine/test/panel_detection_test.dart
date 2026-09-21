import 'package:test/test.dart';
import 'package:fushi_engine/media/manga/panel_detection.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/media/manga/mokuro_sidecar.dart';

void main() {
  test('orders panels in RTL and removes heavy overlap', () {
    final List<PanelRect> panels = orderPanelRects(<PanelRect>[
      const PanelRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.5, score: 0.4),
      const PanelRect(
        left: 0.12,
        top: 0.12,
        right: 0.88,
        bottom: 0.48,
        score: 0.9,
      ),
      const PanelRect(
        left: 0.1,
        top: 0.55,
        right: 0.4,
        bottom: 0.9,
        score: 0.8,
      ),
      const PanelRect(
        left: 0.6,
        top: 0.55,
        right: 0.9,
        bottom: 0.9,
        score: 0.8,
      ),
    ], direction: PanelReadingDirection.rtl);
    expect(panels, hasLength(3));
    expect(panels[1].centerX, greaterThan(panels[2].centerX));
  });

  test('splits a large panel when text boxes provide anchors', () {
    const PanelRect whole = PanelRect(left: 0, top: 0, right: 1, bottom: 1);
    final List<PanelRect> result = splitLargePanel(whole, const <PanelTextBox>[
      PanelTextBox(
        rect: PanelRect(left: 0.2, top: 0.2, right: 0.3, bottom: 0.3),
        score: 0.9,
      ),
      PanelTextBox(
        rect: PanelRect(left: 0.7, top: 0.7, right: 0.8, bottom: 0.8),
        score: 0.9,
      ),
    ], direction: PanelReadingDirection.ltr);
    expect(result, hasLength(2));
    expect(result.first.top, 0);
    expect(result.last.bottom, 1);
  });

  test('merges sidecar blocks without replacing managed URLs', () {
    const MokuroPayload downloaded = MokuroPayload(
      images: <MokuroImage>[
        const MokuroImage(
          url: 'images/page-000001.jpg',
          size: MokuroSize(100, 200),
          blocks: <MokuroBlock>[],
        ),
      ],
    );
    final MokuroSidecarMergeResult result = mergeMokuroSidecar(
      downloaded: downloaded,
      sidecarJson:
          '{"pages":[{"img_path":"001.jpg","img_width":100,"img_height":200,"blocks":[{"box":[1,2,10,20],"lines":["x"]}]}]}',
    );
    expect(result.accepted, isTrue);
    expect(result.payload.images.single.url, 'images/page-000001.jpg');
    expect(result.payload.images.single.blocks, hasLength(1));
  });
}
