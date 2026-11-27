#include "privacy_screen.h"

#include <shobjidl.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <cstdint>

namespace {
using Microsoft::WRL::ComPtr;
constexpr wchar_t kPreviewClass[] = L"LuluRemotePrivacyPreview";
constexpr UINT_PTR kPreviewTimer = 1;
constexpr UINT kPreviewMilliseconds = 12000;
constexpr int kExitHotkey = 1;
constexpr int kCloseButton = 2;

bool ReadImage(const std::wstring& path, SIZE* size, HBITMAP* bitmap) {
  if (path.empty()) return false;
  ComPtr<IWICImagingFactory> wic;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic)))) {
    return false;
  }
  ComPtr<IWICBitmapDecoder> decoder;
  GUID format{};
  if (FAILED(wic->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ,
                                            WICDecodeMetadataCacheOnDemand,
                                            &decoder)) ||
      FAILED(decoder->GetContainerFormat(&format)) ||
      (format != GUID_ContainerFormatPng && format != GUID_ContainerFormatJpeg)) {
    return false;
  }
  ComPtr<IWICBitmapFrameDecode> frame;
  UINT width = 0, height = 0;
  if (FAILED(decoder->GetFrame(0, &frame)) ||
      FAILED(frame->GetSize(&width, &height)) || width == 0 || height == 0 ||
      // Bound the decoded buffer (and keep byte arithmetic below UINT_MAX).
      static_cast<std::uint64_t>(width) * height > 40000000) {
    return false;
  }
  *size = {static_cast<LONG>(width), static_cast<LONG>(height)};
  if (!bitmap) return true;

  ComPtr<IWICFormatConverter> converter;
  if (FAILED(wic->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppPBGRA,
                                   WICBitmapDitherTypeNone, nullptr, 0,
                                   WICBitmapPaletteTypeCustom))) {
    return false;
  }
  // Premultiplied RGB over the black background also handles transparent PNGs.
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(info.bmiHeader);
  info.bmiHeader.biWidth = size->cx;
  info.bmiHeader.biHeight = -size->cy;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* pixels = nullptr;
  HBITMAP image = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &pixels,
                                   nullptr, 0);
  if (!image) return false;
  if (FAILED(converter->CopyPixels(nullptr, width * 4, width * height * 4,
                                   static_cast<BYTE*>(pixels)))) {
    DeleteObject(image);
    return false;
  }
  *bitmap = image;
  return true;
}
}  // namespace

PrivacyImagePick PickPrivacyImage(HWND owner, PrivacyImageFile* selected) {
  ComPtr<IFileOpenDialog> dialog;
  if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&dialog)))) {
    return PrivacyImagePick::kInvalid;
  }
  const COMDLG_FILTERSPEC filters[] = {{L"JPG / PNG", L"*.jpg;*.jpeg;*.png"}};
  DWORD options = 0;
  if (FAILED(dialog->SetFileTypes(ARRAYSIZE(filters), filters)) ||
      FAILED(dialog->GetOptions(&options)) ||
      FAILED(dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST))) {
    return PrivacyImagePick::kInvalid;
  }
  const HRESULT shown = dialog->Show(owner);
  if (shown == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return PrivacyImagePick::kCancel;
  if (FAILED(shown)) return PrivacyImagePick::kInvalid;
  ComPtr<IShellItem> item;
  PWSTR raw_path = nullptr;
  if (FAILED(dialog->GetResult(&item)) ||
      FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &raw_path))) {
    return PrivacyImagePick::kInvalid;
  }
  selected->path = raw_path;
  CoTaskMemFree(raw_path);
  return ReadImage(selected->path, &selected->dimensions, nullptr)
      ? PrivacyImagePick::kSelected : PrivacyImagePick::kInvalid;
}

PrivacyScreen::~PrivacyScreen() { Hide(); }

std::optional<PrivacyPreview> PrivacyScreen::ShowPreview(HWND owner, bool use_image,
                                                const std::wstring& path) {
  if (window_) return std::nullopt;
  const auto instance = GetModuleHandleW(nullptr);
  WNDCLASSEXW klass{};
  klass.cbSize = sizeof(klass);
  klass.hInstance = instance;
  klass.lpfnWndProc = WindowProc;
  klass.hCursor = LoadCursor(nullptr, IDC_ARROW);
  klass.lpszClassName = kPreviewClass;
  if (!RegisterClassExW(&klass) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    return std::nullopt;
  }
  const bool fallback = use_image && !ReadImage(path, &image_size_, &bitmap_);
  window_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                            kPreviewClass, L"LULU Privacy Screen Preview",
                            WS_POPUP, 0, 0, 0, 0, nullptr, nullptr, instance, this);
  if (!window_) {
    Hide();
    return std::nullopt;
  }
  hotkey_registered_ = RegisterHotKey(
      window_, kExitHotkey, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, 'P') != FALSE;
  close_button_ = CreateWindowExW(
      0, L"BUTTON", hotkey_registered_ ? L"\u5173\u95ed\u9884\u89c8 (Ctrl+Alt+P)"
                                       : L"\u5173\u95ed\u9884\u89c8",
      WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0, window_,
      reinterpret_cast<HMENU>(static_cast<INT_PTR>(kCloseButton)), instance,
      nullptr);
  if (!close_button_ ||
      !SetTimer(window_, kPreviewTimer, kPreviewMilliseconds, nullptr)) {
    Hide();
    return std::nullopt;
  }
  SendMessageW(close_button_, WM_SETFONT,
               reinterpret_cast<WPARAM>(GetStockObject(DEFAULT_GUI_FONT)), TRUE);
  owner_ = owner;
  Layout();
  ShowWindow(window_, SW_SHOWNOACTIVATE);
  return PrivacyPreview{fallback, hotkey_registered_};
}

void PrivacyScreen::Hide(bool notify) {
  if (window_) {
    if (hotkey_registered_) UnregisterHotKey(window_, kExitHotkey);
    hotkey_registered_ = false;
    KillTimer(window_, kPreviewTimer);
    DestroyWindow(window_);
    window_ = nullptr;
    close_button_ = nullptr;
  }
  if (bitmap_) {
    DeleteObject(bitmap_);
    bitmap_ = nullptr;
  }
  if (owner_) {
    if (notify) PostMessageW(owner_, kDismissedMessage, 0, 0);
    owner_ = nullptr;
  }
}

void PrivacyScreen::Layout() {
  const int x = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int y = GetSystemMetrics(SM_YVIRTUALSCREEN);
  SetWindowPos(window_, HWND_TOPMOST, x, y,
               GetSystemMetrics(SM_CXVIRTUALSCREEN),
               GetSystemMetrics(SM_CYVIRTUALSCREEN), SWP_NOACTIVATE);
  const UINT dpi = GetDpiForWindow(window_);
  const int width = MulDiv(180, dpi, 96);
  const int height = MulDiv(32, dpi, 96);
  // Screen coordinates (0, 0) are the primary monitor's top-left corner.
  const int margin = MulDiv(16, dpi, 96);
  MoveWindow(close_button_, margin - x, margin - y, width, height, TRUE);
  InvalidateRect(window_, nullptr, FALSE);
}

LRESULT CALLBACK PrivacyScreen::WindowProc(HWND window, UINT message,
                                            WPARAM wparam, LPARAM lparam) {
  if (message == WM_NCCREATE) {
    const auto* data = reinterpret_cast<const CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(data->lpCreateParams));
  }
  auto* screen = reinterpret_cast<PrivacyScreen*>(
      GetWindowLongPtrW(window, GWLP_USERDATA));
  return screen && screen->window_
      ? screen->HandleMessage(message, wparam, lparam)
      : DefWindowProcW(window, message, wparam, lparam);
}

LRESULT PrivacyScreen::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_CLOSE:
      return 0;
    case WM_DISPLAYCHANGE:
      Layout();
      return 0;
    case WM_HOTKEY:
      if (wparam == kExitHotkey) Hide(true);
      return 0;
    case WM_TIMER:
      if (wparam == kPreviewTimer) Hide(true);
      return 0;
    case WM_COMMAND:
      if (LOWORD(wparam) == kCloseButton && HIWORD(wparam) == BN_CLICKED) Hide(true);
      return 0;
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      HDC dc = BeginPaint(window_, &paint);
      RECT rect{};
      GetClientRect(window_, &rect);
      FillRect(dc, &rect, static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
      if (bitmap_) {
        HDC image_dc = CreateCompatibleDC(dc);
        if (image_dc) {
          const auto old = SelectObject(image_dc, bitmap_);
          SetStretchBltMode(dc, HALFTONE);
          SetBrushOrgEx(dc, 0, 0, nullptr);
          StretchBlt(dc, 0, 0, rect.right, rect.bottom, image_dc, 0, 0,
                     image_size_.cx, image_size_.cy, SRCCOPY);
          SelectObject(image_dc, old);
          DeleteDC(image_dc);
        }
      }
      EndPaint(window_, &paint);
      return 0;
    }
  }
  return DefWindowProcW(window_, message, wparam, lparam);
}
