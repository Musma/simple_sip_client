class SipException implements Exception {
  const SipException(this.message);

  final String message;

  @override
  String toString() => message;
}
