#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>

#include <cstdint>
#include <vector>

#include "lan_interfaces.h"

std::vector<LanInterfaceAddress> ActiveLanInterfaceAddresses() {
  constexpr ULONG flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
      GAA_FLAG_SKIP_DNS_SERVER | GAA_FLAG_SKIP_FRIENDLY_NAME;
  ULONG size = 15 * 1024;
  std::vector<std::uint8_t> buffer;
  IP_ADAPTER_ADDRESSES* head = nullptr;
  for (int attempt = 0; attempt < 3; ++attempt) {
    if (size == 0 || size > 1024 * 1024) return {};
    buffer.resize(size);
    head = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
    const auto result = GetAdaptersAddresses(AF_INET, flags, nullptr, head, &size);
    if (result == NO_ERROR) break;
    head = nullptr;
    if (result != ERROR_BUFFER_OVERFLOW) return {};
  }
  std::vector<LanInterfaceAddress> addresses;
  for (auto* adapter = head; adapter; adapter = adapter->Next) {
    if (adapter->OperStatus != IfOperStatusUp ||
        (adapter->IfType != IF_TYPE_ETHERNET_CSMACD &&
         adapter->IfType != IF_TYPE_IEEE80211)) continue;
    MIB_IF_ROW2 interface_row{};
    interface_row.InterfaceLuid = adapter->Luid;
    if (GetIfEntry2(&interface_row) != NO_ERROR ||
        !interface_row.InterfaceAndOperStatusFlags.HardwareInterface) continue;
    for (auto* entry = adapter->FirstUnicastAddress; entry; entry = entry->Next) {
      const auto& socket = entry->Address;
      const int prefix = entry->OnLinkPrefixLength;
      if (!socket.lpSockaddr || socket.iSockaddrLength < static_cast<int>(sizeof(sockaddr_in)) ||
          socket.lpSockaddr->sa_family != AF_INET || prefix < 1 || prefix > 30 ||
          entry->DadState != IpDadStatePreferred) continue;
      const auto* ipv4 = reinterpret_cast<const sockaddr_in*>(socket.lpSockaddr);
      char ip[INET_ADDRSTRLEN]{};
      if (InetNtopA(AF_INET, &ipv4->sin_addr, ip, sizeof(ip))) {
        addresses.push_back({ip, prefix});
      }
      if (addresses.size() == 32) return addresses;
    }
  }
  return addresses;
}
