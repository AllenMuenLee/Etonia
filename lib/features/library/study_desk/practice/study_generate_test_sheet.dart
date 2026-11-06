import 'dart:async';
import 'package:flutter/material.dart';
import '../../../../app/theme/app_tokens.dart';
import '../../../../shared/widgets/app_controls.dart';
import '../study_desk_controller.dart';
import '../study_source_tree.dart';
import 'study_practice_generator.dart';

class StudyGenerateTestSheet extends StatefulWidget {
  const StudyGenerateTestSheet({super.key, required this.controller});
  final StudyDeskController controller;
  @override
  State<StudyGenerateTestSheet> createState() => _StudyGenerateTestSheetState();
}

class _StudyGenerateTestSheetState extends State<StudyGenerateTestSheet> {
  late final topic = TextEditingController(
    text: widget.controller.messages.isEmpty
        ? ''
        : widget.controller.activeTestTopic,
  );
  late final Set<String> _notes = widget.controller.initialPracticeNoteIds
      .toSet();
  List<String> _topics = const [];
  Timer? _debounce;
  int _suggestionRevision = 0;
  bool _loadingTopics = false;
  String? _topicError;
  int mcqs = 4, frqs = 1;

  @override
  void initState() {
    super.initState();
    _scheduleTopics();
  }

  void _scheduleTopics() {
    _debounce?.cancel();
    final revision = ++_suggestionRevision;
    _topics = const [];
    _topicError = null;
    _loadingTopics = _notes.isNotEmpty;
    if (_notes.isEmpty) return;
    final ids = _notes.toList();
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final topics = await widget.controller.suggestTestTopics(ids);
        if (!mounted || revision != _suggestionRevision) return;
        setState(() {
          _topics = topics;
          _loadingTopics = false;
          if (topics.isEmpty) {
            _topicError = 'No topics found. Enter your own focus.';
          }
        });
      } on Object {
        if (!mounted || revision != _suggestionRevision) return;
        setState(() {
          _loadingTopics = false;
          _topicError = 'Suggestions unavailable. Enter a topic or try again.';
        });
      }
    });
  }

  PracticeDifficulty difficulty = PracticeDifficulty.application;
  @override
  void dispose() {
    _debounce?.cancel();
    _suggestionRevision++;
    topic.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Generate Test Paper',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Choose a focus and build a test from your notes.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.of(context).textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            const SectionLabel('Material to test'),
            if (widget.controller.allNotes.isEmpty)
              const Text('Add notes to your library to create a test.'),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                child: StudySourceTree(
                  notes: widget.controller.allNotes.toList(),
                  folders: widget.controller.allFolders.toList(),
                  selected: _notes,
                  noteKeyPrefix: 'test-material',
                  onSelectionChanged: (next) => setState(() {
                    _notes
                      ..clear()
                      ..addAll(next);
                    _scheduleTopics();
                  }),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            const SectionLabel('Suggested topics'),
            if (_loadingTopics)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Flexible(child: Text('Finding topics in your material...')),
                  ],
                ),
              )
            else if (_topicError != null)
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(_topicError!),
                  TextButton(
                    onPressed: () => setState(_scheduleTopics),
                    child: const Text('Try again'),
                  ),
                ],
              )
            else if (_notes.isEmpty)
              const Text('Choose material to see topic suggestions.')
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final suggestion in _topics)
                    ActionChip(
                      label: Text(suggestion),
                      onPressed: () => topic.text = suggestion,
                    ),
                ],
              ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: topic,
              maxLength: 500,
              decoration: const InputDecoration(labelText: 'Topic'),
            ),
            const SizedBox(height: AppSpacing.md),
            SectionLabel(
              'Multiple choice',
              trailing: ValuePill('$mcqs', muted: true),
            ),
            Slider(
              value: mcqs.toDouble(),
              min: 0,
              max: 12,
              divisions: 12,
              label: '$mcqs',
              onChanged: (v) => setState(() => mcqs = v.round()),
            ),
            SectionLabel(
              'Free response',
              trailing: ValuePill('$frqs', muted: true),
            ),
            Slider(
              value: frqs.toDouble(),
              min: 0,
              max: 8,
              divisions: 8,
              label: '$frqs',
              onChanged: (v) => setState(() => frqs = v.round()),
            ),
            const SectionLabel('Difficulty'),
            SegmentedButton<PracticeDifficulty>(
              key: const ValueKey('test-difficulty'),
              showSelectedIcon: false,
              segments: [
                for (final d in PracticeDifficulty.values)
                  ButtonSegment(value: d, label: Text(d.label)),
              ],
              selected: {difficulty},
              onSelectionChanged: (values) =>
                  setState(() => difficulty = values.single),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: mcqs + frqs == 0 || _notes.isEmpty
                  ? null
                  : () {
                      final focus = topic.text.trim();
                      Navigator.of(context).pop();
                      unawaited(
                        widget.controller.generateTestPaperFromActiveTopic(
                          topic: focus,
                          noteIds: _notes.toList(),
                          mcqCount: mcqs,
                          frqCount: frqs,
                          difficulty: difficulty,
                        ),
                      );
                    },
              child: const Text('Generate & Start Test'),
            ),
          ],
        ),
      ),
    ),
  );
}
