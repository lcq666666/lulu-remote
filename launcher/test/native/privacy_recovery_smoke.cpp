#include <windows.h>

#include <iostream>

#include "privacy_screen.h"

namespace {
constexpr wchar_t kCurtainClass[] = L"LuluRemotePrivacyPreview";
WPARAM dismissed_id = 0;

LRESULT CALLBACK Observe(HWND window, UINT msg, WPARAM w, LPARAM l) {
  if (msg == PrivacyScreen::kDismissedMessage) {
    dismissed_id = w;
    return 0;
  }
  return DefWindowProcW(window, msg, w, l);
}

HWND FindCurtain() {
  for (HWND window = nullptr;;) {
    window = FindWindowExW(nullptr, window, kCurtainClass, nullptr);
    if (!window) return nullptr;
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    if (pid == GetCurrentProcessId()) return window;
  }
}

bool CoversVirtualScreen(HWND window) {
  RECT rect{};
  return GetWindowRect(window, &rect) &&
      rect.left == GetSystemMetrics(SM_XVIRTUALSCREEN) &&
      rect.top == GetSystemMetrics(SM_YVIRTUALSCREEN) &&
      rect.right - rect.left == GetSystemMetrics(SM_CXVIRTUALSCREEN) &&
      rect.bottom - rect.top == GetSystemMetrics(SM_CYVIRTUALSCREEN);
}

bool DispatchDismissal(HWND owner) {
  MSG msg{};
  if (!PeekMessageW(&msg, owner, PrivacyScreen::kDismissedMessage,
                   PrivacyScreen::kDismissedMessage, PM_REMOVE)) return false;
  DispatchMessageW(&msg);
  return true;
}
}  // namespace

int main() {
  if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) return 1;
  WNDCLASSW klass{};
  klass.hInstance = GetModuleHandleW(nullptr);
  klass.lpfnWndProc = Observe;
  klass.lpszClassName = L"QGPrivacySmokeObserver";
  if (!RegisterClassW(&klass)) return 2;
  const HWND owner = CreateWindowW(klass.lpszClassName, L"", 0, 0, 0, 0, 0,
                                  nullptr, nullptr, klass.hInstance, nullptr);
  if (!owner) return 3;
  PrivacyScreen curtain;
  const auto preview = curtain.Show(owner, true, L"", false, 41);
  const HWND preview_window = FindCurtain();
  if (!preview || !preview->image_fallback || !IsWindowVisible(preview_window) ||
      !CoversVirtualScreen(preview_window)) return 4;
  SendMessageW(preview_window, WM_COMMAND, MAKEWPARAM(2, BN_CLICKED), 0);
  if (IsWindow(preview_window) || !DispatchDismissal(owner) || dismissed_id != 41) {
    return 5;
  }

  const auto active = curtain.Show(owner, false, L"", true, 42);
  const HWND live = FindCurtain();
  DWORD affinity = 0;
  if (!active || !IsWindowVisible(live) || !CoversVirtualScreen(live) ||
      !GetWindowDisplayAffinity(live, &affinity) ||
      affinity != WDA_EXCLUDEFROMCAPTURE || !curtain.Renew()) return 6;
  // Simulate geometry drift without sending WM_DISPLAYCHANGE. A successful
  // lease renewal must put the entire virtual desktop behind the curtain.
  if (!SetWindowPos(live, nullptr, 0, 0, 32, 32,
                    SWP_NOZORDER | SWP_NOACTIVATE) ||
      CoversVirtualScreen(live) || !curtain.Renew() ||
      !CoversVirtualScreen(live)) return 10;
  // Deliver the lease expiry directly instead of leaving a curtain visible
  // for eight seconds. A recovered session can retry with the same ID.
  SendMessageW(live, WM_TIMER, 1, 0);
  if (IsWindow(live) || curtain.Renew() || DispatchDismissal(owner) ||
      !curtain.Show(owner, false, L"", true, 42)) return 7;
  const HWND restored = FindCurtain();
  SendMessageW(restored, WM_HOTKEY, 1, 0);
  // Native code must reject a stale retry even before Dart sees the event.
  if (IsWindow(restored) || curtain.Show(owner, false, L"", true, 42) ||
      !DispatchDismissal(owner) || dismissed_id != 42) return 8;
  if (!curtain.Show(owner, false, L"", true, 43)) return 9;
  curtain.Hide();
  DestroyWindow(owner);
  CoUninitialize();
  std::cout << "Privacy curtain: preview fallback, geometry recovery, lease recovery and hotkey suppression passed\n";
  return 0;
}
