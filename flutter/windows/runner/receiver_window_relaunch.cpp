#include "receiver_window_relaunch.h"

#include <optional>
#include <string>

namespace receiver_window {
namespace {

constexpr wchar_t kWindowProperty[] = L"DogShareReceiverWindowRelaunchV1";
constexpr ULONG_PTR kUnpackedMarker = 1;
constexpr DWORD kLauncherCapacity = 256;
constexpr DWORD kPathCapacity = 32768;

std::optional<std::wstring> LauncherName() {
  wchar_t buffer[kLauncherCapacity];
  SetLastError(ERROR_SUCCESS);
  const DWORD length =
      GetEnvironmentVariableW(L"RUSTDESK_APPNAME", buffer, kLauncherCapacity);
  if (length == 0) {
    const DWORD error = GetLastError();
    if (error == ERROR_ENVVAR_NOT_FOUND || error == ERROR_SUCCESS) {
      return std::wstring();
    }
    return std::nullopt;
  }
  if (length >= kLauncherCapacity) return std::nullopt;
  return std::wstring(buffer, length);
}

bool EqualWindowsText(const std::wstring& left, const std::wstring& right) {
  return CompareStringOrdinal(left.c_str(), -1, right.c_str(), -1, TRUE) ==
         CSTR_EQUAL;
}

std::optional<std::wstring> ProcessImagePath(HANDLE process) {
  std::wstring image(kPathCapacity, L'\0');
  DWORD length = kPathCapacity;
  if (!QueryFullProcessImageNameW(process, 0, image.data(), &length) ||
      length == 0) {
    return std::nullopt;
  }
  image.resize(length);
  return image;
}

bool MatchesLauncher(ULONG_PTR marker, const std::wstring& launcher) {
  if (launcher.empty()) return marker == kUnpackedMarker;
  if (marker <= kUnpackedMarker || marker > 0xffff) return false;
  wchar_t name[kLauncherCapacity];
  const UINT length = GlobalGetAtomNameW(static_cast<ATOM>(marker), name,
                                         static_cast<int>(kLauncherCapacity));
  return length != 0 && EqualWindowsText(std::wstring(name, length), launcher);
}

struct WindowSearch {
  const std::wstring& launcher;
  const std::wstring& image_path;
  HWND window = nullptr;
  DWORD pid = 0;
};

BOOL CALLBACK FindReceiverWindow(HWND window, LPARAM data) {
  auto* search = reinterpret_cast<WindowSearch*>(data);
  const auto marker = reinterpret_cast<ULONG_PTR>(
      GetPropW(window, kWindowProperty));
  if (!MatchesLauncher(marker, search->launcher)) return TRUE;

  DWORD pid = 0;
  GetWindowThreadProcessId(window, &pid);
  if (!pid || pid == GetCurrentProcessId()) return TRUE;
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) return TRUE;
  const auto image = ProcessImagePath(process);
  CloseHandle(process);
  if (!image || !EqualWindowsText(*image, search->image_path)) return TRUE;
  search->window = window;
  search->pid = pid;
  return FALSE;
}

}  // namespace

bool EnableRelaunch(HWND window) {
  if (!IsWindow(window)) return false;
  if (GetPropW(window, kWindowProperty)) return true;
  const auto launcher = LauncherName();
  if (!launcher) return false;

  // An atom carries the exact launcher name across processes without a pointer
  // into the other process. An unpacked runner has its own marker.
  const ATOM atom = launcher->empty() ? 0 : GlobalAddAtomW(launcher->c_str());
  if (!launcher->empty() && !atom) return false;
  const ULONG_PTR marker = atom ? atom : kUnpackedMarker;
  if (SetPropW(window, kWindowProperty, reinterpret_cast<HANDLE>(marker))) {
    return true;
  }
  if (atom) GlobalDeleteAtom(atom);
  return false;
}

void DisableRelaunch(HWND window) {
  const auto marker = reinterpret_cast<ULONG_PTR>(
      RemovePropW(window, kWindowProperty));
  if (marker > kUnpackedMarker && marker <= 0xffff) {
    GlobalDeleteAtom(static_cast<ATOM>(marker));
  }
}

bool RestoreExistingWindow() {
  const auto launcher = LauncherName();
  const auto image = ProcessImagePath(GetCurrentProcess());
  if (!launcher || !image) return false;

  WindowSearch search{*launcher, *image};
  EnumWindows(FindReceiverWindow, reinterpret_cast<LPARAM>(&search));
  if (!search.window) return false;
  AllowSetForegroundWindow(search.pid);
  if (!ShowWindowAsync(search.window, IsIconic(search.window) ? SW_RESTORE
                                                             : SW_SHOW)) {
    return false;
  }
  SetForegroundWindow(search.window);
  return true;
}

}  // namespace receiver_window
