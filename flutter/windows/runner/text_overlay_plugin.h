#ifndef RUNNER_TEXT_OVERLAY_PLUGIN_H_
#define RUNNER_TEXT_OVERLAY_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <windows.h>

#include <memory>
#include <string>

class TextOverlayPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);
  explicit TextOverlayPlugin(flutter::BinaryMessenger* messenger);
  ~TextOverlayPlugin() override;

 private:
  void HandleMethod(const flutter::MethodCall<>& call,
                    std::unique_ptr<flutter::MethodResult<>> result);
  bool CreateOverlay();
  bool CreateDragSurface();
  void SetDragOutline(bool visible);
  void PollCardPointer();
  void BeginCardDrag(POINT pointer);
  void MoveCard(POINT pointer);
  void EndCardDrag(bool restore_start = false);
  bool SyncDragSurface();
  bool UpdateFont();
  void Layout(bool scroll_to_end);
  void Paint();
  void Scroll(int position);
  void Hide();
  void Close();
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam);
  static LRESULT CALLBACK DragWindowProc(HWND window, UINT message,
                                         WPARAM wparam, LPARAM lparam);

  std::unique_ptr<flutter::MethodChannel<>> channel_;
  HWND window_ = nullptr;
  HWND drag_window_ = nullptr;
  bool dragging_card_ = false;
  POINT drag_start_pointer_{};
  POINT drag_start_position_{};
  HFONT font_ = nullptr;
  std::string source_;
  std::wstring text_;
  std::wstring font_family_ = L"Microsoft YaHei";
  double font_size_ = 32;
  COLORREF color_ = RGB(255, 255, 255);
  COLORREF color_key_ = RGB(1, 2, 3);
  bool paired_card_ = false;
  int scroll_ = 0;
};

#endif  // RUNNER_TEXT_OVERLAY_PLUGIN_H_
