#ifndef RUNNER_PRIVACY_SCREEN_H_
#define RUNNER_PRIVACY_SCREEN_H_

#include <windows.h>

#include <optional>
#include <string>

struct PrivacyImageFile {
  std::wstring path;
  SIZE dimensions;
};

struct PrivacyPreview {
  bool image_fallback;
  bool hotkey_available;
};

enum class PrivacyImagePick { kCancel, kInvalid, kSelected };
PrivacyImagePick PickPrivacyImage(HWND owner, PrivacyImageFile* selected);

class PrivacyScreen {
 public:
  PrivacyScreen() = default;
  ~PrivacyScreen();
  PrivacyScreen(const PrivacyScreen&) = delete;
  PrivacyScreen& operator=(const PrivacyScreen&) = delete;

  static constexpr UINT kDismissedMessage = WM_APP + 3;

  std::optional<PrivacyPreview> Show(HWND owner, bool use_image,
                                     const std::wstring& path, bool live, int request_id);
  bool Renew();
  void Hide(bool notify = false);

 private:
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                      LPARAM lparam);
  static LRESULT CALLBACK KeyboardHook(int code, WPARAM wparam, LPARAM lparam);
  static LRESULT CALLBACK MouseHook(int code, WPARAM wparam, LPARAM lparam);
  bool PrepareLive(HINSTANCE instance);
  void Layout();
  void DismissByUser();
  LRESULT HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

  HWND window_ = nullptr;
  HWND owner_ = nullptr;
  int request_id_ = 0;
  int dismissed_live_id_ = 0;
  HWND close_button_ = nullptr;
  HBITMAP bitmap_ = nullptr;
  static PrivacyScreen* input_owner_;
  HHOOK keyboard_hook_ = nullptr;
  HHOOK mouse_hook_ = nullptr;
  bool physical_keys_[256]{};
  bool hotkey_registered_ = false;
  bool live_ = false;
  SIZE image_size_{};
};

#endif  // RUNNER_PRIVACY_SCREEN_H_
