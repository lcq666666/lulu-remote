#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <tlhelp32.h>

#include <cstdint>
#include <set>
#include <utility>
#include <vector>

#include "sunshine_session.h"

namespace {
using Ports = std::set<std::pair<DWORD, unsigned>>;

// Use a TCP *listener* solely to identify the base port. Established TCP
// requests (including RTSP) are short-lived and do not track the stream.
constexpr unsigned kRtspOffset = 21;
constexpr unsigned kVideoOffset = 9;
constexpr unsigned kControlOffset = 10;
constexpr unsigned kAudioOffset = 11;

unsigned Port(DWORD network_port) {
  return ntohs(static_cast<u_short>(network_port));
}

// IP Helper reports the required size, which can grow again between calls.
template <typename Read>
std::vector<std::uint8_t> ReadTable(Read read) {
  ULONG size = 0;
  if (read(nullptr, &size) != ERROR_INSUFFICIENT_BUFFER) return {};
  for (int attempt = 0; attempt < 3 && size != 0; ++attempt) {
    std::vector<std::uint8_t> buffer(size);
    const DWORD error = read(buffer.data(), &size);
    if (error == NO_ERROR) return buffer;
    if (error != ERROR_INSUFFICIENT_BUFFER) break;
  }
  return {};
}

template <typename Table>
void AddPorts(const std::vector<std::uint8_t>& buffer,
              const std::set<DWORD>& sunshine, Ports* ports) {
  if (buffer.empty()) return;
  const auto* table = reinterpret_cast<const Table*>(buffer.data());
  for (DWORD i = 0; i < table->dwNumEntries; ++i) {
    const auto& row = table->table[i];
    if (sunshine.count(row.dwOwningPid)) {
      ports->emplace(row.dwOwningPid, Port(row.dwLocalPort));
    }
  }
}

struct FamilySample {
  bool usable;
  bool active;
};

template <typename TcpTable, typename UdpTable>
FamilySample ReadFamily(ULONG family, const std::set<DWORD>& sunshine) {
  const auto tcp_table = ReadTable([family](void* out, ULONG* size) {
    return GetExtendedTcpTable(out, size, FALSE, family,
                               TCP_TABLE_OWNER_PID_LISTENER, 0);
  });
  const auto udp_table = ReadTable([family](void* out, ULONG* size) {
    return GetExtendedUdpTable(out, size, FALSE, family, UDP_TABLE_OWNER_PID, 0);
  });
  if (tcp_table.empty() || udp_table.empty()) return {false, false};

  Ports listeners, udp;
  AddPorts<TcpTable>(tcp_table, sunshine, &listeners);
  AddPorts<UdpTable>(udp_table, sunshine, &udp);
  for (const auto& [pid, port] : listeners) {
    if (port < kRtspOffset) continue;
    const unsigned base = port - kRtspOffset;
    // Stock Sunshine creates all three sockets together for its broadcast
    // context and releases them after its last streaming session ends.
    if (udp.count({pid, base + kVideoOffset}) &&
        udp.count({pid, base + kControlOffset}) &&
        udp.count({pid, base + kAudioOffset})) {
      return {true, true};
    }
  }
  return {true, false};
}
}  // namespace

std::optional<bool> SunshineStreaming() {
  const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return std::nullopt;
  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  std::set<DWORD> sunshine;
  BOOL has_entry = Process32FirstW(snapshot, &entry);
  while (has_entry) {
    if (_wcsicmp(entry.szExeFile, L"sunshine.exe") == 0) {
      sunshine.insert(entry.th32ProcessID);
    }
    has_entry = Process32NextW(snapshot, &entry);
  }
  const DWORD error = GetLastError();
  CloseHandle(snapshot);
  if (error != ERROR_NO_MORE_FILES) return std::nullopt;
  if (sunshine.empty()) return false;

  const auto v4 = ReadFamily<MIB_TCPTABLE_OWNER_PID, MIB_UDPTABLE_OWNER_PID>(
      AF_INET, sunshine);
  const auto v6 = ReadFamily<MIB_TCP6TABLE_OWNER_PID, MIB_UDP6TABLE_OWNER_PID>(
      AF_INET6, sunshine);
  if (v4.active || v6.active) return true;
  if (v4.usable && v6.usable) return false;
  return std::nullopt;
}
