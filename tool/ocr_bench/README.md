# OCR benchmark harness

Measures Fushi's local OCR (and candidate ONNX models) on labelled image sets.
First used for Chinese in [docs/reviews/2026-11-04-chinese-ocr-bench.md](../../docs/reviews/2026-11-04-chinese-ocr-bench.md).

Two layers:

- **Recognizer only** (`bench_rec.py`): every recognizer reads the same
  ground-truth line crops, so differences come from the recognizer alone.
- **End to end** (detector + recognizer): the real app pipeline through
  `packages/fushi_server/tool/ocr_pipeline_eval.dart`, plus Python det+rec
  combinations through `bench_e2e.py`. Both are scored by `score_pipeline.py`.

The Python preprocessing mirrors the app's Dart code
(`ppocr_line_recognizer.dart`, `ppocr_line_detector.dart`), so recognizer numbers
transfer to the app.

Images and labels are **not checked in** (copyrighted pages and frames). Keep
them in a folder outside the repo and pass its path.

## Requirements

Python 3.12 with `onnxruntime numpy opencv-python pyclipper pillow pyyaml opencc`
(OpenCC is optional and only adds the Traditional→Simplified folded scores).
`ffmpeg`/`ffprobe` on PATH for the video set builders. Run scripts as
`python -I -X utf8 <script>` (UTF-8 output on Windows).

## Models

`--shipped` is the folder the app already downloads
(`<support>/ocr_models/manga-ctc/`). `--models` holds the candidates, laid out as
in `registry.py`:

| registry name | source (Hugging Face) | file |
|---|---|---|
| `kellenok_v0.2_fp16`, `kellenok_det_v0.2` | `Kellenok/PP-OCRv6_manga` @ `02af751f` | `rec/manga_rec_v0.2_fp16.onnx`, `det/manga_det_v0.2.onnx`, `ppocrv6_dict.txt` → `kel/` |
| `ppocrv6_small` | `PaddlePaddle/PP-OCRv6_small_rec_onnx` @ `b8f84f0b` | `inference.onnx`, `inference.yml` → `v6_small_rec/` |
| `ppocrv5_mobile` / `ppocrv5_server` | `PaddlePaddle/PP-OCRv5_{mobile,server}_rec_onnx` | `inference.onnx`, `inference.yml` → `v5_{mobile,server}_rec/` |
| `ppocrv5_mobile_det` / `ppocrv5_server_det` | `PaddlePaddle/PP-OCRv5_{mobile,server}_det_onnx` | `inference.onnx` → `v5_{mobile,server}_det/` |

All of them are Apache-2.0. Add `+nokana` to a recognizer name to mask kana
classes before decoding (a Chinese-mode experiment; see the report).

## Building sets

```sh
# Donghua, real burned-in subtitles: one frame per soft-subtitle event
python -I -X utf8 extract_video_real.py --video EP1.mkv --video EP2.mkv --out DATA/video_real --track 1
python -I -X utf8 label_consensus.py --mode subtitle --data DATA/video_real --models M --shipped S

# Donghua, synthetic subtitles rendered over real frames (exact ground truth)
python -I -X utf8 make_video_synth.py --video EP1.mkv --out DATA/video_synth

# Manhua pages from your own books (folders or .cbz)
python -I -X utf8 make_manga_set.py --book name=PATH --out DATA/manga_real
python -I -X utf8 label_consensus.py --mode page --data DATA/manga_real --models M --shipped S

# Public smoke set: Pepper&Carrot (CC BY 4.0), Simplified Chinese, page-level text
python -I -X utf8 make_peppercarrot_set.py --out DATA/peppercarrot
```

`label_consensus.py` accepts a line when at least 3 of 4 independent
recognizers read the same text, and writes the rest to `review/` + `review.jsonl`.
A person fills `review_fixes.json` (`{"<image>#<line>": "text" | null}`) and
re-runs it. Spot-check some agreed lines too; the report says how many labels
were checked by hand.

## Running

```sh
python -I -X utf8 bench_rec.py --data DATA/manga_real --models M --shipped S --group vertical
python -I -X utf8 bench_e2e.py --data DATA/video_real --models M --shipped S \
    --det ppocrv6_small_det --rec kellenok_v0.2 --out preds.jsonl
python -I -X utf8 score_pipeline.py --data DATA/video_real --pred preds.jsonl --precision-band 0.78
```

The app pipeline (from `packages/fushi_server/`; copy the shipped models to
`<server-data>/support/ocr_models/manga-ctc/` first):

```sh
dart run tool/ocr_pipeline_eval.dart --data DATA/manga_real --server-data SERVER \
    --out app.jsonl --ort <path to onnxruntime.dll>   # --mode text --band 0.78 for the bitmap path
```

Timings are single-machine CPU numbers (4 threads in Python); compare them
within one run, not across machines.
