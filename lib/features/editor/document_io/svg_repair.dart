// Repairs XML syntax only; callers must still validate the resulting SVG.
String repairSvgXml(
  String source, {
  required int maxNodes,
  required int maxDepth,
}) {
  final StringBuffer result = StringBuffer();
  final List<String> open = <String>[];
  int nodes = 0;
  int cursor = 0;
  while (cursor < source.length) {
    final int start = source.indexOf('<', cursor);
    if (start < 0) {
      result.write(_escapeText(source.substring(cursor)));
      break;
    }
    result.write(_escapeText(source.substring(cursor, start)));
    final String? terminator = source.startsWith('<!--', start)
        ? '-->'
        : source.startsWith('<![CDATA[', start)
        ? ']]>'
        : source.startsWith('<?', start)
        ? '?>'
        : null;
    if (terminator != null) {
      final int end = source.indexOf(terminator, start + 2);
      if (end < 0) throw const FormatException('Invalid SVG');
      cursor = end + terminator.length;
      result.write(source.substring(start, cursor));
      continue;
    }
    if (source.startsWith('<!', start)) {
      throw const FormatException('Unsafe SVG');
    }
    final Match? name = _tagName.matchAsPrefix(source, start);
    if (name == null) {
      // A comparison in text, such as "x < 3", is not an XML tag.
      result.write('&lt;');
      cursor = start + 1;
      continue;
    }
    int? quote;
    int end = name.end;
    for (; end < source.length; end++) {
      final int unit = source.codeUnitAt(end);
      if (quote != null) {
        if (unit == quote) quote = null;
      } else if (unit == 0x22 || unit == 0x27) {
        quote = unit;
      } else if (unit == 0x3e) {
        break;
      }
    }
    // A truncated last tag never became visible; keep the completed artwork.
    if (end == source.length) break;
    final String tagName = name[2]!;
    if (name[1] == '/') {
      final int ancestor = open.lastIndexOf(tagName);
      if (ancestor < 0) throw const FormatException('Invalid SVG');
      while (open.length > ancestor) {
        result.write('</${open.removeLast()}>');
      }
    } else {
      if (++nodes > maxNodes || open.length > maxDepth) {
        throw const FormatException('SVG is too complex');
      }
      String tag = source.substring(start, end + 1);
      // SVG is XML, so even numeric attributes need quotes.
      tag = tag.replaceAllMapped(_attribute, (Match match) {
        if (match[2] == null) return match[0]!;
        String value = match[2]!;
        final bool closing = value.endsWith('/') && match.end == tag.length - 1;
        if (closing) value = value.substring(0, value.length - 1);
        return '${match[1]}"$value"${closing ? '/' : ''}';
      });
      result.write(_escapeAmpersands(tag));
      if (!_selfClosing.hasMatch(tag)) open.add(tagName);
    }
    cursor = end + 1;
  }
  for (final String name in open.reversed) {
    result.write('</$name>');
  }
  return result.toString();
}

String _escapeText(String value) =>
    _escapeAmpersands(value).replaceAll('<', '&lt;');

String _escapeAmpersands(String value) =>
    value.replaceAllMapped(_bareAmpersand, (_) => '&amp;');

final RegExp _tagName = RegExp(r'<(/?)([A-Za-z_][\w:.-]*)(?=[\s/>])');
final RegExp _attribute = RegExp(
  r'''(\s[\w:.-]+\s*=\s*)(?:"[^"]*"|'[^']*'|([^\s"'=<>`]+))''',
);
final RegExp _selfClosing = RegExp(r'/\s*>$');
final RegExp _bareAmpersand = RegExp(
  r'&(?!(?:amp|lt|gt|quot|apos|#\d+|#x[\da-fA-F]+);)',
);
