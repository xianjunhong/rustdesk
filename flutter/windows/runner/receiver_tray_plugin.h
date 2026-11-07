#ifndef RUNNER_RECEIVER_TRAY_PLUGIN_H_
#define RUNNER_RECEIVER_TRAY_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <windows.h>

#include <memory>
#include <optional>
#include <string>

class ReceiverTrayPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);
  explicit ReceiverTrayPlugin(flutter::PluginRegistrarWindows* registrar);
  ~ReceiverTrayPlugin() override;

 private:
  void HandleMethod(const flutter::MethodCall<>& call,
                    std::unique_ptr<flutter::MethodResult<>> result);
  bool EnsureIcon();
  void Cleanup();
  void RestoreAndInvoke(const char* method);
  void ShowMenu(POINT position);
  std::optional<LRESULT> HandleWindowMessage(HWND window, UINT message,
                                            WPARAM wparam, LPARAM lparam);

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<>> channel_;
  int delegate_id_;
  UINT callback_message_;
  UINT taskbar_created_message_;
  HWND window_ = nullptr;
  HICON icon_ = nullptr;
  bool owns_icon_ = false;
  bool icon_added_ = false;
  std::wstring open_label_;
  std::wstring logout_label_;
  std::wstring exit_label_;
};

#endif  // RUNNER_RECEIVER_TRAY_PLUGIN_H_
