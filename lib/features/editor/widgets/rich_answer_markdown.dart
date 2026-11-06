import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:xml/xml.dart';

import '../../../app/theme/app_tokens.dart';
import '../ai/chat_math.dart';

/// Keeps native content out of Markdown's inline layout, including raw SVG.
List<({String kind, String source})> richAnswerBlocks(String source) {
  final blocks = <({String kind, String source})>[];
  final markdown = StringBuffer();
  void flush() {
    if (markdown.toString().trim().isNotEmpty) {
      blocks.add((kind: 'markdown', source: markdown.toString()));
    }
    markdown.clear();
  }

  final lines = source.split('\n');
  var i = 0;
  while (i < lines.length) {
    final fence = RegExp(r'^\s*(`{3,}|~{3,})([^\n]*)$').firstMatch(lines[i]);
    if (fence != null) {
      // Fences stay whole; markup inside programming code is never interpreted.
      flush();
      final delimiter = fence[1]!;
      final language = fence[2]!.trim().toLowerCase();
      final code = StringBuffer();
      final original = StringBuffer()..writeln(lines[i++]);
      var closed = false;
      while (i < lines.length) {
        final line = lines[i++];
        original.writeln(line);
        if (RegExp(
          '^\\s*${RegExp.escape(delimiter[0])}{${delimiter.length},}\\s*\$',
        ).hasMatch(line)) {
          closed = true;
          break;
        }
        code.writeln(line);
      }
      blocks.add((
        kind: language == 'svg' && closed ? 'svg' : 'markdown',
        source: language == 'svg' && closed
            ? code.toString()
            : original.toString(),
      ));
      continue;
    }
    final callout = RegExp(
      r'^\s*>\s*\[!(NOTE|THEOREM|FORMULA|CAUTION)\]\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(lines[i]);
    if (callout != null) {
      flush();
      final body = StringBuffer()..writeln(callout[2]);
      i++;
      while (i < lines.length && RegExp(r'^\s*>').hasMatch(lines[i])) {
        body.writeln(lines[i++].replaceFirst(RegExp(r'^\s*>\s?'), ''));
      }
      blocks.add((kind: callout[1]!.toLowerCase(), source: body.toString()));
      continue;
    }
    final codeSpans = RegExp(r'(`+).*?\1').allMatches(lines[i]).toList();
    final start =
        RegExp(r'<svg\b', caseSensitive: false)
            .allMatches(lines[i])
            .where(
              (svg) => !codeSpans.any(
                (code) => code.start <= svg.start && code.end > svg.start,
              ),
            )
            .firstOrNull
            ?.start ??
        -1;
    if (start >= 0) {
      markdown.write(lines[i].substring(0, start));
      flush();
      final svg = StringBuffer(lines[i++].substring(start));
      while (!svg.toString().contains(
            RegExp(r'</svg\s*>', caseSensitive: false),
          ) &&
          i < lines.length) {
        svg
          ..writeln()
          ..write(lines[i++]);
      }
      final raw = svg.toString();
      final end = RegExp(r'</svg\s*>', caseSensitive: false).firstMatch(raw);
      if (end == null) {
        markdown.write(raw);
      } else {
        blocks.add((kind: 'svg', source: raw.substring(0, end.end)));
        if (raw.substring(end.end).trim().isNotEmpty) {
          lines.insert(i, raw.substring(end.end));
        }
      }
      continue;
    }
    markdown.writeln(lines[i++]);
  }
  flush();
  return blocks;
}

/// Chat vectors are self contained: no linked images, scripts or external URLs.
String? safeChatSvg(String source) {
  if (source.length > 100000 ||
      RegExp(
        r'<!\s*(?:DOCTYPE|ENTITY)',
        caseSensitive: false,
      ).hasMatch(source)) {
    return null;
  }
  try {
    final document = XmlDocument.parse(source);
    if (document.rootElement.name.local.toLowerCase() != 'svg') return null;
    var count = 0;
    for (final element in document.descendants.whereType<XmlElement>()) {
      if (++count > 5000) return null;
      if ([
        'script',
        'foreignobject',
        'image',
        'audio',
        'video',
        'style',
      ].contains(element.name.local.toLowerCase())) {
        return null;
      }
      for (final attribute in element.attributes) {
        final name = attribute.name.local.toLowerCase();
        final value = attribute.value.trim();
        if (name.startsWith('on') ||
            (name == 'href' && !value.startsWith('#')) ||
            (value.contains(RegExp(r'url\s*\(', caseSensitive: false)) &&
                !RegExp(
                  r'''^url\(\s*["']?#[\w:.-]+["']?\s*\)$''',
                ).hasMatch(value))) {
          return null;
        }
      }
    }
    return document.toXmlString();
  } on Object {
    return null;
  }
}

/// Shared renderer for the editor assistant, study chats and practice answers.
class AiAnswerMarkdown extends StatelessWidget {
  const AiAnswerMarkdown(this.source, {super.key});
  final String source;

  Widget _markdown(BuildContext context, String text) => GptMarkdown(
    delimitBareMath(normalizeInlineMath(text)),
    style: Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: AppColors.of(context).textPrimary),
    textDirection: Directionality.of(context),
    useDollarSignsForLatex: true,
    styleSheet: GptMarkdownStyleSheet(
      latex: LatexStyle(
        textStyle: TextStyle(color: AppColors.of(context).textPrimary),
        scrollBlockHorizontally: true,
      ),
    ),
    // Remote answer images stay placeholders. SVGs are validated separately.
    imageBuilder: (context, url, width, height) => const Text('[image]'),
    codeBuilder: (context, language, code, closed) =>
        _CodeCard(language: language, code: code),
  );

  @override
  Widget build(BuildContext context) {
    final blocks = richAnswerBlocks(source);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final block in blocks)
          if (block.kind == 'markdown')
            _markdown(context, block.source)
          else if (block.kind == 'svg')
            _SvgCard(source: block.source)
          else
            _Callout(kind: block.kind, child: _markdown(context, block.source)),
      ],
    );
  }
}

class _CodeCard extends StatefulWidget {
  const _CodeCard({required this.language, required this.code});
  final String language;
  final String code;
  @override
  State<_CodeCard> createState() => _CodeCardState();
}

class _CodeCardState extends State<_CodeCard> {
  bool _copied = false;
  @override
  void didUpdateWidget(_CodeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code) _copied = false;
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.code.trimRight().split('\n');
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      color: AppColors.of(context).textPrimary,
      height: 1.5,
    );
    return Card(
      color: AppColors.of(context).surfaceMuted,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Chip(
                  label: Text(
                    widget.language.isEmpty ? 'code' : widget.language,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: _copied ? 'Copied' : 'Copy code',
                  icon: Icon(_copied ? Icons.check : Icons.copy),
                  onPressed: () async {
                    final code = widget.code;
                    try {
                      await Clipboard.setData(ClipboardData(text: code));
                      if (mounted && code == widget.code) {
                        setState(() => _copied = true);
                      }
                    } on Object {
                      /* Clipboard may be unavailable on a host. */
                    }
                  },
                ),
              ],
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectionContainer.disabled(
                    child: Text(
                      [for (var i = 1; i <= lines.length; i++) '$i'].join('\n'),
                      style: style?.copyWith(
                        color: AppColors.of(context).textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Text(lines.join('\n'), style: style),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SvgCard extends StatefulWidget {
  const _SvgCard({required this.source});
  final String source;
  @override
  State<_SvgCard> createState() => _SvgCardState();
}

class _SvgCardState extends State<_SvgCard> {
  late String? _safe = safeChatSvg(widget.source);
  @override
  void didUpdateWidget(_SvgCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) _safe = safeChatSvg(widget.source);
  }

  Widget _vector() => ColoredBox(
    color: Colors.white,
    child: SvgPicture.string(
      _safe!,
      width: 600,
      height: 280,
      fit: BoxFit.contain,
      semanticsLabel: 'Study diagram',
      errorBuilder: (_, _, _) => const Center(
        child: Text(
          'Diagram could not be rendered',
          style: TextStyle(color: Colors.black),
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    if (_safe == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.sm),
          child: Text('Diagram could not be rendered'),
        ),
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 220,
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 8,
              child: _vector(),
            ),
          ),
          TextButton.icon(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => Dialog(
                child: SizedBox(
                  width: 900,
                  height: 650,
                  child: Column(
                    children: [
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: IconButton(
                          tooltip: 'Close diagram',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ),
                      Expanded(
                        child: InteractiveViewer(
                          minScale: 0.5,
                          maxScale: 12,
                          child: Center(child: _vector()),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            icon: const Icon(Icons.zoom_in),
            label: const Text('Zoom diagram'),
          ),
        ],
      ),
    );
  }
}

class _Callout extends StatelessWidget {
  const _Callout({required this.kind, required this.child});
  final String kind;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = kind == 'caution'
        ? theme.colorScheme.error
        : kind == 'formula'
        ? theme.colorScheme.tertiary
        : theme.colorScheme.primary;
    final icon = switch (kind) {
      'caution' => Icons.warning_amber,
      'formula' => Icons.functions,
      'theorem' => Icons.school_outlined,
      _ => Icons.info_outline,
    };
    return Container(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: AppBorderRadius.medium,
        border: BorderDirectional(start: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: AppSpacing.xs),
              Text(
                '${kind[0].toUpperCase()}${kind.substring(1)}',
                style: theme.textTheme.labelLarge?.copyWith(color: color),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          child,
        ],
      ),
    );
  }
}
