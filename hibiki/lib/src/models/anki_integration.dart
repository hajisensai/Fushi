import 'dart:io';

import 'package:external_app_launcher/external_app_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';

class AnkiIntegration {
  static const MethodChannel methodChannel = HibikiChannels.anki;

  Future<void> requestPermissions() async {
    if (!Platform.isAndroid) return;
    await methodChannel.invokeMethod('requestAnkidroidPermissions');
  }

  Future<void> showApiMessage(BuildContext? ctx) async {
    await requestPermissions();
    if (ctx == null || !ctx.mounted) return;
    await showAppDialog(
      context: ctx,
      builder: (context) => adaptiveAlertDialog(
        context: context,
        title: Text(t.error_ankidroid_api),
        content: Text(t.error_ankidroid_api_content),
        actions: [
          adaptiveDialogAction(
            context: context,
            child: Text(t.dialog_launch_ankidroid),
            onPressed: () async {
              final navigator = Navigator.of(context);
              if (Platform.isAndroid) {
                await LaunchApp.openApp(
                  androidPackageName: 'com.ichi2.anki',
                  openStore: true,
                );
              }
              navigator.pop();
            },
          ),
          adaptiveDialogAction(
            context: context,
            child: Text(t.dialog_close),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Future<void> addDefaultModelIfMissing(BuildContext? ctx) async {
    if (!Platform.isAndroid) return;
    List<String> models = await getModelList(ctx);
    if (!models.contains('Lapis')) {
      methodChannel.invokeMethod('addDefaultModel');
      if (ctx == null || !ctx.mounted) return;
      await showAppDialog(
        context: ctx,
        builder: (context) => adaptiveAlertDialog(
          context: context,
          title: Text(t.info_standard_model),
          content: Text(t.info_standard_model_content),
          actions: [
            adaptiveDialogAction(
              context: context,
              child: Text(t.dialog_close),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
      );
    }
  }

  Future<List<String>> getDecks(BuildContext? ctx) async {
    try {
      Map<dynamic, dynamic> result =
          await methodChannel.invokeMethod('getDecks');
      List<String> decks = result.values.toList().cast<String>();
      decks.sort((a, b) => a.compareTo(b));
      return decks;
    } catch (e) {
      if (ctx != null && ctx.mounted) await showApiMessage(ctx);
      rethrow;
    }
  }

  Future<List<String>> getModelList(BuildContext? ctx) async {
    try {
      Map<dynamic, dynamic> result =
          await methodChannel.invokeMethod('getModelList');
      List<String> models = result.values.toList().cast<String>();
      models.sort((a, b) => a.compareTo(b));
      return models;
    } catch (e) {
      if (ctx != null && ctx.mounted) await showApiMessage(ctx);
      rethrow;
    }
  }

  Future<List<String>> getFieldList(String model, BuildContext? ctx) async {
    try {
      return List<String>.from(
        await methodChannel.invokeMethod(
          'getFieldList',
          <String, dynamic>{'model': model},
        ),
      );
    } catch (e) {
      if (ctx != null && ctx.mounted) showApiMessage(ctx);
      rethrow;
    }
  }
}
