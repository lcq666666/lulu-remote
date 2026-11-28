#ifndef RUNNER_LAN_INTERFACES_H_
#define RUNNER_LAN_INTERFACES_H_

#include <string>
#include <vector>

struct LanInterfaceAddress {
  std::string address;
  int prefix_length;
};

// Read currently active physical LAN interfaces. Does not send traffic.
std::vector<LanInterfaceAddress> ActiveLanInterfaceAddresses();

#endif  // RUNNER_LAN_INTERFACES_H_
