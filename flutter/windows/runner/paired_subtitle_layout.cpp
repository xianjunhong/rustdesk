#include "paired_subtitle_layout.h"

#include <algorithm>
#include <cmath>

namespace {
constexpr float kPadding = 12;
constexpr float kMinimumReadableFont = 12;
constexpr float kPreferredWidth = 640;
constexpr float kWideWidth = 960;
constexpr float kPreferredHeight = 360;

D2D1_COLOR_F ToColor(COLORREF color) {
  return D2D1::ColorF(GetRValue(color) / 255.f, GetGValue(color) / 255.f,
                      GetBValue(color) / 255.f);
}
}  // namespace

bool PairedSubtitleLayout::Fit(const std::wstring& text,
                               const std::wstring& font_family, float font_size,
                               bool automatic, float width, float height) {
  using Microsoft::WRL::ComPtr;
  if (width <= 2 * kPadding || height <= 2 * kPadding || text.empty()) return false;
  if (!text_factory_ &&
      FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                 reinterpret_cast<IUnknown**>(text_factory_.GetAddressOf())))) {
    return false;
  }

  const float content_height = height - 2 * kPadding;
  DWRITE_TEXT_METRICS metrics{};
  ComPtr<IDWriteTextLayout> layout;
  auto measure = [&](float size, float layout_width) {
    ComPtr<IDWriteTextFormat> format;
    if (FAILED(text_factory_->CreateTextFormat(
            font_family.c_str(), nullptr, DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, L"zh-CN",
            format.GetAddressOf())) ||
        FAILED(format->SetWordWrapping(DWRITE_WORD_WRAPPING_WRAP)) ||
        FAILED(text_factory_->CreateTextLayout(
            text.data(), static_cast<UINT32>(text.size()), format.Get(),
            layout_width - 2 * kPadding, 1000000, layout.ReleaseAndGetAddressOf()))) {
      return false;
    }
    return SUCCEEDED(layout->GetMetrics(&metrics));
  };
  std::vector<DWRITE_LINE_METRICS> lines;
  auto read_lines = [&] {
    lines.resize(metrics.lineCount);
    UINT32 count = 0;
    return !lines.empty() &&
           SUCCEEDED(layout->GetLineMetrics(lines.data(), metrics.lineCount, &count)) &&
           count == lines.size();
  };

  float layout_width = automatic ? std::min(kPreferredWidth, width) : width;
  if (!measure(font_size, layout_width)) return false;
  if (automatic && metrics.height > std::min(kPreferredHeight - 2 * kPadding,
                                              content_height)) {
    const float wider = std::min(kWideWidth, width);
    if (wider > layout_width && !measure(font_size, wider)) return false;
    layout_width = wider;
    if (metrics.height > content_height && width > layout_width) {
      layout_width = width;
      if (!measure(font_size, layout_width)) return false;
    }
  }

  // A manual area keeps the selected type size unless even one line will not
  // fit. Auto fit tries to fit the entire caption before falling back to pages.
  auto fits = [&] {
    if (metrics.width > layout_width - 2 * kPadding + 0.01f) return false;
    if (automatic) return metrics.height <= content_height;
    return read_lines() &&
           std::all_of(lines.begin(), lines.end(), [&](const auto& line) {
             return line.height <= content_height;
           });
  };
  const float minimum = std::min(font_size, kMinimumReadableFont);
  if (!fits() && font_size > minimum) {
    if (!measure(minimum, layout_width)) return false;
    if (fits()) {
      int low = static_cast<int>(minimum);
      int high = static_cast<int>(std::ceil(font_size)) - 1;
      while (low < high) {
        const int mid = low + (high - low + 1) / 2;
        if (!measure(static_cast<float>(mid), layout_width)) return false;
        if (fits()) {
          low = mid;
        } else {
          high = mid - 1;
        }
      }
      if (!measure(static_cast<float>(low), layout_width)) return false;
    }
  }

  if (!read_lines()) return false;
  std::vector<Page> pages{{0, 0}};
  float top = 0;
  for (const auto& line : lines) {
    if (line.height > content_height + 0.01f) return false;
    const auto last = pages.back();
    if (last.height > 0 && last.height + line.height > content_height) {
      pages.push_back({top, 0});
    }
    pages.back().height += line.height;
    top += line.height;
  }
  width_ = automatic ? std::min(width, std::ceil(metrics.width) + 2 * kPadding)
                     : width;
  height_ = automatic ? std::min(height, std::ceil(metrics.height) + 2 * kPadding)
                      : height;
  layout_ = std::move(layout);
  pages_ = std::move(pages);
  return true;
}

bool PairedSubtitleLayout::Draw(HDC dc, const RECT& bounds, UINT dpi,
                                COLORREF color, COLORREF background, int page) {
  if (!layout_ || page < 0 || page >= page_count()) return false;
  if (!drawing_factory_ &&
      FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                               drawing_factory_.GetAddressOf()))) {
    return false;
  }
  if (!target_) {
    const auto properties = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_SOFTWARE,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE));
    if (FAILED(drawing_factory_->CreateDCRenderTarget(&properties,
                                                       target_.GetAddressOf()))) {
      return false;
    }
  }
  target_->SetDpi(static_cast<float>(dpi), static_cast<float>(dpi));
  if (FAILED(target_->BindDC(dc, &bounds))) return false;
  target_->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush;
  if (FAILED(target_->CreateSolidColorBrush(ToColor(color), brush.GetAddressOf())))
    return false;
  const auto& view = pages_[page];
  const float right = static_cast<float>(bounds.right) * 96 / dpi;
  target_->BeginDraw();
  target_->Clear(ToColor(background));
  target_->PushAxisAlignedClip(
      D2D1::RectF(0, kPadding, right, kPadding + view.height),
      D2D1_ANTIALIAS_MODE_ALIASED);
  target_->DrawTextLayout(D2D1::Point2F(kPadding, kPadding - view.top),
                          layout_.Get(), brush.Get());
  target_->PopAxisAlignedClip();
  if (FAILED(target_->EndDraw())) {
    target_.Reset();
    return false;
  }
  return true;
}
