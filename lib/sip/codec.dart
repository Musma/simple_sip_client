enum Codec {
  pcma(8, 'PCMA'),
  pcmu(0, 'PCMU');

  const Codec(this.payloadType, this.rtpName);

  final int payloadType;
  final String rtpName;
}
