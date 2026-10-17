#include "system_ocr_windows.h"

#include <windows.h>

#include <roapi.h>
#include <shlwapi.h>
#include <wincodec.h>
#include <winstring.h>

#include <wrl/client.h>
#include <wrl/event.h>
#include <wrl/wrappers/corewrappers.h>

#include <MemoryBuffer.h>
#include <windows.foundation.h>
#include <windows.foundation.collections.h>
#include <windows.globalization.h>
#include <windows.graphics.imaging.h>
#include <windows.media.ocr.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <optional>

#include "screen_ocr_logic.h"

namespace fushi {

namespace {

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Wrappers::HStringReference;

namespace WF = ABI::Windows::Foundation;
namespace WFC = ABI::Windows::Foundation::Collections;
namespace WG = ABI::Windows::Globalization;
namespace WGI = ABI::Windows::Graphics::Imaging;
namespace WMO = ABI::Windows::Media::Ocr;
namespace so = fushi::screen_ocr;

// 单次识别的上限。Windows OCR 对一整块 4K 显示器也在数百毫秒内完成；超过这个时间
// 视为系统组件卡死，报 RECOGNIZE_FAILED 而不是让 Dart 永远等一个回话。
constexpr DWORD kRecognizeTimeoutMs = 30000;

std::string WideToUtf8(const wchar_t* data, size_t length) {
  if (data == nullptr || length == 0) {
    return std::string();
  }
  const int bytes =
      WideCharToMultiByte(CP_UTF8, 0, data, static_cast<int>(length), nullptr,
                          0, nullptr, nullptr);
  if (bytes <= 0) {
    return std::string();
  }
  std::string out(static_cast<size_t>(bytes), '\0');
  WideCharToMultiByte(CP_UTF8, 0, data, static_cast<int>(length), out.data(),
                      bytes, nullptr, nullptr);
  return out;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  const int chars = MultiByteToWideChar(CP_UTF8, 0, value.data(),
                                        static_cast<int>(value.size()),
                                        nullptr, 0);
  if (chars <= 0) {
    return std::wstring();
  }
  std::wstring out(static_cast<size_t>(chars), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      out.data(), chars);
  return out;
}

std::wstring HStringToWide(HSTRING value) {
  UINT32 length = 0;
  const wchar_t* raw = WindowsGetStringRawBuffer(value, &length);
  return raw == nullptr ? std::wstring() : std::wstring(raw, length);
}

SystemOcrResult Failure(const char* code, const std::string& message) {
  SystemOcrResult out;
  out.error_code = code;
  out.error_message = message;
  return out;
}

std::string HresultMessage(const char* what, HRESULT hr) {
  char buffer[96];
  snprintf(buffer, sizeof(buffer), "%s (hr=0x%08lX)", what,
           static_cast<unsigned long>(hr));
  return buffer;
}

HRESULT GetOcrStatics(ComPtr<WMO::IOcrEngineStatics>* statics) {
  return RoGetActivationFactory(
      HStringReference(RuntimeClass_Windows_Media_Ocr_OcrEngine).Get(),
      IID_PPV_ARGS(statics->GetAddressOf()));
}

// 本机识别器语言（顺序 = 系统给的顺序）。
HRESULT ListRecognizerLanguages(WMO::IOcrEngineStatics* statics,
                                std::vector<ComPtr<WG::ILanguage>>* languages,
                                std::vector<std::wstring>* tags) {
  ComPtr<WFC::IVectorView<WG::Language*>> view;
  HRESULT hr = statics->get_AvailableRecognizerLanguages(view.GetAddressOf());
  if (FAILED(hr) || !view) {
    return FAILED(hr) ? hr : E_POINTER;
  }
  unsigned int size = 0;
  hr = view->get_Size(&size);
  if (FAILED(hr)) {
    return hr;
  }
  for (unsigned int i = 0; i < size; ++i) {
    ComPtr<WG::ILanguage> language;
    if (FAILED(view->GetAt(i, language.GetAddressOf())) || !language) {
      continue;
    }
    HSTRING tag = nullptr;
    if (FAILED(language->get_LanguageTag(&tag))) {
      continue;
    }
    tags->push_back(HStringToWide(tag));
    WindowsDeleteString(tag);
    languages->push_back(language);
  }
  return S_OK;
}

struct DecodedImage {
  UINT width = 0;   // 原图
  UINT height = 0;
  UINT ocr_width = 0;  // 送进 OCR 的（可能被缩到 MaxImageDimension 内）
  UINT ocr_height = 0;
  double scale = 1.0;  // ocr / 原图
  std::vector<BYTE> pixels;  // 32bpp 预乘 BGRA，stride = ocr_width * 4
};

bool DecodeImage(const std::vector<uint8_t>& bytes, UINT max_dimension,
                 DecodedImage* out, std::string* error) {
  ComPtr<IWICImagingFactory> wic;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic));
  if (FAILED(hr)) {
    *error = HresultMessage("WIC factory create failed", hr);
    return false;
  }
  ComPtr<IStream> stream;
  stream.Attach(SHCreateMemStream(bytes.data(), static_cast<UINT>(bytes.size())));
  if (!stream) {
    *error = "memory stream alloc failed";
    return false;
  }
  ComPtr<IWICBitmapDecoder> decoder;
  hr = wic->CreateDecoderFromStream(stream.Get(), nullptr,
                                    WICDecodeMetadataCacheOnDemand,
                                    decoder.GetAddressOf());
  ComPtr<IWICBitmapFrameDecode> frame;
  if (SUCCEEDED(hr)) {
    hr = decoder->GetFrame(0, frame.GetAddressOf());
  }
  if (SUCCEEDED(hr)) {
    hr = frame->GetSize(&out->width, &out->height);
  }
  if (FAILED(hr) || out->width == 0 || out->height == 0) {
    *error = HresultMessage("could not decode image bytes", hr);
    return false;
  }
  // 与 Swift 实现同口径：不按 EXIF 旋转，坐标分母就是解码出的像素缓冲。
  out->scale = so::FitScaleForMaxDimension(out->width, out->height,
                                           max_dimension);
  out->ocr_width = std::max<UINT>(
      1, static_cast<UINT>(std::floor(out->width * out->scale)));
  out->ocr_height = std::max<UINT>(
      1, static_cast<UINT>(std::floor(out->height * out->scale)));
  ComPtr<IWICBitmapSource> source = frame;
  if (out->scale < 1.0) {
    ComPtr<IWICBitmapScaler> scaler;
    hr = wic->CreateBitmapScaler(scaler.GetAddressOf());
    if (SUCCEEDED(hr)) {
      hr = scaler->Initialize(frame.Get(), out->ocr_width, out->ocr_height,
                              WICBitmapInterpolationModeFant);
    }
    if (FAILED(hr)) {
      *error = HresultMessage("image downscale failed", hr);
      return false;
    }
    source = scaler;
  }
  ComPtr<IWICFormatConverter> converter;
  hr = wic->CreateFormatConverter(converter.GetAddressOf());
  if (SUCCEEDED(hr)) {
    hr = converter->Initialize(source.Get(), GUID_WICPixelFormat32bppPBGRA,
                               WICBitmapDitherTypeNone, nullptr, 0.0,
                               WICBitmapPaletteTypeCustom);
  }
  const uint64_t stride = static_cast<uint64_t>(out->ocr_width) * 4;
  const uint64_t total = stride * out->ocr_height;
  if (SUCCEEDED(hr) && total > 0x7FFFFFFFull) {
    hr = E_OUTOFMEMORY;
  }
  if (SUCCEEDED(hr)) {
    out->pixels.resize(static_cast<size_t>(total));
    hr = converter->CopyPixels(nullptr, static_cast<UINT>(stride),
                               static_cast<UINT>(total), out->pixels.data());
  }
  if (FAILED(hr)) {
    *error = HresultMessage("pixel conversion failed", hr);
    return false;
  }
  return true;
}

// BGRA 像素 → SoftwareBitmap（Bgra8 / 预乘），按平面描述的 stride 逐行拷。
HRESULT CreateSoftwareBitmap(const DecodedImage& image,
                             ComPtr<WGI::ISoftwareBitmap>* bitmap) {
  ComPtr<WGI::ISoftwareBitmapFactory> factory;
  HRESULT hr = RoGetActivationFactory(
      HStringReference(RuntimeClass_Windows_Graphics_Imaging_SoftwareBitmap)
          .Get(),
      IID_PPV_ARGS(factory.GetAddressOf()));
  if (FAILED(hr)) return hr;
  hr = factory->CreateWithAlpha(WGI::BitmapPixelFormat_Bgra8,
                                static_cast<INT32>(image.ocr_width),
                                static_cast<INT32>(image.ocr_height),
                                WGI::BitmapAlphaMode_Premultiplied,
                                bitmap->GetAddressOf());
  if (FAILED(hr)) return hr;

  ComPtr<WGI::IBitmapBuffer> buffer;
  hr = (*bitmap)->LockBuffer(WGI::BitmapBufferAccessMode_Write,
                             buffer.GetAddressOf());
  if (FAILED(hr)) return hr;
  WGI::BitmapPlaneDescription plane = {};
  hr = buffer->GetPlaneDescription(0, &plane);
  ComPtr<WF::IMemoryBuffer> memory;
  if (SUCCEEDED(hr)) hr = buffer.As(&memory);
  ComPtr<WF::IMemoryBufferReference> reference;
  if (SUCCEEDED(hr)) hr = memory->CreateReference(reference.GetAddressOf());
  ComPtr<::Windows::Foundation::IMemoryBufferByteAccess> access;
  if (SUCCEEDED(hr)) hr = reference.As(&access);
  BYTE* data = nullptr;
  UINT32 capacity = 0;
  if (SUCCEEDED(hr)) hr = access->GetBuffer(&data, &capacity);
  if (SUCCEEDED(hr)) {
    const size_t row = static_cast<size_t>(image.ocr_width) * 4;
    const uint64_t needed =
        static_cast<uint64_t>(plane.StartIndex) +
        static_cast<uint64_t>(plane.Stride) * (image.ocr_height - 1) + row;
    if (data == nullptr || plane.Stride < static_cast<INT32>(row) ||
        needed > capacity) {
      hr = E_UNEXPECTED;
    } else {
      for (UINT y = 0; y < image.ocr_height; ++y) {
        std::memcpy(data + plane.StartIndex +
                        static_cast<size_t>(plane.Stride) * y,
                    image.pixels.data() + row * y, row);
      }
    }
  }
  // 先关引用再关缓冲（IMemoryBufferReference / IBitmapBuffer 都是 IClosable）：
  // 不关的话 SoftwareBitmap 一直处于锁定态，RecognizeAsync 会拒收。
  if (reference) {
    ComPtr<WF::IClosable> closable;
    if (SUCCEEDED(reference.As(&closable))) closable->Close();
  }
  if (buffer) {
    ComPtr<WF::IClosable> closable;
    if (SUCCEEDED(buffer.As(&closable))) closable->Close();
  }
  return hr;
}

// 关句柄的共享持有者：完成回调与等待方各持一份，谁最后走谁关（超时后回调晚到也安全）。
std::shared_ptr<void> MakeSharedEvent() {
  HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (event == nullptr) {
    return nullptr;
  }
  return std::shared_ptr<void>(event, [](void* h) {
    CloseHandle(static_cast<HANDLE>(h));
  });
}

HRESULT RunRecognize(WMO::IOcrEngine* engine, WGI::ISoftwareBitmap* bitmap,
                     ComPtr<WMO::IOcrResult>* result, std::string* error) {
  ComPtr<WF::IAsyncOperation<WMO::OcrResult*>> operation;
  HRESULT hr = engine->RecognizeAsync(bitmap, operation.GetAddressOf());
  if (FAILED(hr)) {
    *error = HresultMessage("RecognizeAsync failed", hr);
    return hr;
  }
  std::shared_ptr<void> done = MakeSharedEvent();
  if (!done) {
    *error = "event create failed";
    return E_OUTOFMEMORY;
  }
  // 完成回调在线程池线程上来：聚合 FtmBase 让委托 agile（同 window_capture.cpp）。
  auto handler = Callback<Microsoft::WRL::Implements<
      Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
      WF::IAsyncOperationCompletedHandler<WMO::OcrResult*>,
      Microsoft::WRL::FtmBase>>(
      [done](WF::IAsyncOperation<WMO::OcrResult*>*,
             WF::AsyncStatus) -> HRESULT {
        SetEvent(static_cast<HANDLE>(done.get()));
        return S_OK;
      });
  if (!handler) {
    *error = "completion handler alloc failed";
    return E_OUTOFMEMORY;
  }
  hr = operation->put_Completed(handler.Get());
  if (FAILED(hr)) {
    *error = HresultMessage("put_Completed failed", hr);
    return hr;
  }
  ComPtr<WF::IAsyncInfo> info;
  operation.As(&info);
  if (WaitForSingleObject(static_cast<HANDLE>(done.get()),
                          kRecognizeTimeoutMs) != WAIT_OBJECT_0) {
    if (info) info->Cancel();
    *error = "recognition timed out";
    return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
  }
  WF::AsyncStatus status = WF::AsyncStatus::Error;
  if (info) info->get_Status(&status);
  if (status != WF::AsyncStatus::Completed) {
    HRESULT code = E_FAIL;
    if (info) info->get_ErrorCode(&code);
    *error = HresultMessage("recognition did not complete", code);
    return FAILED(code) ? code : E_FAIL;
  }
  hr = operation->GetResults(result->GetAddressOf());
  if (FAILED(hr) || !*result) {
    *error = HresultMessage("GetResults failed", hr);
    return FAILED(hr) ? hr : E_POINTER;
  }
  return S_OK;
}

void CollectLines(WMO::IOcrResult* ocr, const DecodedImage& image,
                  std::vector<SystemOcrLine>* out) {
  ComPtr<WFC::IVectorView<WMO::OcrLine*>> lines;
  if (FAILED(ocr->get_Lines(lines.GetAddressOf())) || !lines) {
    return;
  }
  unsigned int line_count = 0;
  lines->get_Size(&line_count);
  const double inverse = image.scale > 0 ? 1.0 / image.scale : 1.0;
  for (unsigned int i = 0; i < line_count; ++i) {
    ComPtr<WMO::IOcrLine> line;
    if (FAILED(lines->GetAt(i, line.GetAddressOf())) || !line) continue;
    ComPtr<WFC::IVectorView<WMO::OcrWord*>> words;
    if (FAILED(line->get_Words(words.GetAddressOf())) || !words) continue;
    unsigned int word_count = 0;
    words->get_Size(&word_count);
    std::vector<std::wstring> texts;
    std::vector<so::RectD> boxes;
    for (unsigned int w = 0; w < word_count; ++w) {
      ComPtr<WMO::IOcrWord> word;
      if (FAILED(words->GetAt(w, word.GetAddressOf())) || !word) continue;
      HSTRING text = nullptr;
      if (SUCCEEDED(word->get_Text(&text))) {
        texts.push_back(HStringToWide(text));
        WindowsDeleteString(text);
      }
      WF::Rect rect = {};
      if (SUCCEEDED(word->get_BoundingRect(&rect))) {
        boxes.push_back(so::RectD{rect.X * inverse, rect.Y * inverse,
                                  (rect.X + rect.Width) * inverse,
                                  (rect.Y + rect.Height) * inverse});
      }
    }
    const std::wstring joined = so::JoinOcrWords(texts);
    const std::optional<so::RectD> bounds = so::UnionOfRects(boxes);
    if (joined.empty() || !bounds) continue;
    SystemOcrLine entry;
    entry.text = WideToUtf8(joined.data(), joined.size());
    entry.left = std::clamp(bounds->left, 0.0, static_cast<double>(image.width));
    entry.top = std::clamp(bounds->top, 0.0, static_cast<double>(image.height));
    entry.right =
        std::clamp(bounds->right, 0.0, static_cast<double>(image.width));
    entry.bottom =
        std::clamp(bounds->bottom, 0.0, static_cast<double>(image.height));
    if (entry.right <= entry.left || entry.bottom <= entry.top) continue;
    out->push_back(std::move(entry));
  }
}

SystemOcrResult RecognizeOnInitializedThread(
    const std::vector<uint8_t>& image_bytes, const std::string& language) {
  ComPtr<WMO::IOcrEngineStatics> statics;
  HRESULT hr = GetOcrStatics(&statics);
  if (FAILED(hr)) {
    return Failure("OCR_UNAVAILABLE",
                   HresultMessage("Windows.Media.Ocr unavailable", hr));
  }
  std::vector<ComPtr<WG::ILanguage>> languages;
  std::vector<std::wstring> tags;
  hr = ListRecognizerLanguages(statics.Get(), &languages, &tags);
  if (FAILED(hr)) {
    return Failure("OCR_UNAVAILABLE",
                   HresultMessage("could not list OCR languages", hr));
  }
  const int picked = so::PickRecognizerLanguage(tags, Utf8ToWide(language));
  if (picked < 0) {
    return Failure("LANGUAGE_UNAVAILABLE",
                   "Windows OCR has no recognizer for \"" + language +
                       "\" (install the language's OCR feature in Settings > "
                       "Time & language > Language)");
  }
  ComPtr<WMO::IOcrEngine> engine;
  hr = statics->TryCreateFromLanguage(languages[picked].Get(),
                                      engine.GetAddressOf());
  if (FAILED(hr) || !engine) {
    return Failure("LANGUAGE_UNAVAILABLE",
                   HresultMessage("OcrEngine.TryCreateFromLanguage failed", hr));
  }
  UINT32 max_dimension = 0;
  statics->get_MaxImageDimension(&max_dimension);

  DecodedImage image;
  std::string error;
  if (!DecodeImage(image_bytes, max_dimension, &image, &error)) {
    return Failure("INVALID_IMAGE", error);
  }
  ComPtr<WGI::ISoftwareBitmap> bitmap;
  hr = CreateSoftwareBitmap(image, &bitmap);
  if (FAILED(hr)) {
    return Failure("RECOGNIZE_FAILED",
                   HresultMessage("SoftwareBitmap create failed", hr));
  }
  ComPtr<WMO::IOcrResult> ocr;
  if (FAILED(RunRecognize(engine.Get(), bitmap.Get(), &ocr, &error))) {
    return Failure("RECOGNIZE_FAILED", error);
  }
  SystemOcrResult out;
  out.width = static_cast<int>(image.width);
  out.height = static_cast<int>(image.height);
  CollectLines(ocr.Get(), image, &out.lines);
  return out;
}

}  // namespace

bool SystemOcrIsAvailable() {
  ComPtr<WMO::IOcrEngineStatics> statics;
  if (FAILED(GetOcrStatics(&statics))) {
    return false;
  }
  std::vector<ComPtr<WG::ILanguage>> languages;
  std::vector<std::wstring> tags;
  if (FAILED(ListRecognizerLanguages(statics.Get(), &languages, &tags))) {
    return false;
  }
  return !tags.empty();
}

SystemOcrResult RecognizeImageText(const std::vector<uint8_t>& image_bytes,
                                   const std::string& language) {
  if (image_bytes.empty()) {
    return Failure("INVALID_IMAGE", "empty image bytes");
  }
  const HRESULT ro = RoInitialize(RO_INIT_MULTITHREADED);
  // RPC_E_CHANGED_MODE = 本线程已按别的套间初始化：照常用，但不由我们反初始化。
  if (FAILED(ro) && ro != RPC_E_CHANGED_MODE) {
    return Failure("OCR_UNAVAILABLE", HresultMessage("RoInitialize failed", ro));
  }
  SystemOcrResult result = RecognizeOnInitializedThread(image_bytes, language);
  if (SUCCEEDED(ro)) {
    RoUninitialize();
  }
  return result;
}

}  // namespace fushi
