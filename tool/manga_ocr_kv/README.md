# manga-ocr KV-cache decoder (OCR speed-up pack)

The classic local manga OCR model is `kha-white/manga-ocr-base` as exported by
`mayocream/manga-ocr-onnx`. Its `decoder_model.onnx` has no KV cache: every
beam-search step re-runs the whole sequence, including the cross-attention
projections of all 197 encoder tokens (about 3.7 GFLOPs per step at beam 4).

This directory re-exports the same weights
(`kha-white/manga-ocr-base` at revision
`aa6573bd10b0d446cbf622e29c3e084914df9741`, Apache-2.0) as two graphs that
decode one token per step:

| File | What it does |
|---|---|
| `cross_kv.onnx` | `encoder_hidden_states` → the cross-attention K/V of both decoder layers; run once per text block |
| `decoder_kv.onnx` | one new token per beam + `beam_idx` + past K/V → last-position logits + present K/V; beam reordering is a Gather inside the graph |

The encoder and vocabulary stay the files from `mayocream/manga-ocr-onnx`.
Recognition output is **token-for-token identical** to the classic decoder
(240 of 240 real text blocks matched both HF `generate` and the classic ONNX
graphs); on an i5-12600KF with ONNX Runtime 1.22 CPU (2 threads, beam 4) a
block takes 298–344 ms instead of 504–685 ms. The exact contract (names,
dtypes, shapes, the zero placeholder past for the first step) is in
`model_manifest.json` and in the header of
`packages/fushi_engine/lib/ocr/manga_ocr_kv_recognizer.dart`.

## How the app uses it

`kMangaOcrKvAcceleratorManifest` (`manga_ocr_model_manifest.dart`) lists the
two files as an optional *accelerator* for the classic model:

- Downloading the classic model downloads the accelerator after the required
  files; a model that is already installed shows a one-click “speed-up pack”
  button in the manga OCR settings.
- Both files are checked against the sha256 below after download; a mismatch
  deletes the file.
- The accelerator does not affect model readiness or the model fingerprint, so
  volumes recognized before it was installed are not recognized again.
- When both files are present the page session builds `MangaOcrKvRecognizer`;
  otherwise it keeps using the classic decoder.

## Producing and verifying the assets

```sh
pip install torch==2.5.1 transformers==4.46.3 onnx onnxruntime numpy
python export_manga_ocr_kv_onnx.py --out out/
python verify_onnx_contract.py --dir out/ --manifest model_manifest.json \
    --classic-encoder encoder_model.onnx --classic-decoder decoder_model.onnx
```

The exporter checks its wrapper modules against the HF decoder and the ONNX
graphs against the wrapper modules (maximum absolute logit difference must
stay below 1e-3; the release export measured 2.1e-5). `verify_onnx_contract.py`
checks the release files against this manifest and, given the classic mayocream
graphs, steps the KV graphs through a beam schedule with forks and a beam swap
and compares every logit row with the classic decoder.

The exported bytes depend on the torch / transformers versions. A different
toolchain produces a different sha256: publish it as a new release tag and
update both this manifest and `kMangaOcrKvAcceleratorManifest` rather than
replacing the files of an existing tag.

## Release asset

Tag `manga-ocr-kv-onnx-v1` on `hajisensai/Fushi`: prerelease, not Latest, no
app binaries attached. The release notes state the source revision, the
contract, both sha256 digests and the license.

| File | Bytes | sha256 |
|---|---|---|
| `cross_kv.onnx` | 9456696 | `3355a58b0e05f874d7fbb332df6824c0e6634d0b99c756322ba119a9d3f35722` |
| `decoder_kv.onnx` | 89050460 | `db4907131dc96308c3d9e4910db2238cf2dee5cfcb1cd3ae7c7b52d630cd8de5` |

## Training data attribution

manga-ocr acknowledges the **Manga109-s** dataset
(<http://www.manga109.org/en/download_s.html>) and the CC-100 text corpus.
Manga109-s terms allow commercial use of derived models provided that the use
of the dataset is clearly indicated, so the attribution travels with this
manifest and with the `On-device models` table in the repository README.
