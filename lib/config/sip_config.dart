class SipConfig {
  const SipConfig({
    required this.server,
    required this.port,
    required this.username,
    required this.password,
    required this.domain,
    this.microphoneGain = 2.5,
  });

  final String server;
  final int port;
  final String username;
  final String password;
  final String domain;
  final double microphoneGain;
}
