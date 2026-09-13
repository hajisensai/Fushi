library hibiki_anki;

// 零 Flutter 子集（引擎 / 无头服务端只 import 这一层）。
export 'fushi_anki_core.dart';

// 以下依赖 Flutter（foundation / services / shared_preferences），只供 app 使用。
export 'src/base_anki_repository.dart';
export 'src/ankidroid/anki_repository.dart';
export 'src/ankiconnect/anki_desktop_foreground.dart';
export 'src/ankiconnect/ankiconnect_installer.dart';
export 'src/ankiconnect/ankiconnect_repository.dart';
