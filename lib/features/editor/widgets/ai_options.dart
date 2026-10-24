import 'package:flutter/material.dart';

import '../../../shared/widgets/app_controls.dart';
import '../ai/ai_assistant_controller.dart';

/// The AI tool's options: whether the assistant may draw on the note and
/// animate what it draws, and whether its notes always show or only in chat.
class AiOptions extends StatelessWidget {
  const AiOptions({super.key, required this.assistant});

  final AiAssistantController assistant;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: assistant,
      builder: (BuildContext context, Widget? _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const SectionLabel('Assistant'),
            ToggleSetting(
              label: 'Enable notation',
              hint: 'Allow the assistant to add static drawings to the note.',
              value: assistant.notationEnabled,
              onChanged: assistant.setNotationEnabled,
            ),
            ToggleSetting(
              label: 'Enable animation',
              hint: 'Allow useful motion explanations to loop on the note.',
              value: assistant.animationEnabled,
              onChanged: assistant.setAnimationEnabled,
            ),
            ToggleSetting(
              label: 'Show notes in chat',
              hint:
                  'Keep what the assistant wrote visible even when AI is '
                  'turned off.',
              value: assistant.showNotesInChat,
              onChanged: assistant.setShowNotesInChat,
            ),
          ],
        );
      },
    );
  }
}
