// Interactive Windows smoke test. No desktop images are saved.
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <windows.h>
#include <d3d11.h>
#include <dwmapi.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <cstdint>
#include <iostream>
#include <limits>
#include <vector>

#include "privacy_screen.h"

namespace {
using Microsoft::WRL::ComPtr;
constexpr std::uint32_t kTestPixel = 0x00ab6319;
constexpr std::uint32_t kUnderCurtainPixel = 0x003978ac;
constexpr std::uint32_t kUnread = std::numeric_limits<std::uint32_t>::max();
constexpr UINT kSample = 128;
std::uint32_t test_pixel = kTestPixel;

LRESULT CALLBACK PatternWindow(HWND w, UINT msg, WPARAM p, LPARAM l) {
  if (msg == WM_PAINT) {
    PAINTSTRUCT paint{};
    const auto dc = BeginPaint(w, &paint);
    const auto brush = CreateSolidBrush(RGB(
        (test_pixel >> 16) & 0xff, (test_pixel >> 8) & 0xff, test_pixel & 0xff));
    FillRect(dc, &paint.rcPaint, brush);
    DeleteObject(brush);
    EndPaint(w, &paint);
    return 0;
  }
  return DefWindowProcW(w, msg, p, l);
}

void Pump() {
  MSG msg{};
  while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
  DwmFlush();
}

std::uint32_t ReadPixel(ID3D11Device* device, ID3D11DeviceContext* context,
                        ID3D11Texture2D* texture) {
  D3D11_TEXTURE2D_DESC desc{};
  texture->GetDesc(&desc);
  if (desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM ||
      desc.Width <= kSample || desc.Height <= kSample) {
    return kUnread;
  }
  desc.Width = desc.Height = 1;
  desc.Usage = D3D11_USAGE_STAGING;
  desc.BindFlags = desc.MiscFlags = 0;
  desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  ComPtr<ID3D11Texture2D> sample;
  if (FAILED(device->CreateTexture2D(&desc, nullptr, &sample))) return kUnread;
  const D3D11_BOX box{kSample, kSample, 0, kSample + 1, kSample + 1, 1};
  context->CopySubresourceRegion(sample.Get(), 0, 0, 0, 0, texture, 0, &box);
  D3D11_MAPPED_SUBRESOURCE map{};
  if (FAILED(context->Map(sample.Get(), 0, D3D11_MAP_READ, 0, &map))) {
    return kUnread;
  }
  const auto result = *static_cast<const std::uint32_t*>(map.pData) & 0xffffff;
  context->Unmap(sample.Get(), 0);
  return result;
}

struct WgcProbe {
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool pool{nullptr};
  winrt::Windows::Graphics::Capture::GraphicsCaptureSession session{nullptr};

  HRESULT Start(HMONITOR monitor) {
    using namespace winrt::Windows::Graphics;
    using winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;
    using winrt::Windows::Graphics::DirectX::DirectXPixelFormat;
    try {
      const auto factory = winrt::get_activation_factory<
          Capture::GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
      Capture::GraphicsCaptureItem item{nullptr};
      winrt::check_hresult(factory->CreateForMonitor(monitor,
          winrt::guid_of<Capture::GraphicsCaptureItem>(), winrt::put_abi(item)));
      winrt::check_hresult(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE,
          nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
          D3D11_SDK_VERSION, &device, nullptr, &context));
      ComPtr<IDXGIDevice> dxgi;
      winrt::check_hresult(device.As(&dxgi));
      winrt::com_ptr<IInspectable> inspectable;
      winrt::check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi.Get(),
          inspectable.put()));
      pool = Capture::Direct3D11CaptureFramePool::CreateFreeThreaded(
          inspectable.as<IDirect3DDevice>(),
          DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, item.Size());
      session = pool.CreateCaptureSession(item);
      session.IsCursorCaptureEnabled(false);
      session.StartCapture();
      return S_OK;
    } catch (const winrt::hresult_error& e) {
      return e.code();
    }
  }

  std::uint32_t Pixel() const {
    using Frame = winrt::Windows::Graphics::Capture::Direct3D11CaptureFrame;
    Frame frame{nullptr};
    for (int retry = 0; retry < 30 && !frame; ++retry) {
      frame = pool.TryGetNextFrame();
      if (!frame) Sleep(8);
    }
    if (!frame) return kUnread;
    const auto resource = frame.Surface().as<
        ::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
    auto result = kUnread;
    ComPtr<ID3D11Texture2D> texture;
    if (SUCCEEDED(resource->GetInterface(IID_PPV_ARGS(&texture)))) {
      result = ReadPixel(device.Get(), context.Get(), texture.Get());
    }
    frame.Close();
    return result;
  }
};

struct DxgiProbe {
  ComPtr<IDXGIOutputDuplication> duplication;
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  HRESULT Start(HMONITOR monitor) {
    ComPtr<IDXGIFactory1> factory;
    HRESULT error = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
    if (FAILED(error)) return error;
    ComPtr<IDXGIAdapter1> adapter;
    for (UINT i = 0; SUCCEEDED(factory->EnumAdapters1(i, &adapter));
         ++i, adapter.Reset()) {
      ComPtr<IDXGIOutput> output;
      for (UINT j = 0; SUCCEEDED(adapter->EnumOutputs(j, &output));
           ++j, output.Reset()) {
        DXGI_OUTPUT_DESC desc{};
        if (FAILED(output->GetDesc(&desc)) || !desc.AttachedToDesktop ||
            desc.Monitor != monitor) {
          continue;
        }
        error = D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN,
            nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
            D3D11_SDK_VERSION, &device, nullptr, &context);
        if (FAILED(error)) return error;
        ComPtr<IDXGIOutput1> output1;
        error = output.As(&output1);
        if (FAILED(error)) return error;
        return output1->DuplicateOutput(device.Get(), &duplication);
      }
    }
    return DXGI_ERROR_NOT_FOUND;
  }

  std::uint32_t Pixel() const {
    ComPtr<IDXGIResource> resource;
    DXGI_OUTDUPL_FRAME_INFO frame{};
    const auto error = duplication->AcquireNextFrame(150, &frame, &resource);
    if (FAILED(error)) return kUnread;
    auto result = kUnread;
    ComPtr<ID3D11Texture2D> texture;
    if (SUCCEEDED(resource.As(&texture))) {
      result = ReadPixel(device.Get(), context.Get(), texture.Get());
    }
    duplication->ReleaseFrame();
    return result;
  }
};

template <typename Probe>
bool WaitPixel(const Probe& probe, std::uint32_t expected, HWND pattern) {
  for (int attempt = 0; attempt < 12; ++attempt) {
    InvalidateRect(pattern, nullptr, FALSE);
    UpdateWindow(pattern);
    Pump();
    if (probe.Pixel() == expected) return true;
  }
  return false;
}

template <typename Probe>
bool CheckCapture(const char* api, HMONITOR monitor, HWND pattern) {
  Probe probe;
  const HRESULT started = probe.Start(monitor);
  if (FAILED(started)) {
    std::cerr << api << ": cannot start capture (0x" << std::hex << started
              << std::dec << ")\n";
    return false;
  }
  test_pixel = kTestPixel;
  if (!WaitPixel(probe, kTestPixel, pattern)) {
    std::cerr << api << ": no visible baseline; use an unlocked SDR desktop\n";
    return false;
  }
  PrivacyScreen curtain;
  if (!curtain.Show(pattern, false, L"", false, 1) ||
      !WaitPixel(probe, 0, pattern)) {
    std::cerr << api << ": preview did not replace the test pattern\n";
    return false;
  }
  curtain.Hide();
  if (!curtain.Show(pattern, false, L"", true, 2)) {
    std::cerr << api << ": live curtain unavailable\n";
    return false;
  }
  // Paint a different color only after the live curtain appears. A frame
  // queued before the window was shown must not count as successful capture.
  test_pixel = kUnderCurtainPixel;
  if (!WaitPixel(probe, kUnderCurtainPixel, pattern)) {
    std::cerr << api << ": updated pattern not visible through live curtain\n";
    return false;
  }
  std::cout << api << ": preview captured black; live captured updated pattern\n";
  return true;
}

BOOL CALLBACK CollectMonitor(HMONITOR monitor, HDC, LPRECT, LPARAM param) {
  reinterpret_cast<std::vector<HMONITOR>*>(param)->push_back(monitor);
  return TRUE;
}
}  // namespace

int main() {
  winrt::init_apartment(winrt::apartment_type::single_threaded);
  WNDCLASSW klass{};
  klass.hInstance = GetModuleHandleW(nullptr);
  klass.lpfnWndProc = PatternWindow;
  klass.lpszClassName = L"QGPrivacyCaptureSmokePattern";
  if (!RegisterClassW(&klass)) return 1;
  std::vector<HMONITOR> monitors;
  if (!EnumDisplayMonitors(nullptr, nullptr, CollectMonitor,
          reinterpret_cast<LPARAM>(&monitors)) || monitors.empty()) return 2;
  bool passed = true;
  size_t index = 0;
  for (const auto monitor : monitors) {
    MONITORINFO info{};
    info.cbSize = sizeof(info);
    if (!GetMonitorInfoW(monitor, &info)) return 3;
    const auto pattern = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, klass.lpszClassName,
        L"", WS_POPUP, info.rcMonitor.left + 96, info.rcMonitor.top + 96,
        128, 128, nullptr, nullptr, klass.hInstance, nullptr);
    if (!pattern) return 4;
    SetWindowPos(pattern, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    std::cout << "Monitor " << ++index << '/' << monitors.size() << '\n';
    passed = CheckCapture<WgcProbe>("WGC", monitor, pattern) && passed;
    passed = CheckCapture<DxgiProbe>("DXGI", monitor, pattern) && passed;
    DestroyWindow(pattern);
  }
  winrt::uninit_apartment();
  return passed ? 0 : 5;
}
