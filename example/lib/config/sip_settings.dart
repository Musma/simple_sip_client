import 'package:simple_sip_client/simple_sip_client.dart';

const sipConfig = SipConfig(
  server: '192.168.5.100',
  port: 5060,
  username: 'control-pc-1',
  password: 'musma0812',
  domain: '192.168.5.100',
);

const speakerTargets = <String, String>{
  'speaker_1001': '1001',
  'speaker_1002': '1002',
  'speaker_1003': '1003',
  'speaker_1004': '1004',
};
