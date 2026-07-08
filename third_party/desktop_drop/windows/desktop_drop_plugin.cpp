#include "include/desktop_drop/desktop_drop_plugin.h"

#include <windows.h>
// TODO-1306: CFSTR_INETURLW ("UniformResourceLocatorW") lives in <shlobj.h>; it
// is the canonical clipboard format browsers use for address-bar / hyperlink
// drags. Needed so URL drags (which carry no CF_HDROP) are not silently dropped.
#include <shlobj.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <sstream>
#include <algorithm>

// TODO-1275 / BUG-361: allow re-registering the host window OLE drop target.
//
// On Windows, opening a reader/video/lookup WebView2 makes the WebView2 runtime
// usurp the host window IDropTarget (default AllowExternalDrop=TRUE registers
// its own so files can be dropped INTO the page). When that controller is torn
// down or has AllowExternalDrop set to FALSE, it revokes the target WITHOUT
// restoring the one desktop_drop registered once at startup, leaving the window
// with NO valid IDropTarget so drag-import shows the forbidden cursor app-wide
// until restart. put_AllowExternalDrop(FALSE) in the WebView2 fork alone is
// insufficient (applied after the controller already hijacked the registration).
// The Hibiki app invokes the reinitialize method (below) after closing media to
// restore the registration regardless of which controller usurped it.

namespace {

    using FlutterMethodChannel = std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>;


    using namespace std::literals::string_literals;

    std::string ws2s(const std::wstring &wstr) {
        if (wstr.empty()) {
            return {};
        }
        size_t pos;
        size_t begin = 0;
        std::string ret;

        int size;
        pos = wstr.find(static_cast<wchar_t>(0), begin);
        while (pos != std::wstring::npos && begin < wstr.length()) {
            std::wstring segment = std::wstring(&wstr[begin], pos - begin);
            size = WideCharToMultiByte(CP_UTF8,
                                       WC_ERR_INVALID_CHARS,
                                       &segment[0],
                                       (int) segment.size(),
                                       nullptr,
                                       0,
                                       nullptr,
                                       nullptr);
            std::string converted = std::string(size, 0);
            WideCharToMultiByte(CP_UTF8,
                                WC_ERR_INVALID_CHARS,
                                &segment[0],
                                (int) segment.size(),
                                &converted[0],
                                (int) converted.size(),
                                nullptr,
                                nullptr);
            ret.append(converted);
            ret.append({0});
            begin = pos + 1;
            pos = wstr.find(static_cast<wchar_t>(0), begin);
        }
        if (begin <= wstr.length()) {
            std::wstring segment = std::wstring(&wstr[begin], wstr.length() - begin);
            size =
                    WideCharToMultiByte(CP_UTF8,
                                        WC_ERR_INVALID_CHARS,
                                        &segment[0],
                                        (int) segment.size(),
                                        nullptr,
                                        0,
                                        nullptr,
                                        nullptr);
            std::string converted = std::string(size, 0);
            WideCharToMultiByte(CP_UTF8,
                                WC_ERR_INVALID_CHARS,
                                &segment[0],
                                (int) segment.size(),
                                &converted[0],
                                (int) converted.size(),
                                nullptr,
                                nullptr);
            ret.append(converted);
        }

        return ret;
    }

    // TODO-1306: browser address-bar / hyperlink drags carry the target URL as
    // CFSTR_INETURLW (a registered "UniformResourceLocatorW" wide-string clipboard
    // format) or plain CF_UNICODETEXT, NOT CF_HDROP -- so the file-only Drop() path
    // yields nothing and the drop is silently lost. Pull the URL out of the data
    // object as a UTF-8 string and hand it to Dart in the SAME performOperation
    // list as file paths; the Dart classifier (classifyDroppedFiles) disambiguates
    // URLs from file paths by scheme. Returns the URL (empty string if none).
    std::string ExtractDroppedUrl(IDataObject *pDataObj) {
        static const UINT cf_inet_url_w = RegisterClipboardFormat(CFSTR_INETURLW);
        const UINT candidates[] = {cf_inet_url_w, CF_UNICODETEXT};
        for (UINT cf : candidates) {
            if (cf == 0) {
                continue;
            }
            FORMATETC fmt = {(CLIPFORMAT) cf, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
            STGMEDIUM med;
            if (pDataObj->QueryGetData(&fmt) != S_OK) {
                continue;
            }
            if (pDataObj->GetData(&fmt, &med) != S_OK) {
                continue;
            }
            std::string url;
            PVOID data = GlobalLock(med.hGlobal);
            if (data != nullptr) {
                std::wstring wide(reinterpret_cast<const wchar_t *>(data));
                url = ws2s(wide);
                GlobalUnlock(med.hGlobal);
            }
            ReleaseStgMedium(&med);
            // CF_UNICODETEXT can be arbitrary text; only accept it if it actually
            // looks like an http(s) URL (CFSTR_INETURLW is already canonical). This
            // keeps plain-text drops from masquerading as importable URLs.
            if (cf == CF_UNICODETEXT && url.rfind("http://", 0) != 0 &&
                url.rfind("https://", 0) != 0) {
                continue;
            }
            if (!url.empty()) {
                return url;
            }
        }
        return {};
    }

    class DesktopDropTarget : public IDropTarget {
    public:

        DesktopDropTarget(FlutterMethodChannel channel, HWND window_handle);

        HRESULT DragEnter(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) override;

        HRESULT DragOver(DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) override;

        HRESULT DragLeave() override;

        HRESULT Drop(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) override;

        HRESULT QueryInterface(const IID &riid, void **ppvObject) override;

        ULONG AddRef() override;

        ULONG Release() override;

        // TODO-1275 / BUG-361: re-assert this window OLE drop target after a
        // WebView2 controller usurped it. Safe to call repeatedly.
        void Reinitialize();

        virtual ~DesktopDropTarget();

    private:
        // TODO-1275: shared registration path used by the constructor and by
        // Reinitialize(); revokes any existing target on the window first (a
        // stale WebView2 registration), then registers this target.
        void RegisterDropTarget();

        FlutterMethodChannel channel_;
        HWND window_handle_;
        LONG ref_count_;
        bool need_revoke_ole_initialize_;
    };

    class DesktopDropPlugin : public flutter::Plugin {

    public:
        static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

        explicit DesktopDropPlugin(DesktopDropTarget *target);

        ~DesktopDropPlugin() override;

    private:

        DesktopDropTarget *target_;

    };

    DesktopDropPlugin::DesktopDropPlugin(DesktopDropTarget *target) : target_(target) {
        target_->AddRef();
    }

    DesktopDropPlugin::~DesktopDropPlugin() {
        target_->Release();
    }


    // static
    void DesktopDropPlugin::RegisterWithRegistrar(
            flutter::PluginRegistrarWindows *registrar) {
        auto channel =
                std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
                        registrar->messenger(), "desktop_drop",
                        &flutter::StandardMethodCodec::GetInstance());

        HWND hwnd = nullptr;
        if (registrar->GetView()) {
            hwnd = registrar->GetView()->GetNativeWindow();
        }

        if (hwnd == nullptr) {
            // no window, no drop.
            return;
        }

        // TODO-1275: the incoming-call handler (which services the reinitialize
        // method) is installed by the target constructor, which owns the moved
        // channel and can capture the target.
        auto drop_target = new DesktopDropTarget(std::move(channel), hwnd);

        auto plugin = std::make_unique<DesktopDropPlugin>(drop_target);

        registrar->AddPlugin(std::move(plugin));
    }


    DesktopDropTarget::DesktopDropTarget(FlutterMethodChannel channel, HWND window_handle) : channel_(
            std::move(channel)), window_handle_(window_handle), ref_count_(0), need_revoke_ole_initialize_(false) {
        RegisterDropTarget();

        // TODO-1275 / BUG-361: service the reinitialize method so the Dart side
        // can restore this window drop target after a WebView2 controller
        // usurped it. Unknown methods stay NotImplemented (unchanged behaviour).
        channel_->SetMethodCallHandler([this](const auto &call, auto result) {
            if (call.method_name() == "reinitialize") {
                Reinitialize();
                result->Success();
            } else {
                result->NotImplemented();
            }
        });
    }

    void DesktopDropTarget::RegisterDropTarget() {
        // Drop any target currently registered on the window (e.g. a WebView2
        // registration that revoked ours) before (re)installing ourselves.
        RevokeDragDrop(window_handle_);

        auto ret = RegisterDragDrop(window_handle_, this);
        if (ret == E_OUTOFMEMORY) {
            OleInitialize(nullptr);
            ret = RegisterDragDrop(window_handle_, this);
            if (ret == 0) {
                need_revoke_ole_initialize_ = true;
            }
        }

        if (ret != 0) {
            std::cout << "RegisterDragDrop failed: " << ret << std::endl;
        }
    }

    void DesktopDropTarget::Reinitialize() {
        RegisterDropTarget();
    }

    HRESULT DesktopDropTarget::DragEnter(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {
        POINT point = {pt.x, pt.y};
        ScreenToClient(window_handle_, &point);
        channel_->InvokeMethod("entered", std::make_unique<flutter::EncodableValue>(
                flutter::EncodableList{
                        flutter::EncodableValue(double(point.x)),
                        flutter::EncodableValue(double(point.y))
                }
        ));
        return 0;
    }

    HRESULT DesktopDropTarget::DragOver(DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {
        POINT point = {pt.x, pt.y};
        ScreenToClient(window_handle_, &point);
        channel_->InvokeMethod("updated", std::make_unique<flutter::EncodableValue>(
                flutter::EncodableList{
                        flutter::EncodableValue(double(point.x)),
                        flutter::EncodableValue(double(point.y))
                }
        ));
        return 0;
    }

    HRESULT DesktopDropTarget::DragLeave() {
        channel_->InvokeMethod("exited", std::make_unique<flutter::EncodableValue>());
        return 0;
    }

    HRESULT DesktopDropTarget::Drop(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {

        flutter::EncodableList list = {};

        // construct a FORMATETC object
        FORMATETC fmtetc = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
        STGMEDIUM stgmed;

        // See if the dataobject contains any TEXT stored as a HGLOBAL
        if (pDataObj->QueryGetData(&fmtetc) == S_OK) {
            // Yippie! the data is there, so go get it!
            if (pDataObj->GetData(&fmtetc, &stgmed) == S_OK) {
                // we asked for the data as a HGLOBAL, so access it appropriately
                PVOID data = GlobalLock(stgmed.hGlobal);
                if (data != nullptr) {
                    auto files = DragQueryFile(reinterpret_cast<HDROP>(data), 0xFFFFFFFF, nullptr, 0);
                    for (unsigned int i = 0; i < files; ++i) {
                        TCHAR filename[MAX_PATH];
                        DragQueryFile(reinterpret_cast<HDROP>(data), i, filename, sizeof(TCHAR) * MAX_PATH);
                        std::wstring wide(filename);
                        std::string path = ws2s(wide);
                        std::cout << "done: " << path << std::endl;
                        list.push_back(flutter::EncodableValue(path));
                    }
                    GlobalUnlock(stgmed.hGlobal);
                }

                // release the data using the COM API
                ReleaseStgMedium(&stgmed);
            }
        }

        // TODO-1306: no files present (empty CF_HDROP) -- this may be a URL drag
        // from a browser (CFSTR_INETURLW / CF_UNICODETEXT). Extract the URL and
        // pass it through the SAME channel so Dart imports it as a stream video.
        if (list.empty()) {
            std::string url = ExtractDroppedUrl(pDataObj);
            if (!url.empty()) {
                list.push_back(flutter::EncodableValue(url));
            }
        }

        channel_->InvokeMethod("performOperation", std::make_unique<flutter::EncodableValue>(list));

        return 0;
    }

    HRESULT DesktopDropTarget::QueryInterface(const IID &iid, void **ppvObject) {
        if (iid == IID_IDropTarget || iid == IID_IUnknown) {
            AddRef();
            *ppvObject = this;
            return S_OK;
        } else {
            *ppvObject = nullptr;
            return E_NOINTERFACE;
        }
    }

    ULONG DesktopDropTarget::AddRef() {
        return InterlockedIncrement(&ref_count_);
    }

    ULONG DesktopDropTarget::Release() {
        LONG count = InterlockedDecrement(&ref_count_);

        if (count == 0) {
            delete this;
            return 0;
        } else {
            return count;
        }
    }

    DesktopDropTarget::~DesktopDropTarget() {
        RevokeDragDrop(window_handle_);
        if (need_revoke_ole_initialize_) {
            OleUninitialize();
        }
    }

}  // namespace

void DesktopDropPluginRegisterWithRegistrar(
        FlutterDesktopPluginRegistrarRef registrar) {
    DesktopDropPlugin::RegisterWithRegistrar(
            flutter::PluginRegistrarManager::GetInstance()
                    ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));

}
