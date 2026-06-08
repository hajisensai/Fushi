import 'dart:io';

import 'package:hibiki/src/sync/hibiki_library_host_service.dart';

abstract class RemoteBookClient {
  Future<List<RemoteBookInfo>> listRemoteBooks();

  Future<void> getRemoteBook(
    String title,
    File destination, {
    void Function(double progress)? onProgress,
  });
}
