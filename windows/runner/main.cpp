#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shobjidl.h>
#include <windows.h>

#include <algorithm>
#include <cstdlib>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Names the app to Windows: the taskbar groups its windows under it, and
// notifications are shown in its name. The installer gives the Start-menu
// shortcut the same id.
constexpr wchar_t kAppUserModelId[] = L"yourj4m.fweek";

// Held while the app runs, so that a second start finds the first.
constexpr wchar_t kInstanceMutex[] = L"Local\\yourj4m.fweek.instance";

// The window's size on first start, in logical pixels (as on Linux).
constexpr int kWidth = 1280;
constexpr int kHeight = 860;

// Brings the window of the instance already running to the front.
void ShowRunningInstance() {
  HWND window = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"fweek");
  if (window == nullptr) return;
  if (::IsIconic(window)) ::ShowWindow(window, SW_RESTORE);
  ::SetForegroundWindow(window);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // One window per planner: a second start shows the first. Test runs
  // point the app at a data folder of their own, and may run side by side.
  // (GetEnvironmentVariableW, not _wgetenv: the build turns MSVC's warning
  // about the latter into an error.)
  const bool own_data_dir =
      ::GetEnvironmentVariableW(L"FWEEK_DATA_DIR", nullptr, 0) > 1;
  HANDLE running = nullptr;
  if (!own_data_dir) {
    running = ::CreateMutexW(nullptr, TRUE, kInstanceMutex);
    if (running != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
      ShowRunningInstance();
      ::CloseHandle(running);
      return EXIT_SUCCESS;
    }
  }

  ::SetCurrentProcessExplicitAppUserModelID(kAppUserModelId);

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // Centred on the primary screen's work area, and no larger than it.
  RECT work{};
  ::SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  const int dpi = static_cast<int>(::GetDpiForSystem());
  const int work_width = ::MulDiv(work.right - work.left, 96, dpi);
  const int work_height = ::MulDiv(work.bottom - work.top, 96, dpi);
  const int width = std::min(kWidth, work_width);
  const int height = std::min(kHeight, work_height);
  Win32Window::Point origin(
      ::MulDiv(work.left, 96, dpi) + std::max(0, (work_width - width) / 2),
      ::MulDiv(work.top, 96, dpi) + std::max(0, (work_height - height) / 2));
  Win32Window::Size size(width, height);
  if (!window.Create(L"fweek", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (running != nullptr) ::CloseHandle(running);
  return EXIT_SUCCESS;
}
