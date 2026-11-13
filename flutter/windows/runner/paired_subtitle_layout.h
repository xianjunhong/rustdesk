#ifndef RUNNER_PAIRED_SUBTITLE_LAYOUT_H_
#define RUNNER_PAIRED_SUBTITLE_LAYOUT_H_

#include <windows.h>
#include <d2d1.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <string>
#include <vector>

class PairedSubtitleLayout {
 public:
  bool Fit(const std::wstring& text, const std::wstring& font_family,
           float font_size, bool automatic, float width, float height);
  bool Draw(HDC dc, const RECT& bounds, UINT dpi, COLORREF color,
            COLORREF background, int page);

  float width() const { return width_; }
  float height() const { return height_; }
  int page_count() const { return static_cast<int>(pages_.size()); }

 private:
  struct Page {
    float top;
    float height;
  };

  Microsoft::WRL::ComPtr<IDWriteFactory> text_factory_;
  Microsoft::WRL::ComPtr<IDWriteTextLayout> layout_;
  Microsoft::WRL::ComPtr<ID2D1Factory> drawing_factory_;
  Microsoft::WRL::ComPtr<ID2D1DCRenderTarget> target_;
  std::vector<Page> pages_;
  float width_ = 0;
  float height_ = 0;
};

#endif  // RUNNER_PAIRED_SUBTITLE_LAYOUT_H_
