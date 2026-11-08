import 'package:flutter/foundation.dart';

enum StudyProgressPhase { planning, searching, reading, describing, answering }

@immutable
class StudyProgressSource {
  const StudyProgressSource(this.title, {this.page});
  final String title;
  final int? page;
  String get label => page == null ? title : '$title, page $page';
}

/// Observable work only: actual retrieval terms and source names, never a
/// generated account of the model's private reasoning.
@immutable
class StudyRequestProgress {
  const StudyRequestProgress(
    this.phase, {
    this.query = '',
    this.sources = const [],
  });
  final StudyProgressPhase phase;
  final String query;
  final List<StudyProgressSource> sources;

  String get label => switch (phase) {
    StudyProgressPhase.planning => 'Planning your answer…',
    StudyProgressPhase.searching =>
      query.isEmpty ? 'Searching your notes…' : 'Searching for “$query”…',
    StudyProgressPhase.reading =>
      sources.isEmpty
          ? 'Reading the selected notes…'
          : 'Reading “${sources.first.label}”…',
    StudyProgressPhase.describing => 'Describing the visual notes…',
    StudyProgressPhase.answering => 'Writing your answer…',
  };

  String? get detail {
    final names = sources.map((source) => source.label).toSet().join('; ');
    final parts = <String>[
      if (query.isNotEmpty && phase != StudyProgressPhase.searching)
        'Looking for: $query',
      if (names.isNotEmpty && phase != StudyProgressPhase.reading)
        'Using: $names',
    ];
    return parts.isEmpty ? null : parts.join('\n');
  }
}
