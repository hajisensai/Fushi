#include "clipboard_image_reader.h"

#include <shellapi.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <cstdio>
#include <cstring>

namespace fushi_clipboard {
namespace {

using Microsoft::WRL::ComPtr;

std::string HResultText(const char* what, HRESULT hr) {
  char buffer[160];
  snprintf(buffer, sizeof(buffer), "%s: HRESULT 0x%08X", what,
           static_cast<unsigned>(hr));
  return std::string(buffer);
}

std::string WideToUtf8(const wchar_t* value, int length) {
  if (length <= 0) return std::string();
  const int size = WideCharToMultiByte(CP_UTF8, 0, value, length, nullptr, 0,
                                       nullptr, nullptr);
  if (size <= 0) return std::string();
  std::string out(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, length, out.data(), size, nullptr,
                      nullptr);
  return out;
}

bool IsPng(const uint8_t* data, size_t size) {
  static const uint8_t kSignature[8] = {0x89, 'P', 'N', 'G', 0x0D,
                                        0x0A, 0x1A, 0x0A};
  return size > sizeof(kSignature) &&
         memcmp(data, kSignature, sizeof(kSignature)) == 0;
}

// 把 HGLOBAL 的内容拷出来（剪贴板关掉后句柄就不归我们了）。
std::vector<uint8_t> CopyGlobal(HANDLE handle) {
  std::vector<uint8_t> out;
  if (handle == nullptr) return out;
  const SIZE_T size = GlobalSize(handle);
  const void* data = GlobalLock(handle);
  if (data == nullptr) return out;
  out.assign(static_cast<const uint8_t*>(data),
             static_cast<const uint8_t*>(data) + size);
  GlobalUnlock(handle);
  return out;
}

// 关剪贴板的守卫：任何返回路径都要 CloseClipboard，否则别的程序再也复制不了。
struct ClipboardCloser {
  ~ClipboardCloser() { CloseClipboard(); }
};

}  // namespace

std::vector<std::string> DropFilesToUtf8Paths(HDROP drop) {
  std::vector<std::string> paths;
  if (drop == nullptr) return paths;
  const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  for (UINT i = 0; i < count; ++i) {
    const UINT length = DragQueryFileW(drop, i, nullptr, 0);
    if (length == 0) continue;
    std::wstring path(static_cast<size_t>(length) + 1, L'\0');
    const UINT copied = DragQueryFileW(drop, i, path.data(), length + 1);
    if (copied == 0) continue;
    std::string utf8 = WideToUtf8(path.c_str(), static_cast<int>(copied));
    if (!utf8.empty()) paths.push_back(std::move(utf8));
  }
  return paths;
}

std::optional<std::string> DibToPng(const uint8_t* dib,
                                    size_t size,
                                    std::vector<uint8_t>* png) {
  if (dib == nullptr || size < sizeof(BITMAPINFOHEADER)) {
    return std::string("DIB is too small");
  }
  BITMAPINFOHEADER header;
  memcpy(&header, dib, sizeof(header));
  if (header.biSize < sizeof(BITMAPINFOHEADER) || header.biSize > size) {
    return std::string("DIB header is invalid");
  }
  // 像素起点 = 信息头 + （BITMAPINFOHEADER 的 BI_BITFIELDS 三个掩码）+ 调色板。
  size_t masks = 0;
  if (header.biSize == sizeof(BITMAPINFOHEADER)) {
    if (header.biCompression == BI_BITFIELDS) masks = 3 * sizeof(DWORD);
    if (header.biCompression == 6 /* BI_ALPHABITFIELDS */) {
      masks = 4 * sizeof(DWORD);
    }
  }
  size_t colors = header.biClrUsed;
  if (colors == 0 && header.biBitCount <= 8) {
    colors = static_cast<size_t>(1) << header.biBitCount;
  }
  const size_t pixel_offset =
      header.biSize + masks + colors * sizeof(RGBQUAD);
  if (pixel_offset >= size) return std::string("DIB has no pixel data");

  // 拼成一个 .bmp 文件交给 WIC 的 BMP 解码器（它认 V4/V5、掩码、自底向上等全部变体）。
  BITMAPFILEHEADER file_header = {};
  file_header.bfType = 0x4D42;  // 'BM'
  file_header.bfSize = static_cast<DWORD>(sizeof(file_header) + size);
  file_header.bfOffBits = static_cast<DWORD>(sizeof(file_header) + pixel_offset);
  std::vector<uint8_t> bmp(sizeof(file_header) + size);
  memcpy(bmp.data(), &file_header, sizeof(file_header));
  memcpy(bmp.data() + sizeof(file_header), dib, size);

  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  if (FAILED(hr)) return HResultText("WIC factory creation failed", hr);

  ComPtr<IWICStream> source;
  hr = factory->CreateStream(&source);
  if (FAILED(hr)) return HResultText("WIC stream creation failed", hr);
  hr = source->InitializeFromMemory(bmp.data(), static_cast<DWORD>(bmp.size()));
  if (FAILED(hr)) return HResultText("WIC stream init failed", hr);

  ComPtr<IWICBitmapDecoder> decoder;
  hr = factory->CreateDecoderFromStream(source.Get(), nullptr,
                                        WICDecodeMetadataCacheOnDemand,
                                        &decoder);
  if (FAILED(hr)) return HResultText("Bitmap decode failed", hr);
  ComPtr<IWICBitmapFrameDecode> frame;
  hr = decoder->GetFrame(0, &frame);
  if (FAILED(hr)) return HResultText("Bitmap frame read failed", hr);

  ComPtr<IWICFormatConverter> converter;
  hr = factory->CreateFormatConverter(&converter);
  if (FAILED(hr)) return HResultText("Converter creation failed", hr);
  hr = converter->Initialize(frame.Get(), GUID_WICPixelFormat24bppBGR,
                             WICBitmapDitherTypeNone, nullptr, 0.0,
                             WICBitmapPaletteTypeCustom);
  if (FAILED(hr)) return HResultText("Pixel conversion failed", hr);
  UINT width = 0;
  UINT height = 0;
  hr = converter->GetSize(&width, &height);
  if (FAILED(hr) || width == 0 || height == 0) {
    return std::string("Bitmap size is invalid");
  }

  ComPtr<IStream> sink;
  hr = CreateStreamOnHGlobal(nullptr, TRUE, &sink);
  if (FAILED(hr)) return HResultText("Output stream creation failed", hr);
  ComPtr<IWICBitmapEncoder> encoder;
  hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
  if (FAILED(hr)) return HResultText("PNG encoder creation failed", hr);
  hr = encoder->Initialize(sink.Get(), WICBitmapEncoderNoCache);
  if (FAILED(hr)) return HResultText("PNG encoder init failed", hr);
  ComPtr<IWICBitmapFrameEncode> out_frame;
  hr = encoder->CreateNewFrame(&out_frame, nullptr);
  if (FAILED(hr)) return HResultText("PNG frame creation failed", hr);
  hr = out_frame->Initialize(nullptr);
  if (FAILED(hr)) return HResultText("PNG frame init failed", hr);
  hr = out_frame->SetSize(width, height);
  if (FAILED(hr)) return HResultText("PNG frame size failed", hr);
  WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
  hr = out_frame->SetPixelFormat(&format);
  if (FAILED(hr)) return HResultText("PNG pixel format failed", hr);
  hr = out_frame->WriteSource(converter.Get(), nullptr);
  if (FAILED(hr)) return HResultText("PNG write failed", hr);
  hr = out_frame->Commit();
  if (FAILED(hr)) return HResultText("PNG frame commit failed", hr);
  hr = encoder->Commit();
  if (FAILED(hr)) return HResultText("PNG commit failed", hr);

  STATSTG stat = {};
  hr = sink->Stat(&stat, STATFLAG_NONAME);
  if (FAILED(hr)) return HResultText("Output stream stat failed", hr);
  HGLOBAL global = nullptr;
  hr = GetHGlobalFromStream(sink.Get(), &global);
  if (FAILED(hr)) return HResultText("Output stream read failed", hr);
  const size_t length = static_cast<size_t>(stat.cbSize.QuadPart);
  const void* data = GlobalLock(global);
  if (data == nullptr) return std::string("Output stream lock failed");
  png->assign(static_cast<const uint8_t*>(data),
              static_cast<const uint8_t*>(data) + length);
  GlobalUnlock(global);
  return std::nullopt;
}

std::optional<std::string> ReadClipboardImage(HWND hwnd, ClipboardImage* out) {
  if (!OpenClipboard(hwnd)) return std::string("OpenClipboard failed");
  ClipboardCloser closer;

  if (IsClipboardFormatAvailable(CF_HDROP)) {
    out->paths =
        DropFilesToUtf8Paths(static_cast<HDROP>(GetClipboardData(CF_HDROP)));
    if (!out->paths.empty()) return std::nullopt;
  }

  const UINT png_format = RegisterClipboardFormatW(L"PNG");
  if (png_format != 0 && IsClipboardFormatAvailable(png_format)) {
    std::vector<uint8_t> bytes = CopyGlobal(GetClipboardData(png_format));
    if (IsPng(bytes.data(), bytes.size())) {
      out->bytes = std::move(bytes);
      return std::nullopt;
    }
  }

  for (const UINT format : {static_cast<UINT>(CF_DIB),
                            static_cast<UINT>(CF_DIBV5)}) {
    if (!IsClipboardFormatAvailable(format)) continue;
    const std::vector<uint8_t> dib = CopyGlobal(GetClipboardData(format));
    if (dib.empty()) continue;
    return DibToPng(dib.data(), dib.size(), &out->bytes);
  }
  return std::nullopt;
}

}  // namespace fushi_clipboard
