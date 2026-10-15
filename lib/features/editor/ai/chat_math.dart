/// Repairs for the LaTeX in an assistant's answer, which the model often
/// writes in ways that keep it from rendering.
library;

/// JSON string escapes that are also how LaTeX commands begin, such as
/// `\frac` (form feed) and `\theta` (tab), mapped to whether the letters
/// after them make the escape a LaTeX command instead.
final Map<String, RegExp> _latexAfterEscape = <String, RegExp>{
  // A form feed or backspace never belongs in an answer.
  'b': RegExp(r'[A-Za-z]'),
  'f': RegExp(r'[A-Za-z]'),
  // Nor does a tab or carriage return right before a letter.
  't': RegExp(r'[A-Za-z]'),
  'r': RegExp(r'[A-Za-z]'),
  // A new line before a word is common, so only commands no word starts
  // with are taken.
  'n': RegExp(
    r'(?:abla|eq|eg|otin|ot|exists|ewline|leq|geq|parallel|mid|subseteq|'
    r'supseteq|cong|sim|rightarrow|leftarrow|Rightarrow|Leftarrow)'
    r'(?![A-Za-z])',
  ),
};

/// [source], a JSON text, with every backslash the model left unescaped in
/// LaTeX escaped, so `{"message":"\frac{1}{2} \alpha"}` decodes to the
/// `\frac{1}{2} \alpha` that was meant rather than failing on `\a` or
/// turning `\f` into a form feed. Escapes that are complete and meant, such
/// as `\\`, `\"`, and a `\n` before an ordinary word, are kept. An escape
/// cut off by the end of [source] is left for the caller to wait on.
String repairLatexEscapes(String source) {
  if (!source.contains(r'\')) {
    return source;
  }
  final StringBuffer out = StringBuffer();
  bool inString = false;
  int i = 0;
  while (i < source.length) {
    final String char = source[i];
    if (!inString) {
      inString = char == '"';
      out.write(char);
      i++;
      continue;
    }
    if (char == '"') {
      inString = false;
      out.write(char);
      i++;
      continue;
    }
    if (char != r'\' || i + 1 >= source.length) {
      out.write(char);
      i++;
      continue;
    }
    final String escape = source[i + 1];
    final bool latex;
    if (escape == '"' || escape == r'\' || escape == '/') {
      latex = false;
    } else if (escape == 'u') {
      if (i + 6 > source.length) {
        // Not all of it has arrived yet.
        latex = false;
      } else {
        latex = !RegExp(
          r'^[0-9A-Fa-f]{4}$',
        ).hasMatch(source.substring(i + 2, i + 6));
      }
    } else if (_latexAfterEscape[escape] case final RegExp after?) {
      latex = after.matchAsPrefix(source, i + 2) != null;
    } else {
      // Not a JSON escape at all, such as \alpha or \sqrt.
      latex = true;
    }
    out
      ..write(latex ? r'\\' : r'\')
      ..write(escape);
    i += 2;
  }
  return out.toString();
}

final RegExp _command = RegExp(r'\\[A-Za-z]+');

/// Math delimiters, code, and environments: a line with any of them is
/// left as it is.
final RegExp _marked = RegExp(r'\$|\\\(|\\\)|\\\[|\\\]|\\begin\{|\\end\{|`');

final RegExp _displayToken = RegExp(r'\$\$|\\\[|\\\]|\\begin\{|\\end\{');

final RegExp _linePrefix = RegExp(
  r'^(?:\s*(?:[-*+]\s+|\d{1,9}[.)]\s+|#{1,6}\s+|>\s*))*\s*',
);

final RegExp _trailingPunctuation = RegExp(r'[.,;:!?]+$');

/// Two letters in a row outside a command: a word, not a formula.
final RegExp _word = RegExp(r'[A-Za-z]{2,}');

/// [markdown] with each run of LaTeX it left outside math delimiters, such
/// as `s(t) = \frac{1}{2}at^2`, wrapped in `$…$` so it renders. Only runs
/// with a LaTeX command are wrapped. Code, and lines that already use
/// delimiters or sit inside a display formula, are left alone.
String delimitBareMath(String markdown) {
  if (!_command.hasMatch(markdown)) {
    return markdown;
  }
  final List<String> lines = markdown.split('\n');
  bool inFence = false;
  bool inDollars = false;
  int depth = 0;
  for (int i = 0; i < lines.length; i++) {
    final String line = lines[i];
    final String trimmed = line.trimLeft();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      inFence = !inFence;
      continue;
    }
    if (inFence) {
      continue;
    }
    if (inDollars || depth > 0 || _marked.hasMatch(line)) {
      for (final Match match in _displayToken.allMatches(line)) {
        switch (match[0]) {
          case r'$$':
            inDollars = !inDollars;
          case r'\[' || r'\begin{':
            depth++;
          case r'\]' || r'\end{':
            depth = depth > 0 ? depth - 1 : 0;
        }
      }
      continue;
    }
    // An indented code block.
    if (line.startsWith('    ') || line.startsWith('\t')) {
      continue;
    }
    lines[i] = _delimitLine(line);
  }
  return lines.join('\n');
}

String _delimitLine(String line) {
  if (!_command.hasMatch(line)) {
    return line;
  }
  final String prefix = _linePrefix.matchAsPrefix(line)?[0] ?? '';
  final List<(String gap, String token)> tokens = _tokens(
    line.substring(prefix.length),
  );
  final List<bool> mathy = <bool>[
    for (final (_, String token) in tokens) _isMathToken(token),
  ];
  final StringBuffer out = StringBuffer(prefix);
  int i = 0;
  while (i < tokens.length) {
    if (!mathy[i]) {
      out
        ..write(tokens[i].$1)
        ..write(tokens[i].$2);
      i++;
      continue;
    }
    int end = i;
    while (end + 1 < tokens.length && mathy[end + 1]) {
      end++;
    }
    // A lone article at either edge is English, not a variable.
    int start = i;
    while (start < end && _isArticle(tokens[start].$2)) {
      start++;
    }
    while (end > start && _isArticle(tokens[end].$2)) {
      end--;
    }
    bool hasCommand = false;
    for (int k = start; k <= end; k++) {
      hasCommand = hasCommand || _command.hasMatch(tokens[k].$2);
    }
    for (int k = i; k < start; k++) {
      out
        ..write(tokens[k].$1)
        ..write(tokens[k].$2);
    }
    if (hasCommand) {
      final StringBuffer formula = StringBuffer();
      for (int k = start; k <= end; k++) {
        if (k > start) formula.write(tokens[k].$1);
        formula.write(tokens[k].$2);
      }
      String text = formula.toString();
      final String tail = _trailingPunctuation.firstMatch(text)?[0] ?? '';
      text = text.substring(0, text.length - tail.length);
      out
        ..write(tokens[start].$1)
        ..write('\$$text\$$tail');
    } else {
      for (int k = start; k <= end; k++) {
        out
          ..write(tokens[k].$1)
          ..write(tokens[k].$2);
      }
    }
    // What the article trim left after the run, and the next run on.
    i = end + 1;
  }
  return out.toString();
}

bool _isArticle(String token) => token == 'a' || token == 'A' || token == 'I';

/// Whether [token] reads as part of a formula: it holds a LaTeX command, a
/// script, or no word.
bool _isMathToken(String token) {
  final String bare = token.replaceAll(_trailingPunctuation, '');
  if (bare.isEmpty) {
    return false;
  }
  if (_command.hasMatch(bare)) {
    return true;
  }
  return !_word.hasMatch(bare);
}

/// [text] split at the spaces outside braces, each token with the spaces
/// before it, so a command's `{…}` argument stays in one token.
List<(String, String)> _tokens(String text) {
  final List<(String, String)> tokens = <(String, String)>[];
  final StringBuffer gap = StringBuffer();
  final StringBuffer token = StringBuffer();
  int depth = 0;
  for (int i = 0; i < text.length; i++) {
    final String char = text[i];
    final bool space = char == ' ' || char == '\t';
    if (space && depth == 0) {
      if (token.isNotEmpty) {
        tokens.add((gap.toString(), token.toString()));
        gap.clear();
        token.clear();
      }
      gap.write(char);
      continue;
    }
    if (char == '{') depth++;
    if (char == '}' && depth > 0) depth--;
    token.write(char);
  }
  if (token.isNotEmpty || gap.isNotEmpty) {
    tokens.add((gap.toString(), token.toString()));
  }
  return tokens;
}
