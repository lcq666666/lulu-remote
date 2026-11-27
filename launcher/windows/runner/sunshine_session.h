#ifndef RUNNER_SUNSHINE_SESSION_H_
#define RUNNER_SUNSHINE_SESSION_H_

#include <optional>

// true = stream transport allocated, false = idle, nullopt = query failed.
std::optional<bool> SunshineStreaming();

#endif  // RUNNER_SUNSHINE_SESSION_H_
