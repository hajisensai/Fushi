library network_to_file_image;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui show Codec, ImmutableBuffer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// This is a mixture of [FileImage] and [NetworkImage].
/// It will download the image from the url once, save it locally in the file system,
/// and then use it from there in the future.
///
/// In more detail:
///
/// Given a file and url of an image, it first tries to read it from the local file.
/// It decodes the given [File] object as an image, associating it with the given scale.
///
/// However, if the image doesn't yet exist as a local file, it fetches the given URL
/// from the network, associating it with the given scale, and then saves it to the local file.
/// The image will be cached regardless of cache headers from the server.
///
/// Notes:
///
/// - If the provided url is null or empty, [NetworkToFileImage] will default
/// to [FileImage]. It will read the image from the local file, and won't try to
/// download it from the network.
///
/// - If the provided file is null, [NetworkToFileImage] will default
/// to [NetworkImage]. It will download the image from the network, and won't
/// save it locally.
///
/// - If you make debug=true it will print to the console whether the image was
/// read from the file or fetched from the network.
///
/// ## Tests
///
/// You can set mock files. Please see methods:
///
/// * `setMockFile(File file, Uint8List bytes)`
/// * `setMockUrl(String url, Uint8List bytes)`
/// * `clearMocks()`
/// * `clearMockFiles()`
/// * `clearMockUrls()`
///
/// ## See also:
///
///  * flutter_image: https://pub.dartlang.org/packages/flutter_image
///  * image_downloader: https://pub.dartlang.org/packages/image_downloader
///  * cached_network_image: https://pub.dartlang.org/packages/cached_network_image
///  * flutter_advanced_networkimage: https://pub.dartlang.org/packages/flutter_advanced_networkimage
class NetworkToFileImage extends ImageProvider<NetworkToFileImage> {
  //
  const NetworkToFileImage({
    this.file,
    this.url,
    this.scale = 1.0,
    this.headers,
    this.debug = false,
    ProcessError? processError,
  }) : assert(file != null || url != null);

  final File? file;
  final String? url;
  final double scale;
  final Map<String, String>? headers;
  final bool debug;

  static final Map<String, Uint8List?> _mockFiles = {};
  static final Map<String, Uint8List> _mockUrls = {};

  /// Call this if you want your mock urls to be visible for regular http requests.
  static void startHttpOverride() {
    HttpOverrides.global = _MockHttpOverrides();
  }

  static void stopHttpOverride() {
    HttpOverrides.global = null;
  }

  /// You can set mock files. It searches for an exact file.path (string comparison).
  /// To set an empty file, use null: `setMockFile(File("photo.png"), null);`
  static void setMockFile(File file, Uint8List? bytes) {
    _mockFiles[file.path] = bytes;
  }

  /// You can set mock urls. It searches for an exact url (string comparison).
  static void setMockUrl(String url, Uint8List bytes) {
    _mockUrls[url] = bytes;
  }

  static void clearMocks() {
    clearMockFiles();
    clearMockUrls();
  }

  static void clearMockFiles() {
    _mockFiles.clear();
  }

  static void clearMockUrls() {
    _mockUrls.clear();
  }

  @override
  Future<NetworkToFileImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<NetworkToFileImage>(this);
  }

  @override
  ImageStreamCompleter loadImage(NetworkToFileImage key, ImageDecoderCallback decode) {
    // Ownership of this controller is handed off to [_loadAsync]; it is that
    // method's responsibility to close the controller's stream when the image
    // has been loaded or an error is thrown.
    final StreamController<ImageChunkEvent> chunkEvents = StreamController<ImageChunkEvent>();

    return MultiFrameImageStreamCompleter(
        codec: _loadAsync(key, chunkEvents, decode),
        chunkEvents: chunkEvents.stream,
        scale: key.scale,
        informationCollector: () {
          return <DiagnosticsNode>[
            ErrorDescription('Image provider: $this'),
            ErrorDescription('File: ${file?.path}'),
            ErrorDescription('Url: $url'),
          ];
        });
  }

  Future<ui.Codec> _loadAsync(
    NetworkToFileImage key,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
  ) async {
    try {
      assert(key == this);
      // ---

      File? file = key.file;
      String? url = key.url;

      late Uint8List bytes;

      // Reads a MOCK file.
      if (file != null && _mockFiles.containsKey(file.path)) {
        bytes = _mockFiles[file.path] ?? Uint8List(0);
      }

      // Reads from the local file.
      else if (file != null && _ifFileExistsLocally(file)) {
        bytes = await _readFromTheLocalFile(file);
      }

      // Reads from the MOCK network and saves it to the local file.
      // Note: This wouldn't be necessary when startHttpOverride() is called.
      else if (url != null && url.isNotEmpty && _mockUrls.containsKey(url)) {
        bytes = await _downloadFromTheMockNetworkAndSaveToTheLocalFile(file, url);
      }

      // Reads from the network and saves it to the local file.
      else if (url != null && url.isNotEmpty) {
        bytes = await _downloadFromTheNetworkAndSaveToTheLocalFile(chunkEvents, file, url);
      }

      // ---

      final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      return decode(buffer);

      //
    } catch (e) {
      // Depending on where the exception was thrown, the image cache may not
      // have had a chance to track the key in the cache at all.
      // Schedule a microtask to give the cache a chance to add the key.
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      rethrow;
    } finally {
      chunkEvents.close();
    }
  }

  bool _ifFileExistsLocally(File file) => file.existsSync();

  Future<Uint8List> _readFromTheLocalFile(File file) async {
    if (debug) print("Reading image file: ${file.path}");
    final Uint8List bytes = await file.readAsBytes();
    return bytes;
  }

  Future<Uint8List> _downloadFromTheNetworkAndSaveToTheLocalFile(
    StreamController<ImageChunkEvent> chunkEvents,
    File? file,
    String url,
  ) async {
    assert(url.isNotEmpty);
    if (debug) print("Fetching image from: $url");
    // ---

    final Uri resolved = Uri.base.resolve(url);

    final HttpClientRequest request = await _httpClient.getUrl(resolved);

    headers?.forEach((String name, String value) {
      request.headers.add(name, value);
    });
    final HttpClientResponse response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      if (debug) print("Failed fetching image from: $url");
      // The network may be only temporarily unavailable, or the file will be
      // added on the server later. Avoid having future calls to resolve
      // fail to check the network again.
      await response.drain<List<int>?>();
      throw NetworkImageLoadException(statusCode: response.statusCode, uri: resolved);
    }

    final Uint8List bytes = await consolidateHttpClientResponseBytes(
      response,
      onBytesReceived: (int cumulative, int? total) {
        chunkEvents.add(ImageChunkEvent(
          cumulativeBytesLoaded: cumulative,
          expectedTotalBytes: total,
        ));
      },
    );
    if (bytes.lengthInBytes == 0) {
      throw Exception('Image is an empty file: $resolved');
    }

    if (file != null) saveImageToTheLocalFile(file, bytes);

    return bytes;
  }

  // Do not access this field directly; use [_httpClient] instead.
  // We set `autoUncompress` to false to ensure that we can trust the value of
  // the `Content-Length` HTTP header. We automatically uncompress the content
  // in our call to [consolidateHttpClientResponseBytes].
  static final HttpClient _sharedHttpClient = HttpClient()..autoUncompress = false;

  static HttpClient get _httpClient {
    HttpClient client = _sharedHttpClient;
    assert(() {
      if (debugNetworkImageHttpClientProvider != null)
        client = debugNetworkImageHttpClientProvider!();
      return true;
    }());
    return client;
  }

  Future<Uint8List> _downloadFromTheMockNetworkAndSaveToTheLocalFile(File? file, String url) async {
    assert(url.isNotEmpty);
    if (debug) print("Fetching image from: $url");
    // ---

    final Uri resolved = Uri.base.resolve(url);
    Uint8List bytes = _mockUrls[url] ?? Uint8List(0);
    if (bytes.lengthInBytes == 0) {
      throw Exception('NetworkImage is an empty file: $resolved');
    }

    if (file != null) saveImageToTheLocalFile(file, bytes);

    return bytes;
  }

  void saveImageToTheLocalFile(File file, Uint8List bytes) async {
    if (debug) print("Saving image to file: ${file.path}");
    file.writeAsBytes(bytes, flush: true);
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is NetworkToFileImage &&
        other.file?.path == file?.path &&
        other.url == url &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(file?.path, url, scale);

  @override
  String toString() => '$runtimeType("${file?.path}", "$url", scale: $scale)';
}

typedef ProcessError = void Function(dynamic error);

// /////////////////////////////////////////////////////////////////////////////////////////////////

class _MockHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return _MockHttpClient(super.createHttpClient(context));
  }
}

// /////////////////////////////////////////////////////////////////////////////////////////////////

class _MockHttpClient implements HttpClient {
  //
  final HttpClient _realClient;

  _MockHttpClient(this._realClient);

  @override
  bool get autoUncompress => _realClient.autoUncompress;

  @override
  set autoUncompress(bool value) => _realClient.autoUncompress = value;

  @override
  Duration? get connectionTimeout => _realClient.connectionTimeout;

  @override
  set connectionTimeout(Duration? value) => _realClient.connectionTimeout = value;

  @override
  Duration get idleTimeout => _realClient.idleTimeout;

  @override
  set idleTimeout(Duration value) => _realClient.idleTimeout = value;

  @override
  int? get maxConnectionsPerHost => _realClient.maxConnectionsPerHost;

  @override
  set maxConnectionsPerHost(int? value) => _realClient.maxConnectionsPerHost = value;

  @override
  String? get userAgent => _realClient.userAgent;

  @override
  set userAgent(String? value) => _realClient.userAgent = value;

  @override
  void addCredentials(Uri url, String realm, HttpClientCredentials credentials) =>
      _realClient.addCredentials(url, realm, credentials);

  @override
  void addProxyCredentials(
          String host, int port, String realm, HttpClientCredentials credentials) =>
      _realClient.addProxyCredentials(host, port, realm, credentials);

  @override
  set authenticate(Future<bool> Function(Uri url, String scheme, String? realm)? f) =>
      _realClient.authenticate = f;

  @override
  set authenticateProxy(
          Future<bool> Function(String host, int port, String scheme, String? realm)? f) =>
      _realClient.authenticateProxy = f;

  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)? callback) =>
      _realClient.badCertificateCallback = callback;

  @override
  void close({bool force = false}) => _realClient.close(force: force);

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _realClient.delete(host, port, path);

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => _realClient.deleteUrl(url);

  @override
  set findProxy(String Function(Uri url)? f) => _realClient.findProxy = f;

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _realClient.get(host, port, path);

  /// Searches the mock first.
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    String urlStr = url.toString();

    if (urlStr.isNotEmpty && NetworkToFileImage._mockUrls.containsKey(urlStr)) {
      return _MockHttpClientRequest(NetworkToFileImage._mockUrls[urlStr]);
    }

    return _realClient.getUrl(url);
  }

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _realClient.head(host, port, path);

  @override
  Future<HttpClientRequest> headUrl(Uri url) => _realClient.headUrl(url);

  @override
  Future<HttpClientRequest> open(String method, String host, int port, String path) =>
      _realClient.open(method, host, port, path);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (method == "GET") {
      String urlStr = url.toString();

      if (urlStr.isNotEmpty && NetworkToFileImage._mockUrls.containsKey(urlStr)) {
        return _MockHttpClientRequest(NetworkToFileImage._mockUrls[urlStr]);
      }
    }
    return _realClient.openUrl(method, url);
  }

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _realClient.patch(host, port, path);

  @override
  Future<HttpClientRequest> patchUrl(Uri url) => _realClient.patchUrl(url);

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _realClient.post(host, port, path);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => _realClient.postUrl(url);

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _realClient.put(host, port, path);

  @override
  Future<HttpClientRequest> putUrl(Uri url) => _realClient.putUrl(url);
  
  @override
  set connectionFactory(Future<ConnectionTask<Socket>> Function(Uri url, String? proxyHost, int? proxyPort)? f)=> _realClient.connectionFactory=f;
  
  @override
  set keyLog(Function(String line)? callback)=> _realClient.keyLog=callback;
}

// /////////////////////////////////////////////////////////////////////////////////////////////////

class _MockHttpClientRequest extends HttpClientRequest {
  //
  final Uint8List? bytes;

  _MockHttpClientRequest(this.bytes);

  @override
  late Encoding encoding;

  @override
  final HttpHeaders headers = _MockHttpHeaders();

  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    return Future<void>.value();
  }

  @override
  Future<HttpClientResponse> close() => done;

  @override
  HttpConnectionInfo? get connectionInfo => null;

  @override
  List<Cookie> get cookies => [];

  @override
  Future<HttpClientResponse> get done =>
      SynchronousFuture<HttpClientResponse>(_MockHttpClientResponse(bytes!));

  @override
  Future<void> flush() {
    return Future<void>.value();
  }

  @override
  String get method => "";

  @override
  Uri get uri => Uri();

  @override
  void write(Object? obj) {}

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {}

  @override
  void writeCharCode(int charCode) {}

  @override
  void writeln([Object? obj = '']) {}

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
}

// /////////////////////////////////////////////////////////////////////////////////////////////////

class _MockHttpClientResponse implements HttpClientResponse {
  //
  final Stream<Uint8List> _delegate;
  final int _contentLength;

  _MockHttpClientResponse(Uint8List bytes)
      : _delegate = Stream<Uint8List>.value(bytes),
        _contentLength = bytes.length;

  @override
  final HttpHeaders headers = _MockHttpHeaders();

  @override
  X509Certificate? get certificate => null;

  @override
  HttpConnectionInfo? get connectionInfo => null;

  @override
  int get contentLength => _contentLength;

  @override
  HttpClientResponseCompressionState get compressionState {
    return HttpClientResponseCompressionState.decompressed;
  }

  @override
  List<Cookie> get cookies => [];

  @override
  Future<Socket> detachSocket() {
    return Future<Socket>.error(UnsupportedError('Mocked response'));
  }

  @override
  bool get isRedirect => false;

  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    return _delegate.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  bool get persistentConnection => false;

  @override
  String get reasonPhrase => "";

  @override
  Future<HttpClientResponse> redirect([String? method, Uri? url, bool? followLoops]) {
    return Future<HttpClientResponse>.error(UnsupportedError('Mocked response'));
  }

  @override
  List<RedirectInfo> get redirects => <RedirectInfo>[];

  @override
  int get statusCode => 200;

  @override
  Future<bool> any(bool Function(Uint8List element) test) {
    return _delegate.any(test);
  }

  @override
  Stream<Uint8List> asBroadcastStream({
    void Function(StreamSubscription<Uint8List> subscription)? onListen,
    void Function(StreamSubscription<Uint8List> subscription)? onCancel,
  }) {
    return _delegate.asBroadcastStream(onListen: onListen, onCancel: onCancel);
  }

  @override
  Stream<E> asyncExpand<E>(Stream<E>? Function(Uint8List event) convert) {
    return _delegate.asyncExpand<E>(convert);
  }

  @override
  Stream<E> asyncMap<E>(FutureOr<E> Function(Uint8List event) convert) {
    return _delegate.asyncMap<E>(convert);
  }

  @override
  Stream<R> cast<R>() {
    return _delegate.cast<R>();
  }

  @override
  Future<bool> contains(Object? needle) {
    return _delegate.contains(needle);
  }

  @override
  Stream<Uint8List> distinct([bool Function(Uint8List previous, Uint8List next)? equals]) {
    return _delegate.distinct(equals);
  }

  @override
  Future<E> drain<E>([E? futureValue]) {
    return _delegate.drain<E>(futureValue);
  }

  @override
  Future<Uint8List> elementAt(int index) {
    return _delegate.elementAt(index);
  }

  @override
  Future<bool> every(bool Function(Uint8List element) test) {
    return _delegate.every(test);
  }

  @override
  Stream<S> expand<S>(Iterable<S> Function(Uint8List element) convert) {
    return _delegate.expand(convert);
  }

  @override
  Future<Uint8List> get first => _delegate.first;

  @override
  Future<Uint8List> firstWhere(
    bool Function(Uint8List element) test, {
    List<int> Function()? orElse,
  }) {
    return _delegate.firstWhere(test, orElse: () {
      return Uint8List.fromList(orElse!());
    });
  }

  @override
  Future<S> fold<S>(S initialValue, S Function(S previous, Uint8List element) combine) {
    return _delegate.fold<S>(initialValue, combine);
  }

  @override
  Future<dynamic> forEach(void Function(Uint8List element) action) {
    return _delegate.forEach(action);
  }

  @override
  Stream<Uint8List> handleError(
    Function onError, {
    bool Function(dynamic error)? test,
  }) {
    return _delegate.handleError(onError, test: test);
  }

  @override
  bool get isBroadcast => _delegate.isBroadcast;

  @override
  Future<bool> get isEmpty => _delegate.isEmpty;

  @override
  Future<String> join([String separator = '']) {
    return _delegate.join(separator);
  }

  @override
  Future<Uint8List> get last => _delegate.last;

  @override
  Future<Uint8List> lastWhere(
    bool Function(Uint8List element) test, {
    List<int> Function()? orElse,
  }) {
    return _delegate.lastWhere(test, orElse: () {
      return Uint8List.fromList(orElse!());
    });
  }

  @override
  Future<int> get length => _delegate.length;

  @override
  Stream<S> map<S>(S Function(Uint8List event) convert) {
    return _delegate.map<S>(convert);
  }

  @override
  Future<dynamic> pipe(StreamConsumer<List<int>> streamConsumer) {
    return _delegate.cast<List<int>>().pipe(streamConsumer);
  }

  @override
  Future<Uint8List> reduce(List<int> Function(Uint8List previous, Uint8List element) combine) {
    return _delegate.reduce((Uint8List previous, Uint8List element) {
      return Uint8List.fromList(combine(previous, element));
    });
  }

  @override
  Future<Uint8List> get single => _delegate.single;

  @override
  Future<Uint8List> singleWhere(
    bool Function(Uint8List element) test, {
    List<int> Function()? orElse,
  }) {
    return _delegate.singleWhere(test, orElse: () {
      return Uint8List.fromList(orElse!());
    });
  }

  @override
  Stream<Uint8List> skip(int count) {
    return _delegate.skip(count);
  }

  @override
  Stream<Uint8List> skipWhile(bool Function(Uint8List element) test) {
    return _delegate.skipWhile(test);
  }

  @override
  Stream<Uint8List> take(int count) {
    return _delegate.take(count);
  }

  @override
  Stream<Uint8List> takeWhile(bool Function(Uint8List element) test) {
    return _delegate.takeWhile(test);
  }

  @override
  Stream<Uint8List> timeout(
    Duration timeLimit, {
    void Function(EventSink<Uint8List> sink)? onTimeout,
  }) {
    return _delegate.timeout(timeLimit, onTimeout: onTimeout);
  }

  @override
  Future<List<Uint8List>> toList() {
    return _delegate.toList();
  }

  @override
  Future<Set<Uint8List>> toSet() {
    return _delegate.toSet();
  }

  @override
  Stream<S> transform<S>(StreamTransformer<List<int>, S> streamTransformer) {
    return _delegate.cast<List<int>>().transform<S>(streamTransformer);
  }

  @override
  Stream<Uint8List> where(bool Function(Uint8List event) test) {
    return _delegate.where(test);
  }
}

// /////////////////////////////////////////////////////////////////////////////////////////////////

class _MockHttpHeaders extends HttpHeaders {
  //
  @override
  List<String> operator [](String name) => <String>[];

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  void clear() {}

  @override
  void forEach(void Function(String name, List<String> values) f) {}

  @override
  void noFolding(String name) {}

  @override
  void remove(String name, Object value) {}

  @override
  void removeAll(String name) {}

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  String? value(String name) => null;
}

// /////////////////////////////////////////////////////////////////////////////////////////////////
