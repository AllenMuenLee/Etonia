import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../ai/ai_assistant_controller.dart';
import 'tool_options_bar.dart';

/// The AI tool's options, along a [ToolOptionsBar], each a switch named in
/// a word or two with its icon: whether the assistant may draw on the note
/// and animate what it draws, and whether its notes always show or only in
/// chat.
class AiOptions extends StatelessWidget {
  const AiOptions({
    super.key,
    required this.assistant,
    this.axis = Axis.horizontal,
  });

  final AiAssistantController assistant;
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: assistant,
      builder: (BuildContext context, Widget? _) {
        Widget toggle({
          required String key,
          required String label,
          required String word,
          required IconData icon,
          required bool value,
          required ValueChanged<bool> onChanged,
        }) {
          return OptionsButton(
            key: ValueKey<String>(key),
            tooltip: '$label: ${value ? 'on' : 'off'}',
            semanticLabel: label,
            label: word,
            selected: value,
            toggled: value,
            onPressed: () => onChanged(!value),
            child: AppIcon(icon),
          );
        }

        return ToolOptionsBar(
          key: const ValueKey<String>('ai-options-bar'),
          axis: axis,
          children: <Widget>[
            toggle(
              key: 'ai-notation-toggle',
              label: 'Notation',
              word: 'Notation',
              icon: AppIcons.notation,
              value: assistant.notationEnabled,
              onChanged: assistant.setNotationEnabled,
            ),
            toggle(
              key: 'ai-animation-toggle',
              label: 'Animation',
              word: 'Animation',
              icon: AppIcons.animation,
              value: assistant.animationEnabled,
              onChanged: assistant.setAnimationEnabled,
            ),
            toggle(
              key: 'ai-show-notes-toggle',
              label: 'Show notes in chat',
              word: 'Show notes',
              icon: AppIcons.show,
              value: assistant.showNotesInChat,
              onChanged: assistant.setShowNotesInChat,
            ),
          ],
        );
      },
    );
  }
}
