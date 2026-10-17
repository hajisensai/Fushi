/*
 * Copyright (c) 2019-2021, 2026 Taner Sener
 *
 * This file is part of FFmpegKitNext.
 *
 * FFmpegKitNext is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * FFmpegKitNext is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General License for more details.
 *
 * You should have received a copy of the GNU Lesser General License
 * along with FFmpegKitNext. If not, see <http://www.gnu.org/licenses/>.
 */

import 'dart:io';

import 'package:ffmpeg_kit_next_flutter_platform_interface/ffmpeg_kit_flutter_platform_interface.dart';
import 'package:flutter/services.dart';

import '../ffmpeg_kit_config.dart';
import '../ffmpeg_session.dart';
import '../ffmpeg_session_complete_callback.dart';
import '../ffprobe_session.dart';
import '../ffprobe_session_complete_callback.dart';
import '../level.dart';
import '../log_callback.dart';
import '../log_redirection_strategy.dart';
import '../media_information_session.dart';
import '../media_information_session_complete_callback.dart';
import '../session.dart';
import '../statistics.dart';
import '../statistics_callback.dart';
import 'ffmpeg_kit_factory.dart';

class FFmpegKitInitializer {
  static FFmpegKitPlatform _platform = FFmpegKitPlatform.instance;
  static const EventChannel _eventChannel =
      const EventChannel('flutter.arthenica.com/ffmpeg_kit_event');

  static FFmpegKitInitializer _instance = new FFmpegKitInitializer();

  static bool _initialized = false;
  static Future<bool>? _initializationFuture;

  static Future<bool> initialize({bool printLoadConfirmation = true}) async {
    if (_initialized) {
      return true;
    }

    final existingInitialization = _initializationFuture;
    if (existingInitialization != null) {
      return existingInitialization;
    }

    final initialization = _instance._initialize().then((_) async {
      // Mark initialized BEFORE syncing the log level. _applyInitialLogLevel
      // calls FFmpegKitConfig.setLogLevel(), which re-enters init(); with the
      // flag already set that re-entrant call short-circuits at the top guard
      // instead of awaiting this future (which would deadlock).
      //
      // Consequence: a concurrent external caller can observe _initialized ==
      // true during the brief log-level sync below and proceed. That is safe -
      // everything functionally required (the event channel listener and
      // enableRedirection) is already done by this point, and the only value
      // still lagging is the Dart-side log-level cache. That cache defaults to
      // Level.avLogTrace (the most permissive level) while native gates logs
      // first, so the pre-sync filter is a strict superset and never drops a
      // log native emitted.
      _initialized = true;
      await _instance._applyInitialLogLevel();
      if (printLoadConfirmation) {
        await _platform.ffmpegKitFlutterInitializerPrintLoadConfirmation();
      }
      return true;
    }).catchError((Object error, StackTrace stackTrace) {
      _initialized = false;
      _initializationFuture = null;
      return Future<bool>.error(error, stackTrace);
    });

    _initializationFuture = initialization;
    return initialization;
  }

  void _onEvent(dynamic event) {
    if (event is Map<dynamic, dynamic>) {
      final Map<String, dynamic> eventMap = event.cast<String, dynamic>();
      final Map<dynamic, dynamic>? logEvent =
          eventMap['FFmpegKitLogCallbackEvent'];
      final Map<dynamic, dynamic>? statisticsEvent =
          eventMap['FFmpegKitStatisticsCallbackEvent'];
      final Map<dynamic, dynamic>? completeEvent =
          eventMap['FFmpegKitCompleteCallbackEvent'];
      final Map<dynamic, dynamic>? sessionDeletedEvent =
          eventMap['FFmpegKitSessionDeletedCallbackEvent'];

      if (logEvent != null) {
        _processLogCallbackEvent(logEvent);
      }

      if (statisticsEvent != null) {
        _processStatisticsCallbackEvent(statisticsEvent);
      }

      if (completeEvent != null) {
        _processCompleteCallbackEvent(completeEvent);
      }

      if (sessionDeletedEvent != null) {
        _processSessionDeletedCallbackEvent(sessionDeletedEvent);
      }
    }
  }

  void _onError(Object error) {
    print('Event error: $error');
  }

  void _processLogCallbackEvent(Map<dynamic, dynamic> event) {
    final log = FFmpegKitFactory.mapToLog(event);
    final int sessionId = event["sessionId"];
    final int level = event["level"];
    final String text = event["message"];
    final int activeLogLevel = FFmpegKitConfig.getLogLevel();
    var globalCallbackDefined = false;
    var sessionCallbackDefined = false;
    LogRedirectionStrategy activeLogRedirectionStrategy =
        FFmpegKitConfig.getLogRedirectionStrategy();

    // avLogStderr logs are always redirected
    if ((activeLogLevel == Level.avLogQuiet && level != Level.avLogStderr) ||
        level > activeLogLevel) {
      // LOG NEITHER PRINTED NOR FORWARDED
      return;
    }

    activeLogRedirectionStrategy =
        FFmpegKitFactory.getLogRedirectionStrategy(sessionId) ??
            activeLogRedirectionStrategy;
    final LogCallback? logCallback = FFmpegKitFactory.getLogCallback(sessionId);

    if (logCallback != null) {
      sessionCallbackDefined = true;

      try {
        // NOTIFY SESSION CALLBACK DEFINED
        logCallback(log);
      } on Exception catch (e, stack) {
        print("Exception thrown inside session log callback. $e");
        print(stack);
      }
    }

    final globalLogCallbackFunction = FFmpegKitFactory.getGlobalLogCallback();
    if (globalLogCallbackFunction != null) {
      globalCallbackDefined = true;

      try {
        // NOTIFY GLOBAL CALLBACK DEFINED
        globalLogCallbackFunction(log);
      } on Exception catch (e, stack) {
        print("Exception thrown inside global log callback. $e");
        print(stack);
      }
    }

    // EXECUTE THE LOG STRATEGY
    switch (activeLogRedirectionStrategy) {
      case LogRedirectionStrategy.neverPrintLogs:
        {
          return;
        }
      case LogRedirectionStrategy.printLogsWhenGlobalCallbackNotDefined:
        {
          if (globalCallbackDefined) {
            return;
          }
        }
        break;
      case LogRedirectionStrategy.printLogsWhenSessionCallbackNotDefined:
        {
          if (sessionCallbackDefined) {
            return;
          }
        }
        break;
      case LogRedirectionStrategy.printLogsWhenNoCallbacksDefined:
        {
          if (globalCallbackDefined || sessionCallbackDefined) {
            return;
          }
        }
        break;
      case LogRedirectionStrategy.alwaysPrintLogs:
        {}
        break;
    }

    // PRINT LOGS
    switch (level) {
      case Level.avLogQuiet:
        {
          // PRINT NO OUTPUT
        }
        break;
      default:
        {
          stdout.write(text);
        }
    }
  }

  void _processStatisticsCallbackEvent(Map<dynamic, dynamic> event) {
    final Statistics statistics = FFmpegKitFactory.mapToStatistics(event);
    final int sessionId = event["sessionId"];

    final StatisticsCallback? statisticsCallback =
        FFmpegKitFactory.getStatisticsCallback(sessionId);
    if (statisticsCallback != null) {
      try {
        // NOTIFY SESSION CALLBACK DEFINED
        statisticsCallback(statistics);
      } on Exception catch (e, stack) {
        print("Exception thrown inside session statistics callback. $e");
        print(stack);
      }
    }

    final globalStatisticsCallbackFunction =
        FFmpegKitFactory.getGlobalStatisticsCallback();
    if (globalStatisticsCallbackFunction != null) {
      try {
        // NOTIFY GLOBAL CALLBACK DEFINED
        globalStatisticsCallbackFunction(statistics);
      } on Exception catch (e, stack) {
        print("Exception thrown inside global statistics callback. $e");
        print(stack);
      }
    }
  }

  void _processCompleteCallbackEvent(Map<dynamic, dynamic> event) {
    final int sessionId = event["sessionId"];

    FFmpegKitConfig.getSession(sessionId).then((Session? session) {
      if (session != null) {
        if (session.isFFmpeg()) {
          final ffmpegSession = session as FFmpegSession;
          final FFmpegSessionCompleteCallback? completeCallback =
              ffmpegSession.getCompleteCallback();

          if (completeCallback != null) {
            try {
              // NOTIFY SESSION CALLBACK DEFINED
              completeCallback(ffmpegSession);
            } on Exception catch (e, stack) {
              print("Exception thrown inside session complete callback. $e");
              print(stack);
            }
          }

          final globalFFmpegSessionCompleteCallback =
              FFmpegKitFactory.getGlobalFFmpegSessionCompleteCallback();
          if (globalFFmpegSessionCompleteCallback != null) {
            try {
              // NOTIFY GLOBAL CALLBACK DEFINED
              globalFFmpegSessionCompleteCallback(ffmpegSession);
            } on Exception catch (e, stack) {
              print("Exception thrown inside global complete callback. $e");
              print(stack);
            }
          }
        } else if (session.isFFprobe()) {
          final ffprobeSession = session as FFprobeSession;
          final FFprobeSessionCompleteCallback? completeCallback =
              ffprobeSession.getCompleteCallback();

          if (completeCallback != null) {
            try {
              // NOTIFY SESSION CALLBACK DEFINED
              completeCallback(ffprobeSession);
            } on Exception catch (e, stack) {
              print("Exception thrown inside session complete callback. $e");
              print(stack);
            }
          }

          final globalFFprobeSessionCompleteCallback =
              FFmpegKitFactory.getGlobalFFprobeSessionCompleteCallback();
          if (globalFFprobeSessionCompleteCallback != null) {
            try {
              // NOTIFY GLOBAL CALLBACK DEFINED
              globalFFprobeSessionCompleteCallback(ffprobeSession);
            } on Exception catch (e, stack) {
              print("Exception thrown inside global complete callback. $e");
              print(stack);
            }
          }
        } else if (session.isMediaInformation()) {
          final mediaInformationSession = session as MediaInformationSession;
          final MediaInformationSessionCompleteCallback? completeCallback =
              mediaInformationSession.getCompleteCallback();

          if (completeCallback != null) {
            try {
              // NOTIFY SESSION CALLBACK DEFINED
              completeCallback(mediaInformationSession);
            } on Exception catch (e, stack) {
              print("Exception thrown inside session complete callback. $e");
              print(stack);
            }
          }

          final globalMediaInformationSessionCompleteCallback = FFmpegKitFactory
              .getGlobalMediaInformationSessionCompleteCallback();
          if (globalMediaInformationSessionCompleteCallback != null) {
            try {
              // NOTIFY GLOBAL CALLBACK DEFINED
              globalMediaInformationSessionCompleteCallback(
                  mediaInformationSession);
            } on Exception catch (e, stack) {
              print("Exception thrown inside global complete callback. $e");
              print(stack);
            }
          }
        }
      }
    });
  }

  void _processSessionDeletedCallbackEvent(Map<dynamic, dynamic> event) {
    FFmpegKitFactory.deleteSession(event["sessionId"]);
  }

  Future<int?> _getLogLevel() async {
    try {
      return _platform.ffmpegKitFlutterInitializerGetLogLevel();
    } on PlatformException catch (e, stack) {
      print("Plugin _getLogLevel error: ${e.message}");
      return Future.error("_getLogLevel failed.", stack);
    }
  }

  Future<void> _initialize() async {
    _eventChannel.receiveBroadcastStream().listen(_onEvent, onError: _onError);
    await _platform.ffmpegKitConfigEnableRedirection();
  }

  // Syncs the Dart-side log level cache with the native log level. Runs after
  // _initialized is set, because FFmpegKitConfig.setLogLevel() re-enters init().
  //
  // Deliberately non-fatal. It runs only after _initialize() has already
  // completed enableRedirection (a method-channel round-trip), so the channel is
  // proven working - a getLogLevel failure here is a rare transient, not a dead
  // channel (that path fails init earlier and is retryable). Propagating it
  // would also be worse than swallowing it: _initialized is already true, so a
  // throw here would flip it true -> false after concurrent callers observed
  // true, leaving init in an inconsistent state. Falling back to the default
  // log level keeps _initialized monotonic and the plugin usable.
  Future<void> _applyInitialLogLevel() async {
    try {
      final logLevel = await _getLogLevel();
      if (logLevel != null) {
        await FFmpegKitConfig.setLogLevel(logLevel);
      }
    } catch (e, stack) {
      print("Applying initial log level failed. $e");
      print(stack);
    }
  }
}
