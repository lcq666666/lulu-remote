#include "flutter_window.h"

#include <shellapi.h>
#include <wincred.h>

#include <optional>
#include <string>

#include "resource.h"

#include "flutter/generated_plugin_registrant.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kShowMessage = WM_APP + 2;
constexpr wchar_t kCredentialName[] = L"LULU Remote/Sunshine host";

NOTIFYICONDATAW TrayIcon(HWND window) {
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = window;
  icon.uID = 1;
  return icon;
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project, bool start_in_tray)
    : start_in_tray_(start_in_tray), project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  taskbar_created_ = ::RegisterWindowMessageW(L"TaskbarCreated");
  tray_added_ = AddTrayIcon();
  tray_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "lulu/host_tray",
      &flutter::StandardMethodCodec::GetInstance());
  tray_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleTrayCall(call, std::move(result));
  });
  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    if (!start_in_tray_ || !tray_added_) Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (tray_channel_) {
    tray_channel_->SetMethodCallHandler(nullptr);
    tray_channel_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_DESTROY && tray_added_) {
    auto icon = TrayIcon(hwnd);
    ::Shell_NotifyIconW(NIM_DELETE, &icon);
    tray_added_ = false;
  }
  if (message == kShowMessage) {
    ShowApp();
    return 0;
  }
  if (message == taskbar_created_ && taskbar_created_ != 0) {
    tray_added_ = AddTrayIcon();
    if (!tray_added_) ShowApp();
    return 0;
  }
  if (message == WM_CLOSE && tray_added_) {
    ::ShowWindow(hwnd, SW_HIDE);
    if (prompt_open_) tray_channel_->InvokeMethod("dismissPrompt", nullptr);
    return 0;
  }
  if (message == kTrayMessage) {
    if (lparam == WM_LBUTTONUP) ShowApp();
    if (lparam == WM_RBUTTONUP) {
      const HMENU menu = ::CreatePopupMenu();
      if (!menu) return 0;
      ::AppendMenuW(menu, MF_STRING, 1, L"\u6253\u5f00 LULU");
      ::AppendMenuW(menu, MF_STRING, 2, L"\u9000\u51fa");
      POINT cursor{};
      ::GetCursorPos(&cursor);
      ::SetForegroundWindow(hwnd);
      const auto choice = ::TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
          cursor.x, cursor.y, 0, hwnd, nullptr);
      ::DestroyMenu(menu);
      ::PostMessageW(hwnd, WM_NULL, 0, 0);
      if (choice == 1) ShowApp();
      if (choice == 2) ::DestroyWindow(hwnd);
    }
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}


bool FlutterWindow::AddTrayIcon() {
  auto icon = TrayIcon(GetHandle());
  icon.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  icon.uCallbackMessage = kTrayMessage;
  icon.hIcon = ::LoadIconW(::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  wcscpy_s(icon.szTip, L"LULU Remote");
  return ::Shell_NotifyIconW(NIM_ADD, &icon) != FALSE;
}

void FlutterWindow::ShowApp() {
  ::ShowWindow(GetHandle(), SW_RESTORE);
  ::SetForegroundWindow(GetHandle());
}

void FlutterWindow::HandleTrayCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto& method = call.method_name();
  if (method == "notify") {
    auto icon = TrayIcon(GetHandle());
    icon.uFlags = NIF_INFO;
    icon.dwInfoFlags = NIIF_INFO;
    wcscpy_s(icon.szInfoTitle, L"LULU Remote");
    wcscpy_s(icon.szInfo, L"\u6709\u8bbe\u5907\u6b63\u5728\u8bf7\u6c42\u8fde\u63a5");
    result->Success(flutter::EncodableValue(
        ::Shell_NotifyIconW(NIM_MODIFY, &icon) != FALSE));
  } else if (method == "show" || method == "showPrompt") {
    const bool was_hidden = !::IsWindowVisible(GetHandle()) || ::IsIconic(GetHandle());
    ShowApp();
    if (method == "showPrompt") {
      prompt_open_ = true;
      ::SetWindowPos(GetHandle(), HWND_TOPMOST, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE);
    }
    result->Success(flutter::EncodableValue(was_hidden));
  } else if (method == "finishPrompt") {
    const auto* hide = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
    prompt_open_ = false;
    ::SetWindowPos(GetHandle(), HWND_NOTOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    if (hide && *hide && tray_added_) ::ShowWindow(GetHandle(), SW_HIDE);
    result->Success();
  } else if (method == "readCredential") {
    PCREDENTIALW credential = nullptr;
    if (!::CredReadW(kCredentialName, CRED_TYPE_GENERIC, 0, &credential)) {
      if (::GetLastError() == ERROR_NOT_FOUND) result->Success();
      else result->Error("credential_read");
      return;
    }
    const std::string data(reinterpret_cast<const char*>(credential->CredentialBlob),
                           credential->CredentialBlobSize);
    ::CredFree(credential);
    result->Success(flutter::EncodableValue(data));
  } else if (method == "writeCredential") {
    const auto* data = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
    if (!data || data->empty() || data->size() > CRED_MAX_CREDENTIAL_BLOB_SIZE) {
      result->Error("credential_size");
      return;
    }
    wchar_t target[] = L"LULU Remote/Sunshine host";
    CREDENTIALW credential{};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = target;
    credential.CredentialBlob = reinterpret_cast<LPBYTE>(const_cast<char*>(data->data()));
    credential.CredentialBlobSize = static_cast<DWORD>(data->size());
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    if (!::CredWriteW(&credential, 0)) {
      result->Error("credential_write");
      return;
    }
    result->Success();
  } else {
    result->NotImplemented();
  }
}
