#include <windows.h>

#include <shlobj.h>
#include <wrl/client.h>

#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

#include "moonlight_shortcut.h"

namespace {
using Microsoft::WRL::ComPtr;

bool SaveLink(const std::filesystem::path& link_path,
              const std::filesystem::path& target) {
  ComPtr<IShellLinkW> link;
  ComPtr<IPersistFile> storage;
  return SUCCEEDED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(&link))) &&
         SUCCEEDED(link->SetPath(target.c_str())) &&
         SUCCEEDED(link->SetArguments(L"unexpected-shortcut-argument")) &&
         SUCCEEDED(link.As(&storage)) &&
         SUCCEEDED(storage->Save(link_path.c_str(), TRUE));
}

int CheckLinks() {
  const auto dir = std::filesystem::current_path() / L"Moonlight \u5b89\u88c5\u76ee\u5f55";
  std::filesystem::create_directories(dir);
  const auto expected = dir / L"Moonlight.exe";
  const auto wrong = dir / L"other.exe";
  const auto link = dir / L"test.lnk";
  std::ofstream(expected) << "not an executable; detection must not invoke it";
  std::ofstream(wrong) << "wrong basename";
  const auto matches = LocalMoonlightShortcutTarget(link.wstring());
  if (!matches.empty()) return 2;
  if (!SaveLink(link, expected) ||
      LocalMoonlightShortcutTarget(link.wstring()) != expected.wstring()) return 3;
  std::filesystem::remove(expected);
  if (!LocalMoonlightShortcutTarget(link.wstring()).empty()) return 4;
  if (!SaveLink(link, wrong) ||
      !LocalMoonlightShortcutTarget(link.wstring()).empty()) return 5;
  return 0;
}
}  // namespace

int main() {
  if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) return 1;
  const auto result = CheckLinks();
  if (result == 0) {
    std::cout << "Custom Unicode path, missing target and wrong basename passed. "
              << "Stock local Start Menu matches: "
              << MoonlightStartMenuTargets().size() << "\n";
  }
  CoUninitialize();
  return result;
}
