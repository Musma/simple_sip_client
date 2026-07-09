import 'package:flutter_test/flutter_test.dart';
import 'package:simple_sip_client/simple_sip_client.dart';

void main() {
  test('exports SIP config and codec API', () {
    const config = SipConfig(
      server: '127.0.0.1',
      port: 5060,
      username: 'user',
      password: 'pass',
      domain: '127.0.0.1',
    );

    expect(config.port, 5060);
    expect(Codec.pcma.payloadType, 8);
    expect(Codec.pcmu.rtpName, 'PCMU');
  });
}
