import 'dart:convert';

class SipResponse {
  const SipResponse({
    required this.statusLine,
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  final String statusLine;
  final int statusCode;
  final Map<String, String> headers;
  final String body;

  static SipResponse parse(String text) {
    final separator = text.contains('\r\n\r\n') ? '\r\n\r\n' : '\n\n';
    final parts = text.split(separator);
    final lines = const LineSplitter().convert(
      parts.first.replaceAll('\r', ''),
    );
    final headers = <String, String>{};

    for (final line in lines.skip(1)) {
      final index = line.indexOf(':');
      if (index > 0) {
        headers[line.substring(0, index).trim().toLowerCase()] = line
            .substring(index + 1)
            .trim();
      }
    }

    return SipResponse(
      statusLine: lines.first,
      statusCode: int.tryParse(lines.first.split(' ')[1]) ?? 0,
      headers: headers,
      body: parts.length > 1 ? parts.sublist(1).join(separator) : '',
    );
  }
}
