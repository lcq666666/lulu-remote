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

// An idle-only preview, not a capture-excluded live privacy curtain.
class PrivacyScreen {
 public:
  PrivacyScreen() = default;
  ~PrivacyScreen();
  PrivacyScreen(const PrivacyScreen&) = delete;
  PrivacyScreen& operator=(const PrivacyScreen&) = delete;

  static constexpr UINT kDismissedMessage = WM_APP + 3;

  std::optional<PrivacyPreview> ShowPreview(HWND owner, bool use_image,
                                  const std::wstring& path);
  void Hide(bool notify = false);

 private:
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                      LPARAM lparam);
  void Layout();
  LRESULT HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

  HWND window_ = nullptr;
  HWND owner_ = nullptr;
  HWND close_button_ = nullptr;
  HBITMAP bitmap_ = nullptr;
  bool hotkey_registered_ = false;
  SIZE image_size_{};
};

#endif  // RUNNER_PRIVACY_SCREEN_H_
