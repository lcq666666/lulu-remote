import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/models/device.dart';
import 'package:lulu_remote/services/moonlight_launcher.dart';

void main() {
  test('Moonlight uses the existing address on default port', () {
    final device = Device(id: '1', name: 'Office', meshAddress: 'office.mesh');
    expect(WindowsMoonlight.endpoint(device), 'office.mesh');
  });

  test('Moonlight connects using the saved custom Sunshine port', () {
    final device = Device(
      id: '1',
      name: 'Office',
      meshAddress: '100.64.0.23',
      sunshinePort: 48123,
    );
    expect(WindowsMoonlight.endpoint(device), '100.64.0.23:48123');
  });
}
