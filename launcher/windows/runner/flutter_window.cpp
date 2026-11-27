#include "flutter_window.h"

#include <shlobj.h>

#include <shellapi.h>
#include <wincred.h>

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

#include "resource.h"
#include "sunshine_session.h"
#include "utils.h"

#include "flutter/generated_plugin_registrant.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kShowMessage = WM_APP + 2;
constexpr wchar_t kCredentialName[] = L"LULU Remote/Sunshine host";

struct StreamWindowSearch {
  DWORD process_id;
  HWND window = nullptr;
};

BOOL CALLBACK FindStreamWindow(HWND window, LPARAM context) {
  auto* search = reinterpret_cast<StreamWindowSearch*>(context);
  DWORD owner = 0;
  ::GetWindowThreadProcessId(window, &owner);
  if (owner != search->process_id || !::IsWindowVisible(window)) return TRUE;
  wchar_t window_class[32] = {};
  wchar_t title[512] = {};
  ::GetClassNameW(window, window_class, ARRAYSIZE(window_class));
  const int length = ::GetWindowTextW(window, title, ARRAYSIZE(title));
  constexpr std::wstring_view suffix = L" - Moonlight";
  const std::wstring_view text(title, static_cast<size_t>(length));
  if (std::wstring_view(window_class) != L"SDL_app" ||
      text.size() < suffix.size() ||
      text.substr(text.size() - suffix.size()) != suffix) return TRUE;
  search->window = window;
  return FALSE;
}

// Return false before injecting any input so the initial switch can retry
// when the newly launched stream becomes ready and takes focus.
bool SwitchStreamMonitor(DWORD process_id, int screen, bool focus) {
  StreamWindowSearch search{process_id};
  ::EnumWindows(FindStreamWindow, reinterpret_cast<LPARAM>(&search));
  if (!search.window) return false;
  if (focus && ::GetForegroundWindow() != search.window) {
    if (::IsIconic(search.window)) ::ShowWindow(search.window, SW_RESTORE);
    ::SetForegroundWindow(search.window);
  }
  constexpr WORD modifiers[] = {VK_LCONTROL, VK_LMENU, VK_LSHIFT};
  for (const int modifier : {VK_CONTROL, VK_MENU, VK_SHIFT, VK_LWIN, VK_RWIN}) {
    if (::GetAsyncKeyState(modifier) & 0x8000) return false;
  }
  if (::GetForegroundWindow() != search.window) return false;
  const WORD keys[] = {modifiers[0], modifiers[1], modifiers[2],
                       static_cast<WORD>(VK_F1 + screen - 1)};
  INPUT input[8]{};
  for (size_t i = 0; i < ARRAYSIZE(keys); ++i) {
    input[i].type = INPUT_KEYBOARD;
    input[i].ki.wVk = keys[i];
    input[7 - i] = input[i];
    input[7 - i].ki.dwFlags = KEYEVENTF_KEYUP;
  }
  const UINT sent = ::SendInput(ARRAYSIZE(input), input, sizeof(INPUT));
  if (sent > 0 && sent < ARRAYSIZE(input)) {
    ::SendInput(4, input + 4, sizeof(INPUT));
  }
  return sent == ARRAYSIZE(input);
}

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
  privacy_screen_.Hide();
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
  if (message == PrivacyScreen::kDismissedMessage) {
    if (tray_channel_) {
      tray_channel_->InvokeMethod("privacyScreenDismissed",
          std::make_unique<flutter::EncodableValue>(static_cast<int32_t>(wparam)));
    }
    return 0;
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
      ::AppendMenuW(menu, MF_STRING, 1, L"\u6253\u5f00\u5F3A\u54E5\u8FDC\u7A0B");
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
  wcscpy_s(icon.szTip, L"\u5F3A\u54E5\u8FDC\u7A0B");
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
  if (method == "switchStreamMonitor") {
    const auto* args = call.arguments()
        ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
    const auto get = [args](const char* key) -> const flutter::EncodableValue* {
      if (!args) return nullptr;
      const auto entry = args->find(flutter::EncodableValue(key));
      return entry == args->end() ? nullptr : &entry->second;
    };
    const auto* pid = std::get_if<int32_t>(get("pid"));
    const auto* screen = std::get_if<int32_t>(get("screen"));
    const auto* focus = std::get_if<bool>(get("focus"));
    if (!pid || *pid <= 0 || !screen || *screen < 1 || *screen > 12 || !focus) {
      result->Error("stream_monitor_arguments");
      return;
    }
    result->Success(flutter::EncodableValue(
        SwitchStreamMonitor(static_cast<DWORD>(*pid), *screen, *focus)));
  } else if (method == "sunshineStreaming") {
    const auto streaming = SunshineStreaming();
    if (streaming) result->Success(flutter::EncodableValue(*streaming));
    else result->Success();
  } else if (method == "lockAfterStream") {
    // Do not lock if another stream started while Dart was reading settings.
    // The tray runner lives in the interactive user's Windows session, and
    // can call the supported API directly (no rundll32 signature mismatch).
    if (SunshineStreaming() == std::optional<bool>(false)) {
      ::LockWorkStation();
    }
    result->Success();
  } else if (method == "knownDesktop") {
    PWSTR path = nullptr;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_Desktop, 0, nullptr, &path))) {
      CoTaskMemFree(path);
      result->Error("desktop_folder");
      return;
    }
    const auto location = Utf8FromUtf16(path);
    CoTaskMemFree(path);
    result->Success(flutter::EncodableValue(location));
  } else if (method == "pickPrivacyImage") {
    PrivacyImageFile image{};
    const auto picked = PickPrivacyImage(GetHandle(), &image);
    if (picked == PrivacyImagePick::kCancel) {
      result->Success();
    } else if (picked == PrivacyImagePick::kInvalid) {
      result->Error("privacy_image");
    } else {
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("path"),
           flutter::EncodableValue(Utf8FromUtf16(image.path.c_str()))},
          {flutter::EncodableValue("width"),
           flutter::EncodableValue(static_cast<int>(image.dimensions.cx))},
          {flutter::EncodableValue("height"),
           flutter::EncodableValue(static_cast<int>(image.dimensions.cy))},
      }));
    }
  } else if (method == "showPrivacyScreen") {
    const auto* args = call.arguments() ?
        std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
    if (!args) {
      result->Error("privacy_arguments");
      return;
    }
    const auto live_entry = args->find(flutter::EncodableValue("live"));
    const auto* live_argument = live_entry == args->end() ? nullptr :
        std::get_if<bool>(&live_entry->second);
    const bool live = live_argument && *live_argument;
    if (SunshineStreaming() != std::optional<bool>(live)) {
      result->Error("privacy_streaming");
      return;
    }
    const auto mode_entry = args->find(flutter::EncodableValue("mode"));
    const auto* mode = mode_entry == args->end() ? nullptr :
        std::get_if<std::string>(&mode_entry->second);
    if (!mode || (*mode != "black" && *mode != "image")) {
      result->Error("privacy_mode");
      return;
    }
    const auto image_entry = args->find(flutter::EncodableValue("image"));
    const auto* image = image_entry == args->end() ? nullptr :
        std::get_if<std::string>(&image_entry->second);
    const auto id_entry = args->find(flutter::EncodableValue("id"));
    const auto* request_id = id_entry == args->end() ? nullptr :
        std::get_if<int32_t>(&id_entry->second);
    if (!request_id || *request_id <= 0) {
      result->Error("privacy_arguments");
      return;
    }
    const auto preview = privacy_screen_.Show(
        GetHandle(), *mode == "image", image ? Utf16FromUtf8(*image) : L"",
        live, *request_id);
    if (preview) {
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("imageFallback"),
           flutter::EncodableValue(preview->image_fallback)},
          {flutter::EncodableValue("hotkeyAvailable"),
           flutter::EncodableValue(preview->hotkey_available)},
      }));
    } else {
      result->Error("privacy_preview");
    }
  } else if (method == "renewPrivacyScreen") {
    if (privacy_screen_.Renew()) result->Success();
    else result->Error("privacy_lease");
  } else if (method == "hidePrivacyScreen") {
    privacy_screen_.Hide();
    result->Success();
  } else if (method == "notify") {
    auto icon = TrayIcon(GetHandle());
    icon.uFlags = NIF_INFO;
    icon.dwInfoFlags = NIIF_INFO;
    wcscpy_s(icon.szInfoTitle, L"\u5F3A\u54E5\u8FDC\u7A0B");
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
