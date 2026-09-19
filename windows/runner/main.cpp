#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>

#include "app_links/app_links_plugin_c_api.h"
#include "flutter_window.h"
#include "utils.h"

// LibrePili: "Open with" passes a plain file/folder path, which app_links
// does not forward (no URI scheme). Send it to a running instance as a
// `librepili-open:<full path>` link (handled in lib/utils/app_scheme.dart).
static bool SendFileToInstance() {
  int argc;
  wchar_t **argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return false;
  }
  std::string path;
  if (argc == 2 && ::GetFileAttributesW(argv[1]) != INVALID_FILE_ATTRIBUTES) {
    wchar_t full[32768] = {};
    if (::GetFullPathNameW(argv[1], 32768, full, nullptr) != 0) {
      path = Utf8FromUtf16(full);
    }
  }
  ::LocalFree(argv);
  if (path.empty()) {
    return false;
  }

  struct State {
    HWND found;
    wchar_t ourExe[MAX_PATH];
  };
  State s = {};
  ::GetModuleFileNameW(nullptr, s.ourExe, MAX_PATH);
  ::EnumWindows(
      [](HWND hwnd, LPARAM lp) -> BOOL {
        auto *s = reinterpret_cast<State *>(lp);
        wchar_t cls[64] = {};
        ::GetClassNameW(hwnd, cls, 64);
        if (_wcsicmp(cls, L"FLUTTER_RUNNER_WIN32_WINDOW") != 0) return TRUE;
        DWORD pid = 0;
        ::GetWindowThreadProcessId(hwnd, &pid);
        HANDLE h = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
        if (!h) return TRUE;
        wchar_t exe[MAX_PATH] = {};
        DWORD len = MAX_PATH;
        ::QueryFullProcessImageNameW(h, 0, exe, &len);
        ::CloseHandle(h);
        if (_wcsicmp(exe, s->ourExe) == 0) {
          s->found = hwnd;
          return FALSE;
        }
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&s));
  if (!s.found) {
    return false;
  }

  const std::string link = "librepili-open:" + path;
  COPYDATASTRUCT cds = {0};
  cds.dwData = WM_USER + 2;  // app_links' APPLINK_MSG_ID
  cds.cbData = static_cast<DWORD>(link.size() + 1);
  cds.lpData = (PVOID)link.c_str();
  ::SendMessage(s.found, WM_COPYDATA, (WPARAM)s.found, (LPARAM)(LPVOID)&cds);

  WINDOWPLACEMENT place = {sizeof(WINDOWPLACEMENT)};
  ::GetWindowPlacement(s.found, &place);
  ::ShowWindow(s.found, place.showCmd == SW_SHOWMAXIMIZED ? SW_SHOWMAXIMIZED
                        : place.showCmd == SW_SHOWMINIMIZED ? SW_RESTORE
                                                            : SW_NORMAL);
  ::SetForegroundWindow(s.found);
  return true;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (SendFileToInstance() || SendAppLinkToInstance()) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  // https://github.com/flutter/flutter/issues/188635
  // https://github.com/flutter/flutter/issues/191050
  // https://github.com/flutter/flutter/issues/191069
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"LibrePili", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
