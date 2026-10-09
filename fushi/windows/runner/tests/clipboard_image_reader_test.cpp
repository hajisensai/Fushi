// 反馈「粘贴截图」的 Windows 剪贴板解码：不碰真剪贴板（每次构建都跑，不能清掉构建
// 机的剪贴板），只测两段纯转换——截图工具的 32bpp DIB（alpha 全 0）→ 不透明 PNG、
// BI_BITFIELDS 掩码偏移；资源管理器复制的 CF_HDROP → UTF-8 路径（含中文）。
//
// release 也要真断言（assert_liveness_guard_test 按文件强制）：本文件用自己的
// Check 计数，与其余 runner 测试同一写法，免得日后加 assert 时被 NDEBUG 编空。
#undef NDEBUG

#include <windows.h>
#include <shlobj.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "../clipboard_image_reader.h"

using Microsoft::WRL::ComPtr;

namespace {

int failures = 0;

void Check(bool ok, const char* what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what);
    ++failures;
  }
}

// 4x2 的 32bpp 自底向上 DIB，像素全是纯红 (B=0,G=0,R=255)，alpha 字节全 0——
// QQ / 微信截图常见的写法。[bitfields] 时用 BI_BITFIELDS + 三个掩码。
std::vector<uint8_t> MakeDib(bool bitfields) {
  const int width = 4;
  const int height = 2;
  BITMAPINFOHEADER header = {};
  header.biSize = sizeof(header);
  header.biWidth = width;
  header.biHeight = height;
  header.biPlanes = 1;
  header.biBitCount = 32;
  header.biCompression = bitfields ? BI_BITFIELDS : BI_RGB;
  header.biSizeImage = width * height * 4;
  std::vector<uint8_t> dib(sizeof(header));
  memcpy(dib.data(), &header, sizeof(header));
  if (bitfields) {
    const DWORD masks[3] = {0x00FF0000, 0x0000FF00, 0x000000FF};
    const uint8_t* m = reinterpret_cast<const uint8_t*>(masks);
    dib.insert(dib.end(), m, m + sizeof(masks));
  }
  for (int i = 0; i < width * height; ++i) {
    const uint8_t px[4] = {0, 0, 255, 0};
    dib.insert(dib.end(), px, px + 4);
  }
  return dib;
}

// 解 PNG 成 32bppBGRA，返回左上像素 (B,G,R,A)。
bool FirstPixel(const std::vector<uint8_t>& png, uint8_t bgra[4], UINT* w,
                UINT* h) {
  ComPtr<IWICImagingFactory> factory;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)))) {
    return false;
  }
  ComPtr<IWICStream> stream;
  if (FAILED(factory->CreateStream(&stream))) return false;
  if (FAILED(stream->InitializeFromMemory(
          const_cast<BYTE*>(png.data()), static_cast<DWORD>(png.size())))) {
    return false;
  }
  ComPtr<IWICBitmapDecoder> decoder;
  if (FAILED(factory->CreateDecoderFromStream(
          stream.Get(), &GUID_ContainerFormatPng,
          WICDecodeMetadataCacheOnDemand, &decoder))) {
    return false;
  }
  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(decoder->GetFrame(0, &frame))) return false;
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateFormatConverter(&converter))) return false;
  if (FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
                                   WICBitmapDitherTypeNone, nullptr, 0.0,
                                   WICBitmapPaletteTypeCustom))) {
    return false;
  }
  if (FAILED(converter->GetSize(w, h))) return false;
  WICRect rect = {0, 0, 1, 1};
  return SUCCEEDED(converter->CopyPixels(&rect, 4, 4, bgra));
}

void TestDib(bool bitfields) {
  const std::vector<uint8_t> dib = MakeDib(bitfields);
  std::vector<uint8_t> png;
  const auto error =
      fushi_clipboard::DibToPng(dib.data(), dib.size(), &png);
  Check(!error.has_value(), "DibToPng succeeds");
  if (error.has_value()) {
    std::fprintf(stderr, "  %s\n", error->c_str());
    return;
  }
  Check(png.size() > 8 && png[0] == 0x89 && png[1] == 'P', "output is PNG");
  uint8_t bgra[4] = {};
  UINT w = 0;
  UINT h = 0;
  Check(FirstPixel(png, bgra, &w, &h), "PNG decodes");
  Check(w == 4 && h == 2, "size preserved");
  Check(bgra[2] == 255 && bgra[1] == 0 && bgra[0] == 0, "pixel is red");
  Check(bgra[3] == 255, "alpha-0 DIB comes out opaque");
}

void TestDropFiles() {
  const wchar_t files[] = L"C:\\shots\\\x622A\x56FE.png\0C:\\notes.txt\0";
  const size_t files_bytes = sizeof(files) + sizeof(wchar_t);  // 末尾双 0
  HGLOBAL global = GlobalAlloc(GHND, sizeof(DROPFILES) + files_bytes);
  auto* drop = static_cast<DROPFILES*>(GlobalLock(global));
  drop->pFiles = sizeof(DROPFILES);
  drop->fWide = TRUE;
  memcpy(reinterpret_cast<uint8_t*>(drop) + sizeof(DROPFILES), files,
         sizeof(files));
  GlobalUnlock(global);
  const std::vector<std::string> paths =
      fushi_clipboard::DropFilesToUtf8Paths(static_cast<HDROP>(global));
  GlobalFree(global);
  Check(paths.size() == 2, "two dropped paths");
  if (paths.size() == 2) {
    Check(paths[0] == "C:\\shots\\\xE6\x88\xAA\xE5\x9B\xBE.png",
          "CJK path is UTF-8");
    Check(paths[1] == "C:\\notes.txt", "second path");
  }
}

}  // namespace

int main() {
  if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) {
    std::fprintf(stderr, "FAIL: CoInitializeEx\n");
    return 1;
  }
  TestDib(false);
  TestDib(true);
  TestDropFiles();
  {
    std::vector<uint8_t> png;
    const uint8_t junk[4] = {1, 2, 3, 4};
    Check(fushi_clipboard::DibToPng(junk, sizeof(junk), &png).has_value(),
          "truncated DIB is an error");
  }
  CoUninitialize();
  if (failures != 0) return 1;
  std::printf("clipboard_image_reader_test: OK\n");
  return 0;
}
