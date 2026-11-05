# Chinese OCR benchmark: manhua and donghua (2026-11-04)

**Question.** Can Fushi's on-device OCR handle Chinese media, and should it add
small Chinese models for it? Candidates: `Kellenok/PP-OCR_manga`
(PP-OCRv6_manga) for manhua and illustrations, PP-OCRv5 for donghua and video.

**Answer.** No new model is needed. The current local pipeline already reads
Chinese well. The PP-OCRv6_manga recognizer named in the request is already the app's manga
recognizer (`kellenok_manga_rec_v0.2.onnx`), and its model card covers Chinese.
PP-OCRv5 was not better than what ships on any set, and costs a new 16–85 MB
download. No app code changes in this round; the harness (`tool/ocr_bench/`,
`packages/fushi_server/tool/ocr_pipeline_eval.dart`) is checked in so the
numbers can be rerun.

## Sets

None of the images are in the repo (copyright). Ground truth:

| set | what | lines / pages | how labelled |
|---|---|---|---|
| `video_real` | *A Record of a Mortal's Journey to Immortality* ep 191 and 192 (4K, burned-in Simplified Chinese subtitles: thin, semi-transparent, no outline). One frame per soft-subtitle event. | 193 lines / 200 frames | 3-of-4 recognizer consensus (192), 1 by hand; 3 false boxes dropped; 24 agreed lines spot-checked by eye, all correct. 8 frames have no subtitle (checked). |
| `video_synth` | Original Chinese subtitle lines (`lines_zh.txt`) rendered over 160 real frames of the same episodes: 11 fonts (YaHei, DengXian, SimHei, SimSun, KaiTi, JhengHei, MingLiU, DFKai), outline / shadow / yellow / thin / boxed, 45% Traditional, 25% with an English second line. | 160 lines | exact (rendered) |
| `manga_real` | 24 pages from two Traditional-Chinese editions of Japanese manga (化物语, 向丑女献上花束): typeset vertical columns, hand-lettered text, side notes, scanlation credit pages. | 459 lines | consensus (415, 28 spot-checked, all correct) + 44 by hand; 76 detector boxes dropped (untranslated Japanese SFX, a Japanese ad page, art, punctuation only, boxes spanning two columns) |
| `peppercarrot` | *Pepper&Carrot* by David Revoy (CC BY 4.0), Simplified Chinese translation by Ran Zhuang, Yan Jing, Lou Simons; episodes 21–29, credit pages excluded. Native horizontal comic layout in a hand-lettering font (Xiaolai SC). | 60 pages | the translation SVG text of each page (page level only) |

Consensus labels make the "agreed" lines easy for every model by construction,
so the hand-labelled subsets are the fairest comparison where they exist.

Scores use the "body" text view (NFKC, letters and digits only) from the
2026-10-15 review, and additionally fold Traditional→Simplified (OpenCC t2s) on
both sides so a model reading 這 as 这 is not counted wrong. Machine: Ryzen 7
5800X3D, CPU only, ONNX Runtime 1.31, 4 threads.

## 1. Recognizers on the same crops

`bench_rec.py`: every model reads the ground-truth line crops (vertical columns
are rotated like the app does). CER is body view, folded.

| recognizer | size | manhua (459) | manhua, hand-labelled (44) | manhua, horizontal (58) | real subtitles (193) | synthetic subtitles (160) | ms/line |
|---|---:|---:|---:|---:|---:|---:|---:|
| **Kellenok v0.2** (shipped) | 21.2 MB | 2.07% | **17.9%** | 5.80% | 0.07% | 0.59% | 10 |
| Kellenok v0.2 fp16 | 10.6 MB | 2.07% | 17.9% | 5.80% | 0.07% | 0.59% | 12 |
| PP-OCRv6 small | 21.2 MB | **1.89%** | 19.6% | **1.09%** | **0.00%** | 0.32% | 10 |
| PP-OCRv5 mobile | 16.5 MB | 3.82% | 31.3% | 7.25% | 0.07% | 0.91% | 11 |
| PP-OCRv5 server | 84.5 MB | 2.12% | 20.1% | 3.62% | 0.14% | **0.21%** | 43 |

- **Kellenok and PP-OCRv6 small are effectively tied on Chinese.** Kellenok is
  best on the hard hand-lettered lines; PP-OCRv6 small is better on horizontal
  lines (scanlation credits, small horizontal SFX).
- **PP-OCRv5 mobile is worst everywhere.** PP-OCRv5 server is never clearly
  ahead of PP-OCRv6 small, but is 4× larger and 4× slower.
- **Kellenok's errors on Chinese come from its Japanese training data**:
  Japanese glyph forms (歳 for 歲), stray kana (呼っ, 別田っ), kana for
  untranslated SFX. Masking kana classes before the CTC argmax when the
  language is Chinese (`+nokana` in the harness) helped the hard lines
  (17.9% → 16.2%) but hurt the easy ones (0.65% → 1.15%), because a masked kana
  is replaced by a look-alike ideograph instead of nothing. Not worth adopting.
- **fp16 Kellenok gives the same text as fp32** on 808 of 809 distinct lines
  (one character read as its Traditional form: 辗 → 輾) at half the size.

## 2. Donghua: end to end on real burned-in subtitles

Whole 1920×1080 frames; precision counts only predictions in the bottom 22%
(the subtitle band), so on-screen logos and signs are not counted as noise.

| pipeline | line CER | line exact | char recall | char precision (band) | ms/frame |
|---|---:|---:|---:|---:|---:|
| **App, page mode** (pause OCR "all videos" path: comic text detector → PP-OCRv6 small line det → Kellenok) | **0.22%** | **99.0%** | **99.9%** | **98.2%** | 338 |
| App, text mode on the bottom band (the picture-subtitle bitmap path) | 3.40% | 94.3% | 96.8% | 97.4% | 98 |
| PP-OCRv6 small det + Kellenok, whole frame | 0.43% | 97.4% | 99.6% | 95.3% | 70 |
| PP-OCRv6 small det + Kellenok, band only | 0.43% | 96.9% | 99.6% | 94.3% | 56 |
| PP-OCRv5 mobile det + Kellenok, whole frame | 0.72% | 95.9% | 99.6% | 95.2% | 160 |
| PP-OCRv5 mobile det + Kellenok, band only | 0.43% | 96.9% | 99.6% | 95.0% | 192 |
| PP-OCRv5 server det + Kellenok, whole frame | 0.65% | 97.9% | 99.9% | 94.8% | 824 |
| PP-OCRv5 server det + Kellenok, band only | 1.16% | 96.9% | 99.8% | 94.8% | 587 |

(App timings are the Dart pipeline through FFI ORT; Python timings are not
comparable to them one-to-one.)

- The app's current path for burned-in subtitles is the most accurate option
  measured. The PP-OCRv5 detectors add false boxes on costume patterns and
  scenery (lower precision) and are slower.
- Text mode is meant for clean subtitle bitmaps (PGS / VobSub / DVB), which have
  a transparent background. On a band cut from a real frame it picks up
  sponsor logos (五粮液) and the show's watermark and loses some lines. That is
  expected and not a Chinese issue; it is listed only to show the paths differ.

## 3. Manhua: end to end

### Real pages (`manga_real`)

| pipeline | line CER | char recall | char precision | ms/page |
|---|---:|---:|---:|---:|
| **App, page mode** | 9.81% | 96.4% | 91.8% | 572 |
| App, page mode with "ignore furigana" | 9.94% | 96.2% | 91.7% | 578 |
| Kellenok det + Kellenok rec (Python) | 3.08% | 98.2% | 90.5% | 221 |
| Kellenok det + PP-OCRv6 small rec (Python) | 3.13% | 98.2% | 91.7% | 205 |

The two Python rows are favoured by construction: the ground-truth line boxes
came from the same Kellenok detector. Character recall is the fairer
comparison: 96.4% vs 98.2%. Where the app loses text:

- **Missed text (15 lines, 36 characters)** is almost all free-floating
  hand-lettered text outside speech bubbles (緊抓不放, 喘不過氣, 揪心, 哇). The
  comic text detector targets bubbles, and the missed-text sweep needs at
  least 2 confident characters. Japanese pages behave the same way.
- **Furigana handling does not hurt Chinese.** Turning on "ignore furigana"
  changes nothing measurable, and no missed line was a ruby-column drop. The
  two small side notes that were missed (服從, 主人) had no detector box at all.
- **Nested duplicates (0.9% of output characters, 5 of 24 pages)**: when a
  bubble box contains exactly one text box and both are read,
  `_dropContainerBlocks` (needs ≥2 children) and
  `_suppressRecognizedContainedBlocks` (horizontal children only, per
  BUG-2644) both leave the pair, so the line appears twice. This is the
  Japanese pipeline's deliberate conservative choice, not Chinese-specific;
  see follow-ups.

### Public set (`peppercarrot`, horizontal native comics)

60 pages, 5,858 reference characters. Ground truth is page-level (no boxes), so
only character recall and precision apply. Text drawn into the artwork (signs,
posters) is not in the SVG, which lowers every pipeline's precision a little.

| pipeline | char recall | char precision | ms/page |
|---|---:|---:|---:|
| **App, page mode** | 88.7% | **98.0%** | 546 |
| Kellenok det + Kellenok rec (Python) | 91.6% | 92.1% | 332 |
| Kellenok det + PP-OCRv6 small rec (Python) | 92.3% | 91.8% | 303 |
| Kellenok det + PP-OCRv5 server rec (Python) | 92.3% | 93.5% | 744 |
| PP-OCRv5 server det + rec, whole page (Python) | 92.2% | 95.9% | 3143 |

The app is the most precise but reads about 3 points less. The missing
characters are free-floating sound effects (啪, 咔嗒, 哗啦) and posters /
newspapers drawn into panels: the same category as on the real manhua. The
recognizer choice barely moves recall (91.6–92.3%), which again points at
detection rather than the recognizer.

## 4. Licenses

| model | weights license | in the app | notes |
|---|---|---|---|
| Kellenok/PP-OCRv6_manga rec v0.2 | Apache-2.0 | yes (unchanged) | Fine-tuned from PaddlePaddle/PP-OCRv6_small_rec. Training data includes Manga109-s (its terms allow commercial use of trained results with attribution and forbid redistributing the dataset) and AnimeText (CC BY-NC-SA 4.0, already noted in `README.md`). |
| PaddlePaddle/PP-OCRv6_small_det_onnx, _rec_onnx | Apache-2.0 | det yes; rec only for galgame calibration | |
| PaddlePaddle/PP-OCRv5_{mobile,server}_{det,rec}_onnx | Apache-2.0 | no | Official ONNX exports, revisions mobile_rec `ed152b8b`, server_rec `b70df217`, mobile_det `e6f4fa85`, server_det `dcf248c4`. Not adopted. |
| ogkalu/comic-text-and-bubble-detector | Apache-2.0 | yes (unchanged) | |
| Benchmark material | — | no | Pepper&Carrot is CC BY 4.0 (attribution above). Manga pages and episode frames are copyrighted and stay on the tester's machine. |

The Hugging Face Space `Kellenok/PP-OCR_manga` itself is Apache-2.0 and only
demonstrates the same weights (OpenVINO). Nothing is copied from it.

## 5. Decision

1. **Manhua / illustrations:** keep the current pipeline. It already reads
   Chinese; the recognizer is the requested model. No language switch is needed
   in the local engine.
2. **Donghua / video:** keep the current pipeline. It beat every PP-OCRv5
   combination on real burned-in Chinese subtitles. Do not add PP-OCRv5.
3. **No new download, no new preference, no app code change** in this round.

## Follow-ups (not done here)

- **Kellenok fp16** halves the recognizer download (21.2 → 10.6 MB) with
  the same output on 808 of 809 Chinese lines. Switching affects Japanese too, so it
  needs the Japanese 2026-10-15 regression run and a cache-revision bump first.
- **OCR reading order ignores the book's reading direction.** The pipeline
  always orders blocks right to left (`MangaOcrPipeline.rightToLeft`), while the
  reader already knows RTL / LTR / vertical (`MangaQuickDirection`). For native
  manhua and webtoons (left to right) this only changes block order (sentence
  context when mining), not recognition. Wiring the book's direction into the
  page session would fix it for every language.
- **Free-floating text outside bubbles** (hand-lettered dialogue, SFX, posters)
  is the main recall loss on both manhua and Pepper&Carrot. The lever is the
  missed-text sweep, not the recognizer.
- **Single-child nested duplicates** (section 3): consider dropping a vertical
  child when the parent's text contains it verbatim, with BUG-2644's cases as
  regression tests.
- **Floating-ball / screen OCR language** is hard-coded to `ja`
  (`kFloatingBallOcrLanguage`). That only affects system OCR, which takes a
  language; Chinese screen OCR through it needs that to follow the user's
  OCR language.
- **Burned-in subtitle extraction for whole videos** (make a subtitle track
  from hardsubs) would be a separate feature; this benchmark shows the page
  pipeline's accuracy on donghua is already good enough to build it on.
