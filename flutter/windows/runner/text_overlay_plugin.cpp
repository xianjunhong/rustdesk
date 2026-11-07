#include "text_overlay_plugin.h"

#include <flutter/standard_method_codec.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace {
constexpr wchar_t kClassName[] = L"TomDeskTextOverlay";
constexpr wchar_t kDragClassName[] = L"TomDeskSubtitleDrag";
constexpr UINT kTextFlags = DT_WORDBREAK | DT_NOPREFIX | DT_EXPANDTABS;
constexpr UINT_PTR kAccountTimer = 1;
constexpr BYTE kArmedDragAlpha = 1;
constexpr BYTE kMovingDragAlpha = 48;
constexpr UINT_PTR kCardPointerTimer = 2;
constexpr UINT kCardPointerIntervalMs = 16;

bool AccountAllowsOverlay() {
  using Check = bool (*)();
  auto module = GetModuleHandleW(L"librustdesk.dll");
  auto check = module ? reinterpret_cast<Check>(
      GetProcAddress(module, "tomdesk_account_overlay_allowed")) : nullptr;
  return check && check();
}
constexpr int kPadding = 12;
constexpr COLORREF kTransparentBackground = RGB(1, 2, 3);

const flutter::EncodableValue* Find(const flutter::EncodableMap& args,
                                   const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  return it == args.end() ? nullptr : &it->second;
}

bool ReadString(const flutter::EncodableMap& args, const char* key,
                std::string* value) {
  const auto* item = Find(args, key);
  const auto* str = item ? std::get_if<std::string>(item) : nullptr;
  if (!str || str->find('\0') != std::string::npos) return false;
  *value = *str;
  return true;
}

bool ReadNumber(const flutter::EncodableMap& args, const char* key,
                double* value) {
  const auto* item = Find(args, key);
  if (!item) return false;
  if (auto number = std::get_if<double>(item)) {
    *value = *number;
  } else if (auto integer = std::get_if<int32_t>(item)) {
    *value = *integer;
  } else {
    return false;
  }
  return std::isfinite(*value);
}

bool ToWide(const std::string& input, size_t limit, std::wstring* output) {
  if (input.empty() || input.size() > limit * 4) return false;
  const auto size = static_cast<int>(input.size());
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(),
                                size, nullptr, 0);
  if (count <= 0 || static_cast<size_t>(count) > limit) return false;
  output->resize(count);
  return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(), size,
                             output->data(), count) == count;
}

UINT WindowDpi(HWND window) {
  using GetDpi = UINT(WINAPI*)(HWND);
  static auto get_dpi = reinterpret_cast<GetDpi>(
      GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetDpiForWindow"));
  return get_dpi ? get_dpi(window) : 96;
}

void PaintDragSurface(HWND window) {
  PAINTSTRUCT paint{};
  HDC dc = BeginPaint(window, &paint);
  FillRect(dc, &paint.rcPaint, static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
  RECT rect{};
  BYTE alpha = 0;
  if (GetClientRect(window, &rect) &&
      GetLayeredWindowAttributes(window, nullptr, &alpha, nullptr) &&
      alpha == kMovingDragAlpha) {
    const int dpi = static_cast<int>(WindowDpi(window));
    const int stroke = std::max(1, MulDiv(2, dpi, 96));
    if (auto pen = CreatePen(PS_SOLID, stroke, RGB(219, 232, 255))) {
      const auto old_pen = SelectObject(dc, pen);
      const auto old_brush = SelectObject(dc, GetStockObject(NULL_BRUSH));
      const int corner = MulDiv(16, dpi, 96);
      RoundRect(dc, stroke, stroke, rect.right - stroke, rect.bottom - stroke,
                corner, corner);
      SelectObject(dc, old_brush);
      SelectObject(dc, old_pen);
      DeleteObject(pen);
    }
  }
  EndPaint(window, &paint);
}
}  // namespace

void TextOverlayPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  registrar->AddPlugin(std::make_unique<TextOverlayPlugin>(registrar->messenger()));
}

TextOverlayPlugin::TextOverlayPlugin(flutter::BinaryMessenger* messenger)
    : channel_(std::make_unique<flutter::MethodChannel<>>(
          messenger, "tomdesk/text_overlay",
          &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) { HandleMethod(call, std::move(result)); });
}

TextOverlayPlugin::~TextOverlayPlugin() {
  channel_->SetMethodCallHandler(nullptr);
  if (window_) DestroyWindow(window_);
  if (font_) DeleteObject(font_);
}

void TextOverlayPlugin::HandleMethod(
    const flutter::MethodCall<>& call,
    std::unique_ptr<flutter::MethodResult<>> result) {
  if (call.method_name() != "show" && call.method_name() != "hide") {
    result->NotImplemented();
    return;
  }
  const auto* args = call.arguments()
      ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
  std::string source;
  if (!args || !ReadString(*args, "source", &source) || source.empty() ||
      source.size() > 512) {
    result->Error("invalid_arguments", "A valid subtitle source is required.");
    return;
  }
  if (call.method_name() == "hide") {
    if (source == source_) Hide();
    result->Success();
    return;
  }

  if (!AccountAllowsOverlay()) {
    Close();
    result->Error("account_required", "Sign in to DogShare to use subtitles.");
    return;
  }

  std::string text, label, family;
  std::wstring wide_text, wide_label, wide_family;
  double size = 0, opacity = 0, width = 0, height = 0;
  const auto* color_value = Find(*args, "color");
  int64_t color = -1;
  if (color_value) {
    if (auto value = std::get_if<int32_t>(color_value)) color = *value;
    if (auto value = std::get_if<int64_t>(color_value)) color = *value;
  }
  const auto* card_value = Find(*args, "pairedCard");
  const auto* card = card_value ? std::get_if<bool>(card_value) : nullptr;
  const bool paired_card = card && *card;
  const int min_font_size = paired_card ? 8 : 16;
  const int max_font_size = paired_card ? 96 : 72;
  if (!ReadString(*args, "text", &text) || !ToWide(text, 16000, &wide_text) ||
      !ReadString(*args, "label", &label) || !ToWide(label, 256, &wide_label) ||
      !ReadString(*args, "fontFamily", &family) || !ToWide(family, LF_FACESIZE - 1, &wide_family) ||
      !ReadNumber(*args, "fontSize", &size) ||
      size < min_font_size || size > max_font_size ||
      !ReadNumber(*args, "opacity", &opacity) || opacity < 0 || opacity > 1 ||
      !ReadNumber(*args, "width", &width) || width < 240 || width > 2560 ||
      !ReadNumber(*args, "height", &height) || height < 80 || height > 1440 ||
      color < 0 || color > 0xffffffffLL) {
    Hide();
    result->Error("invalid_arguments", "Invalid subtitle text or style.");
    return;
  }
  if (window_ && paired_card_ != paired_card) DestroyWindow(window_);
  paired_card_ = paired_card;
  if (!CreateOverlay()) {
    Hide();
    result->Error("window_failed", "Unable to create the subtitle window.");
    return;
  }
  font_size_ = size;
  font_family_ = std::move(wide_family);
  color_ = RGB((color >> 16) & 255, (color >> 8) & 255, color & 255);
  color_key_ = paired_card_ && color_ == kTransparentBackground
                   ? RGB(3, 2, 1) : kTransparentBackground;
  const auto alpha = paired_card_ ? static_cast<BYTE>((color >> 24) & 255)
                                  : static_cast<BYTE>(std::lround(opacity * 255));
  if (!UpdateFont() || !SetLayeredWindowAttributes(
          window_, color_key_, alpha, LWA_ALPHA | LWA_COLORKEY)) {
    Hide();
    result->Error("style_failed", "Unable to apply the subtitle style.");
    return;
  }
  // Apply affinity after initializing the layered window, before showing it.
  if (!SetWindowDisplayAffinity(window_, WDA_EXCLUDEFROMCAPTURE)) {
    const DWORD error = GetLastError();
    Hide();
    result->Error("capture_exclusion_failed",
                  "Unable to exclude the subtitle window from capture (Win32 " +
                      std::to_string(error) + ").");
    return;
  }
  if (paired_card_ && !CreateDragSurface()) {
    Hide();
    result->Error("window_failed", "Unable to create the subtitle drag surface.");
    return;
  }
  source_ = source;
  text_ = std::move(wide_text);
  if (!SetWindowTextW(window_, (L"DogShare \u2014 " + wide_label).c_str())) {
    Hide();
    result->Error("window_failed", "Unable to update the subtitle title.");
    return;
  }
  if (!SetTimer(window_, kAccountTimer, 1000, nullptr)) {
    Hide();
    result->Error("window_failed", "Unable to monitor subtitle authorization.");
    return;
  }
  if (paired_card_ && !IsWindowVisible(window_) &&
      !SetTimer(window_, kCardPointerTimer, kCardPointerIntervalMs, nullptr)) {
    Hide();
    result->Error("window_failed", "Unable to monitor subtitle dragging.");
    return;
  }
  const int dpi = static_cast<int>(WindowDpi(window_));
  if (!SetWindowPos(window_, HWND_TOPMOST, 0, 0,
          MulDiv(static_cast<int>(std::lround(width)), dpi, 96),
          MulDiv(static_cast<int>(std::lround(height)), dpi, 96),
          SWP_NOMOVE | SWP_NOACTIVATE | SWP_SHOWWINDOW) ||
      (paired_card_ && !SyncDragSurface())) {
    Hide();
    result->Error("window_failed", "Unable to show the subtitle window.");
    return;
  }
  Layout(true);
  result->Success();
}

bool TextOverlayPlugin::CreateOverlay() {
  if (window_) return true;
  const auto instance = GetModuleHandleW(nullptr);
  WNDCLASSW window_class{};
  window_class.lpfnWndProc = WindowProc;
  window_class.hInstance = instance;
  window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
  window_class.lpszClassName = kClassName;
  if (!RegisterClassW(&window_class) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
    return false;
  RECT work{};
  if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0)) return false;
  // A layered window with this style lets mouse input reach other apps,
  // including where the subtitle glyphs are visible.
  
  const DWORD ex_style = WS_EX_TOPMOST | WS_EX_LAYERED |
    (paired_card_ ? (WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW) : 0);
  if (!CreateWindowExW(ex_style, kClassName, L"DogShare",
      paired_card_ ? WS_POPUP : WS_POPUP | WS_THICKFRAME,
      work.left + 24, work.top + 24, 640, 360, nullptr, nullptr, instance, this))
    return false;
  if (!SetWindowPos(window_, nullptr, 0, 0, 0, 0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED)) {
    DestroyWindow(window_);
    return false;
  }
  return true;
}

bool TextOverlayPlugin::UpdateFont() {
  auto font = CreateFontW(-MulDiv(static_cast<int>(std::lround(font_size_)),
                                static_cast<int>(WindowDpi(window_)), 96),
      0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
      OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
      DEFAULT_PITCH, font_family_.c_str());
  if (!font) return false;
  if (font_) DeleteObject(font_);
  font_ = font;
  return true;
}

void TextOverlayPlugin::Layout(bool scroll_to_end) {
  if (!window_ || !font_) return;
  RECT client{};
  GetClientRect(window_, &client);
  RECT measured{0, 0, std::max(1L, client.right - 2 * kPadding), 0};
  HDC dc = GetDC(window_);
  if (!dc) return;
  auto previous = SelectObject(dc, font_);
  DrawTextW(dc, text_.c_str(), static_cast<int>(text_.size()), &measured,
            kTextFlags | DT_CALCRECT);
  SelectObject(dc, previous);
  ReleaseDC(window_, dc);
  const int max_scroll = static_cast<int>(
      std::max(0L, measured.bottom + 2 * kPadding - client.bottom));
  scroll_ = scroll_to_end ? max_scroll : std::clamp(scroll_, 0, max_scroll);
  InvalidateRect(window_, nullptr, FALSE);
}

void TextOverlayPlugin::Paint() {
  PAINTSTRUCT paint{};
  HDC target = BeginPaint(window_, &paint);
  RECT client{};
  GetClientRect(window_, &client);
  HDC buffer = CreateCompatibleDC(target);
  HBITMAP bitmap = CreateCompatibleBitmap(target, std::max(1L, client.right),
                                          std::max(1L, client.bottom));
  if (buffer && bitmap) {
    auto old_bitmap = SelectObject(buffer, bitmap);
    auto old_font = SelectObject(buffer, font_ ? font_ : GetStockObject(DEFAULT_GUI_FONT));
    SetDCBrushColor(buffer, color_key_);
    FillRect(buffer, &client, static_cast<HBRUSH>(GetStockObject(DC_BRUSH)));
    SetBkMode(buffer, TRANSPARENT);
    SetTextColor(buffer, color_);
    RECT text_rect{kPadding, kPadding - scroll_, client.right - kPadding,
                   client.bottom + scroll_};
    DrawTextW(buffer, text_.c_str(), static_cast<int>(text_.size()), &text_rect, kTextFlags);
    BitBlt(target, 0, 0, client.right, client.bottom, buffer, 0, 0, SRCCOPY);
    SelectObject(buffer, old_font);
    SelectObject(buffer, old_bitmap);
  } else {
    SetDCBrushColor(target, color_key_);
    FillRect(target, &client, static_cast<HBRUSH>(GetStockObject(DC_BRUSH)));
  }
  if (bitmap) DeleteObject(bitmap);
  if (buffer) DeleteDC(buffer);
  EndPaint(window_, &paint);
}

bool TextOverlayPlugin::CreateDragSurface() {
  if (drag_window_) return true;
  const auto instance = GetModuleHandleW(nullptr);
  WNDCLASSW window_class{};
  window_class.style = CS_HREDRAW | CS_VREDRAW;
  window_class.lpfnWndProc = DragWindowProc;
  window_class.hInstance = instance;
  window_class.hCursor = LoadCursor(nullptr, IDC_SIZEALL);
  window_class.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  window_class.lpszClassName = kDragClassName;
  if (!RegisterClassW(&window_class) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
    return false;
  drag_window_ = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kDragClassName, L"", WS_POPUP, 0, 0, 1, 1, window_, nullptr, instance, nullptr);
  if (!drag_window_) return false;
  // Zero-alpha pixels would let Alt+click reach the application underneath.
  if (!SetLayeredWindowAttributes(drag_window_, 0, kArmedDragAlpha, LWA_ALPHA) ||
      !SetWindowDisplayAffinity(drag_window_, WDA_EXCLUDEFROMCAPTURE)) {
    DestroyWindow(drag_window_);
    drag_window_ = nullptr;
    return false;
  }
  return true;
}

void TextOverlayPlugin::SetDragOutline(bool visible) {
  if (!drag_window_) return;
  const BYTE alpha = visible ? kMovingDragAlpha : kArmedDragAlpha;
  BYTE current = 0;
  if (GetLayeredWindowAttributes(drag_window_, nullptr, &current, nullptr) &&
      current == alpha) return;
  if (SetLayeredWindowAttributes(drag_window_, 0, alpha, LWA_ALPHA)) {
    RedrawWindow(drag_window_, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW);
  }
}

bool TextOverlayPlugin::SyncDragSurface() {
  RECT rect{};
  if (!GetWindowRect(window_, &rect)) return false;
  return SetWindowPos(drag_window_, nullptr, rect.left, rect.top,
                      rect.right - rect.left, rect.bottom - rect.top,
                      SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_NOACTIVATE);
}

void TextOverlayPlugin::PollCardPointer() {
  if (!drag_window_ || !IsWindowVisible(window_)) return;
  const bool alt_down = GetAsyncKeyState(VK_MENU) < 0;
  const int button = GetSystemMetrics(SM_SWAPBUTTON) ? VK_RBUTTON : VK_LBUTTON;
  const bool button_down = GetAsyncKeyState(button) < 0;
  if (dragging_card_) {
    if (GetAsyncKeyState(VK_ESCAPE) < 0) {
      EndCardDrag(true);
    } else if (!alt_down) {
      EndCardDrag();
    } else {
      // The nonactivating window may stop receiving movement outside its bounds.
      POINT pointer{};
      if (GetCursorPos(&pointer)) MoveCard(pointer);
      if (!button_down) EndCardDrag();
    }
    return;
  }
  POINT pointer{};
  RECT rect{};
  // Do not take over an ordinary left-button gesture that is already in progress.
  const bool arm = alt_down && !button_down && GetCursorPos(&pointer) &&
                   GetWindowRect(window_, &rect) && PtInRect(&rect, pointer);
  if (arm != (IsWindowVisible(drag_window_) != FALSE)) {
    ShowWindow(drag_window_, arm ? SW_SHOWNOACTIVATE : SW_HIDE);
  }
}

void TextOverlayPlugin::BeginCardDrag(POINT pointer) {
  RECT rect{};
  if (dragging_card_ || GetAsyncKeyState(VK_MENU) >= 0 ||
      !IsWindowVisible(drag_window_) || !GetWindowRect(window_, &rect) ||
      !PtInRect(&rect, pointer)) return;
  drag_start_pointer_ = pointer;
  drag_start_position_ = {rect.left, rect.top};
  dragging_card_ = true;
  SetCapture(drag_window_);
  SetDragOutline(true);
}

void TextOverlayPlugin::MoveCard(POINT pointer) {
  if (!dragging_card_) return;
  const LONG x = drag_start_position_.x + pointer.x - drag_start_pointer_.x;
  const LONG y = drag_start_position_.y + pointer.y - drag_start_pointer_.y;
  RECT rect{};
  if (GetWindowRect(window_, &rect) && (rect.left != x || rect.top != y)) {
    SetWindowPos(window_, nullptr, x, y, 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  }
}

void TextOverlayPlugin::EndCardDrag(bool restore_start) {
  if (!dragging_card_) return;
  if (restore_start) MoveCard(drag_start_pointer_);
  dragging_card_ = false;
  ShowWindow(drag_window_, SW_HIDE);
  SetDragOutline(false);
  if (GetCapture() == drag_window_) ReleaseCapture();
}

LRESULT CALLBACK TextOverlayPlugin::DragWindowProc(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_NCHITTEST) {
    return GetAsyncKeyState(VK_MENU) < 0 ? HTCLIENT : HTTRANSPARENT;
  }
  if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
  if (message == WM_ERASEBKGND) return 1;
  if (message == WM_PAINT) {
    PaintDragSurface(window);
    return 0;
  }
  auto* self = reinterpret_cast<TextOverlayPlugin*>(
      GetWindowLongPtrW(GetWindow(window, GW_OWNER), GWLP_USERDATA));
  if (!self) return DefWindowProcW(window, message, wparam, lparam);
  switch (message) {
    case WM_LBUTTONDOWN:
    case WM_MOUSEMOVE:
    case WM_LBUTTONUP: {
      POINT pointer{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (message == WM_LBUTTONDOWN || self->dragging_card_) {
        if (ClientToScreen(window, &pointer)) {
          if (message == WM_LBUTTONDOWN) {
            self->BeginCardDrag(pointer);
          } else if (GetAsyncKeyState(VK_MENU) < 0) {
            self->MoveCard(pointer);
          }
        }
        if (message == WM_LBUTTONUP || GetAsyncKeyState(VK_MENU) >= 0) {
          self->EndCardDrag();
        }
      }
      return 0;
    }
    case WM_KEYDOWN:
      if (wparam == VK_ESCAPE && self->dragging_card_) {
        self->EndCardDrag(true);
        return 0;
      }
      break;
    case WM_CAPTURECHANGED:
    case WM_CANCELMODE:
    case WM_DESTROY:
      self->EndCardDrag();
      break;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

void TextOverlayPlugin::Scroll(int position) {
  scroll_ = std::max(0, position);
  Layout(false);
}

void TextOverlayPlugin::Hide() {
  if (drag_window_) {
    EndCardDrag();
    ShowWindow(drag_window_, SW_HIDE);
  }
  if (window_) {
    KillTimer(window_, kAccountTimer);
    if (paired_card_) KillTimer(window_, kCardPointerTimer);
    ShowWindow(window_, SW_HIDE);
  }
  source_.clear();
  text_.clear();
}

void TextOverlayPlugin::Close() {
  auto source = std::move(source_);
  Hide();
  channel_->InvokeMethod("closed", std::make_unique<flutter::EncodableValue>(
      flutter::EncodableMap{{flutter::EncodableValue("source"), flutter::EncodableValue(source)}}));
}

LRESULT CALLBACK TextOverlayPlugin::WindowProc(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  auto* self = reinterpret_cast<TextOverlayPlugin*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<TextOverlayPlugin*>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
    self->window_ = window;
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (!self) return DefWindowProcW(window, message, wparam, lparam);
  switch (message) {
    case WM_CLOSE: self->Close(); return 0;
    case WM_TIMER:
      if (wparam == kAccountTimer && !AccountAllowsOverlay()) self->Close();
      if (wparam == kCardPointerTimer && self->paired_card_) self->PollCardPointer();
      return 0;
    case WM_NCCALCSIZE: return 0;
    case WM_NCHITTEST: return self->paired_card_ ? HTTRANSPARENT : HTCAPTION;
    case WM_ERASEBKGND: return 1;
    case WM_PAINT: self->Paint(); return 0;
    case WM_CANCELMODE:
      self->EndCardDrag();
      break;
    case WM_MOVE:
      if (self->drag_window_) self->SyncDragSurface();
      break;
    case WM_SIZE:
      self->Layout(false);
      if (self->drag_window_) self->SyncDragSurface();
      return 0;
    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      const int dpi = static_cast<int>(WindowDpi(window));
      info->ptMinTrackSize = {MulDiv(240, dpi, 96), MulDiv(80, dpi, 96)};
      return 0;
    }
    case WM_MOUSEWHEEL:
      if (!self->paired_card_)
        self->Scroll(self->scroll_ - GET_WHEEL_DELTA_WPARAM(wparam) / WHEEL_DELTA * 48);
      return 0;
    case WM_DPICHANGED: {
      const auto* rect = reinterpret_cast<RECT*>(lparam);
      SetWindowPos(window, nullptr, rect->left, rect->top, rect->right - rect->left,
                    rect->bottom - rect->top, SWP_NOZORDER | SWP_NOACTIVATE |
                        (self->dragging_card_ ? SWP_NOMOVE : 0));
      if (!self->UpdateFont()) OutputDebugStringW(L"TomDesk: subtitle font update failed.\n");
      self->Layout(false);
      return 0;
    }
    case WM_NCDESTROY:
      self->EndCardDrag();
      self->window_ = nullptr;
      self->drag_window_ = nullptr;
      SetWindowLongPtrW(window, GWLP_USERDATA, 0);
      break;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}
