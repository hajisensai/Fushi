/// Selectable local recognizers. The existing manga-ocr model stays the default.
library;

import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi_engine/ocr/manga_ocr_cuda_manifest.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_fingerprint.dart' as model_fp;

enum MangaOcrLocalModel {
  mangaOcr('manga_ocr'),
  mangaOcrCuda('manga_ocr_cuda'),
  baberu('baberu');

  const MangaOcrLocalModel(this.key);
  final String key;

  static MangaOcrLocalModel fromKey(String key) => switch (key) {
    'baberu' => baberu,
    'manga_ocr_cuda' => mangaOcrCuda,
    _ => mangaOcr,
  };

  /// A preference restored from Windows must not select unsupported models on
  /// another device. Settings, imports and inference share this resolution.
  static MangaOcrLocalModel forPlatform(
    String key, {
    String? operatingSystem,
  }) => (operatingSystem ?? Platform.operatingSystem) == 'windows'
      ? fromKey(key)
      : mangaOcr;

  List<MangaOcrModelFile> get manifest => switch (this) {
    baberu => kBaberuOcrModelManifest,
    mangaOcrCuda => kMangaOcrCudaModelManifest,
    mangaOcr => kMangaOcrModelManifest,
  };

  String get cacheSignature => switch (this) {
    baberu => 'local-onnx-baberu-v1-bicubic-$kMangaOcrPipelineRevision',
    mangaOcrCuda => 'local-manga-cuda-v1-beam4-cache-$_cudaRuntimeIdentity-$kMangaOcrPipelineRevision',
    mangaOcr => kLocalMangaOcrEngineSignature,
  };

  /// Sibling directories keep deleting either model from affecting the other.
  Future<Directory> modelsDirectory() async {
    final Directory legacy = await model_fp.defaultMangaOcrModelsDir();
    return this == mangaOcr
        ? legacy
        : Directory(
            p.join(
              legacy.parent.path,
              this == baberu ? 'manga-baberu' : 'manga-cuda',
            ),
          );
  }
}

const String kBaberuOcrRevision = 'd9cc13153e9a1cd8fdfa3b7b1cc329da2020aeae';

// Runtime upgrades can change decoding even when model weights stay identical.
// Hash the pinned lock metadata, without reading multi-GB wheel contents on OCR.
final String _cudaRuntimeIdentity = sha256
    .convert(
      utf8.encode('$kMangaOcrCudaRuntimeVersion\n$kMangaOcrCudaRequirements'),
    )
    .toString()
    .substring(0, 8);

const String _baberuBase =
    'https://huggingface.co/genshiai-daichi/baberu-ocr/resolve/$kBaberuOcrRevision';

/// Apache-2.0 precision tier: FP16 vision weights with float32 IO, int8 decoder
/// prefill/step graphs with a KV cache. Exact sizes checked against HF blobs.
const List<MangaOcrModelFile> kBaberuOcrModelManifest = <MangaOcrModelFile>[
  MangaOcrModelFile(
    fileName: 'detector-v4-s_int8.onnx',
    url:
        'https://huggingface.co/ogkalu/comic-text-and-bubble-detector/'
        'resolve/main/detector-v4-s_int8.onnx',
    expectedBytes: 11120765,
    role: MangaOcrModelRole.detector,
  ),
  MangaOcrModelFile(
    fileName: 'vision_fp16.onnx',
    url: '$_baberuBase/onnx/vision_fp16.onnx',
    expectedBytes: 172917304,
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: 'decoder_prefill_int8.onnx',
    url: '$_baberuBase/onnx/decoder_prefill_int8.onnx',
    expectedBytes: 35133596,
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: 'decoder_step_int8.onnx',
    url: '$_baberuBase/onnx/decoder_step_int8.onnx',
    expectedBytes: 33929034,
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: 'vocab.json',
    url: '$_baberuBase/tokenizer/vocab.json',
    expectedBytes: 130761,
    role: MangaOcrModelRole.recognizer,
  ),
  ...kPpOcrLineModelManifest,
];
