# Manga panel detector model asset

The model is derived from `leoxs22/manga-panel-detector-yolo26n` at revision
`535bbe1fc1e922d2108f918cd1bce29ba3516196` (Apache-2.0). The upstream repository
contains PyTorch and TFLite files, not an ONNX release. `export_yolo26n_onnx.py`
exports a fixed batch-1, opset-17 ONNX graph with NMS included; run
`verify_onnx_contract.py` before uploading an immutable GitHub release asset.

The checked-in `model_manifest.json` records the source, contract, and the
verified immutable release asset (`manga-panel-detector-onnx-v1`). Consumers
must refuse a manifest without a digest and byte count rather than download an
unverified blob. The export script writes the SHA-256 and byte count when a new
asset is produced.

## Training data attribution

The upstream weights are trained on **Manga109-s**
(<http://www.manga109.org/en/download_s.html>). Its terms allow commercial use
of models derived from the dataset **provided that the use of the dataset is
clearly indicated**, so the attribution travels with this manifest
(`trainingData` in `model_manifest.json`,
`kMangaPanelModelTrainingData*` in
`packages/fushi_engine/lib/media/manga/panel_model_manifest.dart`) and with the
`On-device models` table in the repository README — not only in the upstream
model card.

Dataset citations:

- Y. Matsui et al., "Sketch-based Manga Retrieval using Manga109 Dataset",
  *Multimedia Tools and Applications*, 2017.
- K. Aizawa et al., "Building a Manga Dataset “Manga109” with Annotations for
  Multimedia Applications", *IEEE MultiMedia*, 2020.
