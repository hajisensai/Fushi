// 子进程探针：在一个从没加载过 fushi_p2p 的干净进程里，所有候选都不存在时
// tryLoad / isAvailable 必须给 null / false 而不是抛。
// （同进程里测不了：库一旦被加载，Windows 按裸名 LoadLibrary 会直接命中已加载模块。）
import 'dart:io';

import 'package:fushi_p2p/fushi_p2p.dart';

void main(List<String> args) {
  final String dir = args.single;
  final String sep = Platform.pathSeparator;
  final FushiP2p? lib = FushiP2p.tryLoad(
    libraryPath: '$dir${sep}nope$sep${FushiP2p.defaultLibraryName()}',
    environment: const <String, String>{},
    executablePath: '$dir${sep}bin${sep}fushi_server.exe',
  );
  stdout.writeln('tryLoad=${lib == null ? 'null' : 'loaded'}');
  stdout.writeln('isAvailable=${FushiP2p.isAvailable}');
}
