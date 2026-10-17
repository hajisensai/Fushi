#pragma once

// Private to the offscreen floating-ball renderer test target. Its translation
// unit supplies a checked fake for FlutterDesktopGetDpiForMonitor before it
// includes the production .cpp. No Flutter engine API is needed or linked.
// Do not add this directory to the application runner's include path.
