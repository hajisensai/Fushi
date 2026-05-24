import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/reader/reader_settings.dart';

class SettingsContext {
  const SettingsContext({
    required this.context,
    required this.appModel,
    required this.ref,
    required this.readerSource,
    required this.refresh,
  });

  final BuildContext context;
  final AppModel appModel;
  final WidgetRef ref;
  final ReaderHibikiSource readerSource;
  final VoidCallback refresh;

  ReaderSettings? get readerSettings => ReaderHibikiSource.readerSettings;
}
