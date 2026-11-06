String assistantTextForStudyDesk(String source) {
  final lines = source.split('\n');
  final protected = <int>{};
  String? fence;
  var fenceLength = 0;
  var inFormula = false;
  var inSvg = false;
  var end = lines.length;

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    final delimiter = RegExp(r'^(`{3,}|~{3,})(.*)$').firstMatch(line);
    if (fence != null) {
      protected.add(i);
      if (delimiter != null &&
          delimiter[1]!.startsWith(fence) &&
          delimiter[1]!.length >= fenceLength &&
          delimiter[2]!.trim().isEmpty) {
        fence = null;
      }
      continue;
    }
    if (!inFormula && !inSvg && delimiter != null) {
      fence = delimiter[1]![0];
      fenceLength = delimiter[1]!.length;
      protected.add(i);
      continue;
    }
    if (inFormula || inSvg) protected.add(i);
    if (!inFormula && RegExp(r'<svg\b', caseSensitive: false).hasMatch(line)) {
      inSvg = true;
      protected.add(i);
    }
    if (!inSvg && r'$$'.allMatches(line).length.isOdd) {
      inFormula = !inFormula;
      protected.add(i);
    }
    if (RegExp(r'</svg\s*>', caseSensitive: false).hasMatch(line)) {
      inSvg = false;
    }
    if (!protected.contains(i) &&
        RegExp(
          r'^\((?:end|stop)\)[.!]?$',
          caseSensitive: false,
        ).hasMatch(line)) {
      end = i;
      break;
    }
  }

  // Only trim standalone sign-offs at the end. Subject matter and examples
  // containing these words remain part of the answer.
  final signOff = RegExp(
    r'^(?:good luck[.!]?|final line[.!]?|\.{3,}|…+)$',
    caseSensitive: false,
  );
  while (end > 0 && !protected.contains(end - 1)) {
    final line = lines[end - 1].trim();
    if (line.isNotEmpty && !signOff.hasMatch(line)) break;
    end--;
  }
  final completion = RegExp(
    r'^[\w -]{1,80} overview complete[.!]?$',
    caseSensitive: false,
  );
  final nextStep = RegExp(r'^Review .+ next[.!]?$', caseSensitive: false);
  for (var i = end - 1; i >= 0; i--) {
    if (protected.contains(i)) break;
    final line = lines[i].trim();
    if (completion.hasMatch(line)) {
      end = i;
      break;
    }
    if (line.isNotEmpty && !nextStep.hasMatch(line)) break;
  }
  final notationLabel = RegExp(
    r'^(?:[-*+]\s+)?(?:\*\*|__)?notation(?:\*\*|__)?\s*:(?:\*\*|__)?\s*',
    caseSensitive: false,
  );
  final drawingDescription = RegExp(
    r'\b(?:above|below|beside|underneath|left|right|blue|red|green|orange|purple|teal|'
    r'drawn|drawing|added|placed|highlighted|annotated|on the note)\b',
    caseSensitive: false,
  );
  final kept = <String>[];
  var removedNarration = false;
  for (var i = 0; i < end; i++) {
    if (!protected.contains(i) && notationLabel.hasMatch(lines[i].trim())) {
      var next = i + 1;
      while (next < end &&
          !protected.contains(next) &&
          lines[next].trim().isNotEmpty &&
          !RegExp(r'^\s*(?:[-*+]\s|#{1,6}\s|>)').hasMatch(lines[next])) {
        next++;
      }
      if (drawingDescription.hasMatch(lines.sublist(i, next).join('\n'))) {
        removedNarration = true;
        i = next - 1;
        continue;
      }
    }
    kept.add(lines[i]);
  }
  return end == lines.length && !removedNarration
      ? source
      : kept.join('\n').trim();
}
