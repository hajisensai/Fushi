#include "screen_capture.h"

#include <glib/gstdio.h>

#include <algorithm>
#include <cmath>
#include <string>
#include <utility>

namespace fushi {
namespace screen_capture {

namespace {

constexpr char kPortalBus[] = "org.freedesktop.portal.Desktop";
constexpr char kPortalPath[] = "/org/freedesktop/portal/desktop";
// The first request waits for the user to answer the desktop's permission
// dialog; later ones answer in well under a second.
constexpr guint kPortalTimeoutSeconds = 60;

std::shared_ptr<GdkPixbuf> Adopt(GdkPixbuf* pixbuf) {
  return std::shared_ptr<GdkPixbuf>(pixbuf, [](GdkPixbuf* p) {
    if (p != nullptr) g_object_unref(p);
  });
}

int Scale(GdkMonitor* monitor) {
  return std::max(1, gdk_monitor_get_scale_factor(monitor));
}

GdkRectangle PhysicalScreen(GdkMonitor* monitor) {
  GdkRectangle geometry;
  gdk_monitor_get_geometry(monitor, &geometry);
  const int scale = Scale(monitor);
  return GdkRectangle{geometry.x * scale, geometry.y * scale,
                      geometry.width * scale, geometry.height * scale};
}

// Bounding box of every monitor (GDK logical coordinates): the area the
// portal's whole-desktop screenshot covers.
GdkRectangle DesktopBounds(GdkDisplay* display) {
  const int count = gdk_display_get_n_monitors(display);
  GdkRectangle bounds{0, 0, 0, 0};
  for (int i = 0; i < count; ++i) {
    GdkRectangle geometry;
    gdk_monitor_get_geometry(gdk_display_get_monitor(display, i), &geometry);
    if (i == 0) {
      bounds = geometry;
    } else {
      gdk_rectangle_union(&bounds, &geometry, &bounds);
    }
  }
  return bounds;
}

// Cuts |monitor| out of a whole-desktop image and brings it to the monitor's
// physical size (image px == screen px is the channel contract).
GdkPixbuf* CropToMonitor(GdkPixbuf* desktop, GdkMonitor* monitor) {
  const GdkRectangle bounds = DesktopBounds(gdk_monitor_get_display(monitor));
  if (bounds.width <= 0 || bounds.height <= 0) return nullptr;
  GdkRectangle geometry;
  gdk_monitor_get_geometry(monitor, &geometry);
  const int image_w = gdk_pixbuf_get_width(desktop);
  const int image_h = gdk_pixbuf_get_height(desktop);
  const double rx = static_cast<double>(image_w) / bounds.width;
  const double ry = static_cast<double>(image_h) / bounds.height;
  const int left = std::clamp(
      static_cast<int>(std::lround((geometry.x - bounds.x) * rx)), 0, image_w);
  const int top = std::clamp(
      static_cast<int>(std::lround((geometry.y - bounds.y) * ry)), 0, image_h);
  const int width = std::clamp(
      static_cast<int>(std::lround(geometry.width * rx)), 0, image_w - left);
  const int height = std::clamp(
      static_cast<int>(std::lround(geometry.height * ry)), 0, image_h - top);
  if (width <= 0 || height <= 0) return nullptr;
  GdkPixbuf* view =
      gdk_pixbuf_new_subpixbuf(desktop, left, top, width, height);
  const GdkRectangle screen = PhysicalScreen(monitor);
  GdkPixbuf* out =
      (width == screen.width && height == screen.height)
          ? gdk_pixbuf_copy(view)
          : gdk_pixbuf_scale_simple(view, screen.width, screen.height,
                                    GDK_INTERP_BILINEAR);
  g_object_unref(view);
  return out;
}

// ── X11 session: read the root window ───────────────────────────────────────

void CaptureX11(GdkMonitor* monitor, CaptureDone done) {
  GdkRectangle geometry;
  gdk_monitor_get_geometry(monitor, &geometry);
  MonitorCapture capture;
  capture.screen = PhysicalScreen(monitor);
  capture.diagnostic = "x11 root";
  GdkPixbuf* pixbuf =
      gdk_pixbuf_get_from_window(gdk_get_default_root_window(), geometry.x,
                                 geometry.y, geometry.width, geometry.height);
  std::string error;
  if (pixbuf == nullptr) {
    error = "capture_failed";
  } else {
    capture.pixbuf = Adopt(pixbuf);
  }
  // Same contract as the portal path: answer from the main loop, never inline.
  auto* pending = new std::pair<CaptureDone, std::pair<MonitorCapture, std::string>>(
      std::move(done), {std::move(capture), std::move(error)});
  g_idle_add_full(
      G_PRIORITY_DEFAULT,
      [](gpointer data) -> gboolean {
        auto* p = static_cast<
            std::pair<CaptureDone, std::pair<MonitorCapture, std::string>>*>(
            data);
        p->first(std::move(p->second.first), p->second.second);
        return G_SOURCE_REMOVE;
      },
      pending,
      [](gpointer data) {
        delete static_cast<
            std::pair<CaptureDone, std::pair<MonitorCapture, std::string>>*>(
            data);
      });
}

// ── Wayland session: xdg-desktop-portal Screenshot ──────────────────────────

struct PortalRequest {
  CaptureDone done;
  GdkMonitor* monitor = nullptr;  // ref held
  GDBusConnection* bus = nullptr;
  guint subscription = 0;
  guint timeout = 0;
  std::string handle;
  bool finished = false;
};

void Finish(PortalRequest* request, MonitorCapture capture,
            const std::string& error) {
  if (request->finished) return;
  request->finished = true;
  if (request->subscription != 0) {
    g_dbus_connection_signal_unsubscribe(request->bus, request->subscription);
    request->subscription = 0;
  }
  if (request->timeout != 0) {
    g_source_remove(request->timeout);
    request->timeout = 0;
  }
  CaptureDone done = std::move(request->done);
  g_object_unref(request->monitor);
  g_object_unref(request->bus);
  delete request;
  done(std::move(capture), error);
}

void FinishWithError(PortalRequest* request, const std::string& error,
                     const std::string& diagnostic) {
  MonitorCapture capture;
  capture.screen = PhysicalScreen(request->monitor);
  capture.diagnostic = diagnostic;
  Finish(request, std::move(capture), error);
}

void OnPortalResponse(GDBusConnection*, const gchar*, const gchar*,
                      const gchar*, const gchar*, GVariant* parameters,
                      gpointer data) {
  auto* request = static_cast<PortalRequest*>(data);
  guint32 code = 2;
  GVariant* results = nullptr;
  g_variant_get(parameters, "(u@a{sv})", &code, &results);
  const gchar* uri = nullptr;
  if (results != nullptr) {
    g_variant_lookup(results, "uri", "&s", &uri);
  }
  if (code != 0 || uri == nullptr) {
    // 1 = the user refused (or dismissed the permission dialog).
    const std::string diagnostic =
        "portal response " + std::to_string(code);
    if (results != nullptr) g_variant_unref(results);
    FinishWithError(request, code == 1 ? "permission_denied" : "capture_failed",
                    diagnostic);
    return;
  }
  gchar* path = g_filename_from_uri(uri, nullptr, nullptr);
  g_variant_unref(results);
  if (path == nullptr) {
    FinishWithError(request, "capture_failed", "portal uri is not a file");
    return;
  }
  GError* error = nullptr;
  GdkPixbuf* desktop = gdk_pixbuf_new_from_file(path, &error);
  // Our temporary capture, not a screenshot the user asked to keep.
  g_unlink(path);
  g_free(path);
  if (desktop == nullptr) {
    const std::string message =
        error != nullptr ? error->message : "unknown error";
    g_clear_error(&error);
    FinishWithError(request, "capture_failed", "portal png: " + message);
    return;
  }
  GdkPixbuf* cropped = CropToMonitor(desktop, request->monitor);
  const std::string diagnostic =
      "portal " + std::to_string(gdk_pixbuf_get_width(desktop)) + "x" +
      std::to_string(gdk_pixbuf_get_height(desktop));
  g_object_unref(desktop);
  if (cropped == nullptr) {
    FinishWithError(request, "capture_failed", diagnostic + " crop failed");
    return;
  }
  MonitorCapture capture;
  capture.pixbuf = Adopt(cropped);
  capture.screen = PhysicalScreen(request->monitor);
  capture.diagnostic = diagnostic;
  Finish(request, std::move(capture), std::string());
}

void Subscribe(PortalRequest* request, const std::string& handle) {
  if (request->subscription != 0) {
    g_dbus_connection_signal_unsubscribe(request->bus, request->subscription);
  }
  request->handle = handle;
  request->subscription = g_dbus_connection_signal_subscribe(
      request->bus, kPortalBus, "org.freedesktop.portal.Request", "Response",
      handle.c_str(), nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
      OnPortalResponse, request, nullptr);
}

void OnScreenshotCalled(GObject* source, GAsyncResult* result, gpointer data) {
  auto* request = static_cast<PortalRequest*>(data);
  GError* error = nullptr;
  GVariant* reply =
      g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
  if (request->finished) {
    if (reply != nullptr) g_variant_unref(reply);
    g_clear_error(&error);
    return;
  }
  if (reply == nullptr) {
    const std::string message =
        error != nullptr ? error->message : "unknown error";
    g_clear_error(&error);
    FinishWithError(request, "capture_failed", "portal call: " + message);
    return;
  }
  // Portals older than 0.9 pick their own request path: follow it.
  const gchar* handle = nullptr;
  g_variant_get(reply, "(&o)", &handle);
  if (handle != nullptr && request->handle != handle) {
    Subscribe(request, handle);
  }
  g_variant_unref(reply);
}

void CapturePortal(GdkMonitor* monitor, CaptureDone done) {
  GError* error = nullptr;
  GDBusConnection* bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (bus == nullptr) {
    g_clear_error(&error);
    CaptureX11(monitor, std::move(done));
    return;
  }
  auto* request = new PortalRequest();
  request->done = std::move(done);
  request->monitor = GDK_MONITOR(g_object_ref(monitor));
  request->bus = bus;

  static guint counter = 0;
  const std::string token = "fushi_screen_ocr_" + std::to_string(++counter);
  // ":1.42" -> "1_42": the request path the portal will use for our token.
  std::string sender = g_dbus_connection_get_unique_name(bus) + 1;
  std::replace(sender.begin(), sender.end(), '.', '_');
  Subscribe(request, std::string(kPortalPath) + "/request/" + sender + "/" +
                         token);
  request->timeout = g_timeout_add_seconds(
      kPortalTimeoutSeconds,
      [](gpointer data) -> gboolean {
        auto* r = static_cast<PortalRequest*>(data);
        r->timeout = 0;
        FinishWithError(r, "capture_failed", "portal timed out");
        return G_SOURCE_REMOVE;
      },
      request);

  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token",
                        g_variant_new_string(token.c_str()));
  g_variant_builder_add(&options, "{sv}", "interactive",
                        g_variant_new_boolean(FALSE));
  g_dbus_connection_call(
      bus, kPortalBus, kPortalPath, "org.freedesktop.portal.Screenshot",
      "Screenshot", g_variant_new("(sa{sv})", "", &options),
      G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr,
      OnScreenshotCalled, request);
}

}  // namespace

void SkipCloseAnimation(GtkWidget* window) {
  gtk_widget_realize(window);
  GdkWindow* gdk_window = gtk_widget_get_window(window);
  if (gdk_window == nullptr) return;
  const long skip = 1;
  gdk_property_change(gdk_window,
                      gdk_atom_intern_static_string(
                          "_KDE_NET_WM_SKIP_CLOSE_ANIMATION"),
                      gdk_atom_intern_static_string("CARDINAL"), 32,
                      GDK_PROP_MODE_REPLACE,
                      reinterpret_cast<const guchar*>(&skip), 1);
}

bool IsWaylandSession() {
  const gchar* session = g_getenv("XDG_SESSION_TYPE");
  if (session != nullptr && g_strcmp0(session, "wayland") == 0) return true;
  const gchar* display = g_getenv("WAYLAND_DISPLAY");
  return display != nullptr && *display != 0;
}

void CaptureMonitor(GdkMonitor* monitor, CaptureDone done) {
  if (IsWaylandSession()) {
    CapturePortal(monitor, std::move(done));
  } else {
    CaptureX11(monitor, std::move(done));
  }
}

}  // namespace screen_capture
}  // namespace fushi
