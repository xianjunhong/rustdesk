#include "receiver_tray_plugin.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <windowsx.h>

#include <cwchar>
#include <utility>

#include "resource.h"

namespace {
constexpr UINT kIconId = 0x5444;
constexpr UINT kOpenCommand = 1;
constexpr UINT kLogoutCommand = 2;
constexpr UINT kExitCommand = 3;

bool ReadLabel(const flutter::EncodableMap& args, const char* key,
               std::wstring* output) {
  const auto it = args.find(flutter::EncodableValue(key));
  const auto* value = it == args.end()
                          ? nullptr
                          : std::get_if<std::string>(&it->second);
  if (!value || value->empty() || value->size() > 1024 ||
      value->find('\0') != std::string::npos) {
    return false;
  }
  const auto size = static_cast<int>(value->size());
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                      value->data(), size, nullptr, 0);
  if (count <= 0 || count > 256) return false;
  output->resize(count);
  return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value->data(), size,
                             output->data(), count) == count;
}
}  // namespace

void ReceiverTrayPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  registrar->AddPlugin(std::make_unique<ReceiverTrayPlugin>(registrar));
}

ReceiverTrayPlugin::ReceiverTrayPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar),
      channel_(std::make_unique<flutter::MethodChannel<>>(
          registrar->messenger(), "tomdesk/receiver_tray",
          &flutter::StandardMethodCodec::GetInstance())),
      callback_message_(RegisterWindowMessageW(L"TomDeskReceiverTrayCallback")),
      taskbar_created_message_(RegisterWindowMessageW(L"TaskbarCreated")) {
  delegate_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
      [this](HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
        return HandleWindowMessage(window, message, wparam, lparam);
      });
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) { HandleMethod(call, std::move(result)); });
}

ReceiverTrayPlugin::~ReceiverTrayPlugin() {
  channel_->SetMethodCallHandler(nullptr);
  registrar_->UnregisterTopLevelWindowProcDelegate(delegate_id_);
  Cleanup();
}

void ReceiverTrayPlugin::HandleMethod(
    const flutter::MethodCall<>& call,
    std::unique_ptr<flutter::MethodResult<>> result) {
  if (call.method_name() == "cleanup") {
    Cleanup();
    result->Success();
    return;
  }
  if (call.method_name() != "ensure") {
    result->NotImplemented();
    return;
  }
  const auto* args = call.arguments()
                         ? std::get_if<flutter::EncodableMap>(call.arguments())
                         : nullptr;
  std::wstring open_label, logout_label, exit_label;
  if (!args || !ReadLabel(*args, "openLabel", &open_label) ||
      !ReadLabel(*args, "logoutLabel", &logout_label) ||
      !ReadLabel(*args, "exitLabel", &exit_label)) {
    result->Success(flutter::EncodableValue(false));
    return;
  }
  open_label_ = std::move(open_label);
  logout_label_ = std::move(logout_label);
  exit_label_ = std::move(exit_label);
  result->Success(flutter::EncodableValue(EnsureIcon()));
}

bool ReceiverTrayPlugin::EnsureIcon() {
  if (!callback_message_ || !taskbar_created_message_) return false;
  if (!window_) {
    auto* view = registrar_->GetView();
    if (!view) return false;
    window_ = GetAncestor(view->GetNativeWindow(), GA_ROOT);
  }
  if (!IsWindow(window_)) return false;
  if (!icon_) {
    icon_ = static_cast<HICON>(LoadImageW(
        GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0));
    owns_icon_ = icon_ != nullptr;
    if (!icon_) {
      icon_ = reinterpret_cast<HICON>(
          SendMessageW(window_, WM_GETICON, ICON_SMALL2, 0));
      if (!icon_) {
        icon_ = reinterpret_cast<HICON>(
            SendMessageW(window_, WM_GETICON, ICON_BIG, 0));
      }
    }
  }
  if (!icon_) return false;

  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  data.uCallbackMessage = callback_message_;
  data.hIcon = icon_;
  wcscpy_s(data.szTip, L"DogShare");
  if (icon_added_) {
    if (Shell_NotifyIconW(NIM_MODIFY, &data)) return true;
    Shell_NotifyIconW(NIM_DELETE, &data);
    icon_added_ = false;
  }
  if (!Shell_NotifyIconW(NIM_ADD, &data)) return false;
  data.uVersion = NOTIFYICON_VERSION_4;
  if (!Shell_NotifyIconW(NIM_SETVERSION, &data)) {
    Shell_NotifyIconW(NIM_DELETE, &data);
    return false;
  }
  icon_added_ = true;
  return true;
}

void ReceiverTrayPlugin::Cleanup() {
  if (icon_added_) {
    NOTIFYICONDATAW data{};
    data.cbSize = sizeof(data);
    data.hWnd = window_;
    data.uID = kIconId;
    Shell_NotifyIconW(NIM_DELETE, &data);
    icon_added_ = false;
  }
  if (icon_ && owns_icon_) DestroyIcon(icon_);
  icon_ = nullptr;
  owns_icon_ = false;
  window_ = nullptr;
}

void ReceiverTrayPlugin::RestoreAndInvoke(const char* method) {
  if (IsWindow(window_)) {
    ShowWindow(window_, IsIconic(window_) ? SW_RESTORE : SW_SHOW);
    SetForegroundWindow(window_);
  }
  channel_->InvokeMethod(method, nullptr);
}

void ReceiverTrayPlugin::ShowMenu(POINT position) {
  HMENU menu = CreatePopupMenu();
  if (!menu) {
    RestoreAndInvoke("open");
    return;
  }
  if (!AppendMenuW(menu, MF_STRING, kOpenCommand, open_label_.c_str()) ||
      !AppendMenuW(menu, MF_STRING, kLogoutCommand, logout_label_.c_str()) ||
      !AppendMenuW(menu, MF_STRING, kExitCommand, exit_label_.c_str())) {
    DestroyMenu(menu);
    RestoreAndInvoke("open");
    return;
  }
  if (position.x == -1 && position.y == -1) GetCursorPos(&position);
  SetForegroundWindow(window_);
  const auto command = static_cast<UINT>(TrackPopupMenuEx(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, position.x,
      position.y, window_, nullptr));
  PostMessageW(window_, WM_NULL, 0, 0);
  DestroyMenu(menu);
  switch (command) {
    case kOpenCommand:
      RestoreAndInvoke("open");
      break;
    case kLogoutCommand:
      RestoreAndInvoke("logout");
      break;
    case kExitCommand:
      channel_->InvokeMethod("exit", nullptr);
      break;
  }
}

std::optional<LRESULT> ReceiverTrayPlugin::HandleWindowMessage(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (window != window_) return std::nullopt;
  if (taskbar_created_message_ && message == taskbar_created_message_) {
    if (icon_added_) {
      icon_added_ = false;
      if (!EnsureIcon()) RestoreAndInvoke("open");
    }
    return std::nullopt;
  }
  if (callback_message_ && message == callback_message_ && icon_added_ &&
      HIWORD(lparam) == kIconId) {
    switch (LOWORD(lparam)) {
      case NIN_SELECT:
      case NIN_KEYSELECT:
      case WM_LBUTTONDBLCLK:
        RestoreAndInvoke("open");
        return 0;
      case WM_CONTEXTMENU:
        ShowMenu(POINT{GET_X_LPARAM(wparam), GET_Y_LPARAM(wparam)});
        return 0;
    }
  }
  return std::nullopt;
}
