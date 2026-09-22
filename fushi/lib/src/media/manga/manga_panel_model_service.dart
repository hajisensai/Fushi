import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi/src/media/manga/manga_panel_detector.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/manga/panel_detection.dart';
import 'package:fushi_engine/media/manga/panel_model_manifest.dart';
import 'package:fushi_engine/ocr/ocr_host_bindings.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/utils/net/app_http.dart';

class MangaPanelModelStatus {
  const MangaPanelModelStatus({
    required this.available,
    required this.bytes,
    this.error,
  });

  final bool available;
  final int bytes;
  final String? error;
}

const String kMangaPanelModelDirectory = 'manga_panel_detector';

Future<Directory> mangaPanelModelDirectory() async {
  final Directory root = await enginePaths.supportRootDirectory();
  return Directory(
    '${root.path}${Platform.pathSeparator}$kMangaPanelModelDirectory',
  );
}

Future<File> mangaPanelModelFile() async {
  final Directory dir = await mangaPanelModelDirectory();
  return File(
    '${dir.path}${Platform.pathSeparator}${kMangaPanelModelManifest.fileName}',
  );
}

Future<MangaPanelModelStatus> mangaPanelModelStatus() async {
  if (!kMangaPanelModelManifest.isVerified) {
    return const MangaPanelModelStatus(
      available: false,
      bytes: 0,
      error: 'panel model release asset is not verified',
    );
  }
  final File file = await mangaPanelModelFile();
  if (!await file.exists()) {
    return const MangaPanelModelStatus(available: false, bytes: 0);
  }
  final int bytes = await file.length();
  if (bytes != kMangaPanelModelManifest.bytes) {
    return MangaPanelModelStatus(
      available: false,
      bytes: bytes,
      error: 'model size mismatch',
    );
  }
  final String digest = await _sha256(file);
  return MangaPanelModelStatus(
    available: digest == kMangaPanelModelManifest.sha256,
    bytes: bytes,
    error: digest == kMangaPanelModelManifest.sha256
        ? null
        : 'model checksum mismatch',
  );
}

Stream<int> downloadMangaPanelModel({
  HttpClient Function()? clientFactory,
}) async* {
  if (!kMangaPanelModelManifest.isVerified) {
    throw StateError('panel model manifest has no verified release digest');
  }
  final Directory dir = await mangaPanelModelDirectory();
  await dir.create(recursive: true);
  final File target = File(
    '${dir.path}${Platform.pathSeparator}${kMangaPanelModelManifest.fileName}',
  );
  final File part = File('${target.path}.part');
  final HttpClient client = (clientFactory ?? createAppHttpClient)();
  try {
    final HttpClientRequest request = await client.getUrl(
      Uri.parse(kMangaPanelModelManifest.assetUrl),
    );
    request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
    final HttpClientResponse response = await request.close().timeout(
      const Duration(seconds: 30),
    );
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('model download HTTP ${response.statusCode}');
    }
    IOSink? sink = part.openWrite();
    try {
      int received = 0;
      await for (final List<int> chunk in response) {
        received += chunk.length;
        if (received > kMangaPanelModelManifest.bytes!) {
          throw StateError('model exceeds manifest size');
        }
        sink.add(chunk);
        yield received;
      }
      await sink.close();
      sink = null;
      if (received != kMangaPanelModelManifest.bytes ||
          await _sha256(part) != kMangaPanelModelManifest.sha256) {
        throw StateError('downloaded panel model failed manifest validation');
      }
    } finally {
      await sink?.close();
    }
    // A retry may be replacing a corrupt file. Windows rename does not replace
    // an existing target, so remove only this verified-path target immediately
    // before the atomic move.
    if (await target.exists()) await target.delete();
    await part.rename(target.path);
  } finally {
    client.close(force: true);
  }
}

Future<PanelDetector?> createMangaPanelDetector() async {
  final MangaPanelModelStatus status = await mangaPanelModelStatus();
  if (!status.available) return null;
  final OcrSessionFactory Function()? builder = ocrSessionFactoryBuilder;
  if (builder == null) return null;
  final OcrSessionFactory factory = builder();
  final File model = await mangaPanelModelFile();
  final OcrSession session = await factory.createSession(
    model.path,
    providers: <OcrExecutionProvider>[OcrExecutionProvider.cpu],
  );
  return OnnxPanelDetector(
    session,
    modelRevision: kMangaPanelModelManifest.revision,
  );
}

Future<String> _sha256(File file) async {
  final Digest digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

void installMangaPanelDetectorFactory() {
  mangaPanelDetectorFactory = createMangaPanelDetector;
}
