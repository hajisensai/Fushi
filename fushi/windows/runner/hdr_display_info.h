#ifndef RUNNER_HDR_DISPLAY_INFO_H_
#define RUNNER_HDR_DISPLAY_INFO_H_

#include <windows.h>

namespace fushi {

// Current output colour space of the monitor the main window sits on
// (IDXGIOutput6::GetDesc1). colour_space == 12 is
// DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020 (Windows HDR on).
//
// sdr_white_nits is the "SDR content brightness" slider of that monitor
// (DISPLAYCONFIG_SDR_WHITE_LEVEL): the luminance DWM gives sRGB 1.0 of every
// SDR window, and the white the compositor HDR output gives the Flutter UI.
// 0 = unknown (query failed / pre-1709 Windows).
struct HdrDisplayInfo {
  bool valid = false;
  int color_space = -1;
  float max_luminance = 0.0f;
  unsigned bits_per_color = 0;
  float sdr_white_nits = 0.0f;
};
HdrDisplayInfo QueryHdrDisplayInfo(HWND main);

// SDR white level (nits) of the display whose GDI source name is
// |gdi_device_name| (\.\DISPLAYn, what DXGI_OUTPUT_DESC1::DeviceName reports).
// DISPLAYCONFIG_SDR_WHITE_LEVEL is in units of 80 nits / 1000. Returns 0 when
// no active path matches. Shared with hdr_desktop_capture.cpp (screen OCR).
float QuerySdrWhiteNits(const wchar_t* gdi_device_name);

}  // namespace fushi

#endif  // RUNNER_HDR_DISPLAY_INFO_H_
