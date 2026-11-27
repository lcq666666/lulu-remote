// SPDX-License-Identifier: GPL-3.0-only

/// Pairing failures, kept apart deliberately: the recovery differs.
///
/// - [PairingWrongPin] → the user retypes / LULU re-submits a PIN.
/// - [PairingMitm] → stop trusting this host, do not retry blindly.
/// - [PairingTransport] → network / host unreachable, retry later.
/// - [PairingRefused] → Sunshine said `<paired>0</paired>` at phase 4.
/// - [PairingAlreadyInProgress] → another pairing is in flight on the host
///   (empty `plaincert`); wait for it to finish or restart Sunshine.
sealed class PairingException implements Exception {
  const PairingException(this.message);
  final String message;
  @override
  String toString() => message;
}

class PairingWrongPin extends PairingException {
  const PairingWrongPin()
      : super('PIN 不正确：请检查后重新配对。');
}

class PairingMitm extends PairingException {
  const PairingMitm()
      : super('服务器签名校验失败：可能有人在中间，或这台电脑换了证书。请确认组网地址是你自己的电脑，再重试。');
}

class PairingTransport extends PairingException {
  const PairingTransport(super.message);
}

class PairingRefused extends PairingException {
  const PairingRefused()
      : super('对方拒绝了配对（paired=0）。请确认 Sunshine 正在运行，且没有其他配对正在进行。');
}

class PairingAlreadyInProgress extends PairingException {
  const PairingAlreadyInProgress()
      : super('这台电脑上已经有一个配对在进行中，请等它结束后再试。');
}

class PairingCancelled extends PairingException {
  const PairingCancelled() : super('配对已取消。');
}
