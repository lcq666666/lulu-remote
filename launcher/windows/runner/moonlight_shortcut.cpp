#include "moonlight_shortcut.h"

#include <windows.h>

#include <shlobj.h>
#include <wrl/client.h>

#include <array>
#include <utility>

namespace {
using Microsoft::WRL::ComPtr;
constexpr wchar_t kMoonlightLink[] =
    L"\\Moonlight Game Streaming\\Moonlight.lnk";

bool IsLocalDrivePath(const std::wstring& path) {
  if (path.size() < 4 || path[1] != L':' || path[2] != L'\\' ||
      !((path[0] >= L'A' && path[0] <= L'Z') ||
        (path[0] >= L'a' && path[0] <= L'z'))) {
    return false;
  }
  const auto type = GetDriveTypeW(path.substr(0, 3).c_str());
  return type == DRIVE_FIXED || type == DRIVE_REMOVABLE;
}

bool IsLocalFile(const std::wstring& path) {
  if (!IsLocalDrivePath(path)) return false;
  // Reject reparse points in parent directories as well as the file itself.
  // A junction on a fixed drive can otherwise redirect us to another target.
  size_t start = 3;
  while (start < path.size()) {
    const auto end = path.find(L'\\', start);
    const auto name = path.substr(start, end == std::wstring::npos
                                            ? std::wstring::npos : end - start);
    if (name.empty() || name == L"." || name == L".." ||
        name.find_first_of(L"/:") != std::wstring::npos) return false;
    const auto attributes = GetFileAttributesW(path.substr(0, end).c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) return false;
    if (end == std::wstring::npos) return !(attributes & FILE_ATTRIBUTE_DIRECTORY);
    if (!(attributes & FILE_ATTRIBUTE_DIRECTORY)) return false;
    start = end + 1;
  }
  return false;
}
}  // namespace

std::wstring LocalMoonlightShortcutTarget(const std::wstring& shortcut) {
  if (!IsLocalFile(shortcut)) return {};
  ComPtr<IShellLinkW> link;
  if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&link)))) return {};
  ComPtr<IPersistFile> storage;
  if (FAILED(link.As(&storage)) ||
      FAILED(storage->Load(shortcut.c_str(), STGM_READ))) return {};

  // RAWPATH reads the recorded target, without trying to find a missing
  // object. Official Moonlight links store an absolute local executable path.
  std::array<wchar_t, 32768> target{};
  if (link->GetPath(target.data(), static_cast<int>(target.size()), nullptr,
                    SLGP_RAWPATH) != S_OK) return {};
  const std::wstring path(target.data());
  const auto last_separator = path.find_last_of(L"\\/");
  if (last_separator == std::wstring::npos ||
      CompareStringOrdinal(path.c_str() + last_separator + 1, -1,
                           L"Moonlight.exe", -1, TRUE) != CSTR_EQUAL ||
      !IsLocalFile(path)) return {};
  return path;
}

std::vector<std::wstring> MoonlightStartMenuTargets() {
  std::vector<std::wstring> paths;
  for (const auto* folder : {&FOLDERID_CommonPrograms, &FOLDERID_Programs}) {
    PWSTR location = nullptr;
    if (SUCCEEDED(SHGetKnownFolderPath(*folder, KF_FLAG_DONT_VERIFY, nullptr,
                                       &location)) && location) {
      auto path = LocalMoonlightShortcutTarget(std::wstring(location) + kMoonlightLink);
      if (!path.empty()) paths.push_back(std::move(path));
    }
    CoTaskMemFree(location);
  }
  return paths;
}
