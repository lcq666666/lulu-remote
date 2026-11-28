#ifndef RUNNER_MOONLIGHT_SHORTCUT_H_
#define RUNNER_MOONLIGHT_SHORTCUT_H_

#include <string>
#include <vector>

// Read the target of an existing local Shell Link. No invocation, repair,
// network resolution, or use of shortcut arguments takes place.
std::wstring LocalMoonlightShortcutTarget(const std::wstring& shortcut);
std::vector<std::wstring> MoonlightStartMenuTargets();

#endif  // RUNNER_MOONLIGHT_SHORTCUT_H_
