#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

// Smallest size at which the single-column layout stays usable, in logical
// pixels (as on Linux).
constexpr int kMinWidth = 360;
constexpr int kMinHeight = 480;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Files dragged from Explorer and dropped anywhere on the window: their
  // paths go to the app, which takes calendar and contacts files. The
  // Flutter view does not accept files itself, so a drop on it reaches this
  // window, its parent.
  drop_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "fweek/drop",
          &flutter::StandardMethodCodec::GetInstance());
  ::DragAcceptFiles(GetHandle(), TRUE);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  drop_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_DROPFILES:
      OnDropFiles(reinterpret_cast<HDROP>(wparam));
      return 0;
    case WM_GETMINMAXINFO: {
      const UINT dpi = ::GetDpiForWindow(hwnd);
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = ::MulDiv(kMinWidth, dpi, 96);
      info->ptMinTrackSize.y = ::MulDiv(kMinHeight, dpi, 96);
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::OnDropFiles(HDROP drop) {
  flutter::EncodableList paths;
  const UINT count = ::DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  for (UINT i = 0; i < count; i++) {
    const UINT length = ::DragQueryFileW(drop, i, nullptr, 0);
    if (length == 0) continue;
    std::wstring path(length + 1, L'\0');
    ::DragQueryFileW(drop, i, path.data(), length + 1);
    path.resize(length);
    const std::string utf8 = Utf8FromUtf16(path.c_str());
    if (!utf8.empty()) paths.push_back(flutter::EncodableValue(utf8));
  }
  ::DragFinish(drop);
  if (!paths.empty() && drop_channel_) {
    drop_channel_->InvokeMethod(
        "files", std::make_unique<flutter::EncodableValue>(paths));
  }
}
