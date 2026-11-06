# Implementation Prompt 31: Study Desk Chat Redesign (Zero-Jank Scrolling & Animated Citation Highlights, Bottom-Gated Dynamic Suggestions, Rich Multimodal Rendering, and Course/History Organization)

You are working in the **Greatnote** (`Etonia`) Flutter codebase. Redesign the **Study Desk Chat experience** (`lib/features/library/study_desk/`) to achieve silky-smooth 60/120 FPS scrolling with fluidly animated citation transitions, gate suggested questions to only appear at the bottom of the transcript with dynamic AI generation, introduce a rich multimodal chat rendering engine (including direct SVG rendering), and implement a structured Course/Class organization sidebar for historical conversations.

---

## 1. What Currently Exists & Problems to Solve

### 1. Current Performance Bottleneck (`study_desk_screen.dart` lines 177–228)
- **The Lag Issue**: `_scheduleFocusUpdate()` triggers `_updateFocusedParagraph()` on scroll notifications. Every time the reading line crosses into a new paragraph with citations, `_controller.focusCitation()` is called.
- This immediately invokes `notifyListeners()`, triggering a top-level `setState()` on `StudyDeskScreen`, causing the entire chat transcript sliver list and citation preview pane to rebuild.
- Simultaneously, `StudyCitationPreview` unmounts and re-renders note pages / PDF pages, leading to severe frame drops, micro-stutters, and visual jank while scrolling.
- Highlighting changes abruptly between paragraphs without any visual interpolation or easing.

### 2. Suggested Prompts Placement & Generation
- Currently, `_Starters` are static chips (`StudyStarter`) rendered in a fixed column above the composer, cluttering vertical reading space and appearing before the user has even finished reading the assistant's response.
- Suggested questions are static presets and do not dynamically reflect the actual concepts discussed in the ongoing conversation.

### 3. Limited Multimodal Content in Chat
- Chat answers are rendered via markdown, but lack rich native Flutter widgets for vector diagrams (SVGs), copyable code blocks, visual theorem/formula callouts, and interactive diagram zoom cards.

### 4. Flat Historical Session Management (`study_desk_controller.dart` lines 159–230)
- Historical sessions are limited to an unstructured flat list of up to 20 sessions (`_sessions = kept.sessions`).
- There is no categorization by academic courses or classes (e.g. "AP Physics", "Calculus BC", "Organic Chemistry"), making it difficult for students to organize, search, and review past study conversations across multiple subjects.

---

## 2. Zero-Jank Scrolling & Fluid Animated Citation Highlights

### 2.1 Decouple Scroll Notifications from Transcript Rebuilds (`study_desk_screen.dart`)
1. **Debounce & Threshold Focus Updates**:
   - Wrap `_updateFocusedParagraph()` with a 150ms debounce or scroll-idle detector (`ScrollEndNotification`). Never trigger citation pane reloads while active finger dragging / momentum scrolling is underway.
   - Maintain an internal `ValueNotifier<(int, int)?> focusedParagraphNotifier` on `StudyDeskController` instead of calling global `notifyListeners()`.
2. **Fine-Grained Paragraph Highlight Rebuilds**:
   - In `_Paragraph`: Listen specifically to `focusedParagraphNotifier` rather than rebuilding the parent widget tree.
   - Replace the abrupt border and background color switch with smooth animated transitions:
     ```dart
     AnimatedContainer(
       duration: const Duration(milliseconds: 220),
       curve: Curves.easeOutCubic,
       decoration: BoxDecoration(
         color: isFocused
             ? aiCitationHighlightColor.withValues(alpha: 0.16)
             : Colors.transparent,
         borderRadius: AppBorderRadius.small,
         border: BorderDirectional(
           start: BorderSide(
             color: isFocused ? aiCitationHighlightColor : Colors.transparent,
             width: 3.5,
           ),
         ),
       ),
       child: ...
     )
     ```
3. **Smooth Citation Pane Cross-Fading (`study_citation_preview.dart`)**:
   - When switching focused citations, do not abruptly destroy and recreate the viewport.
   - Animate the `InteractiveViewer` matrix smoothly (`Matrix4Tween` with `Curves.easeInOutCubic`, 300ms) to zoom/pan to the newly cited bounding box.
   - If switching note documents or pages, use `AnimatedSwitcher` with subtle opacity cross-fade to prevent visual white flashes or layout jumps.

---

## 3. Bottom-Gated Dynamic Suggested Questions

### 3.1 Scroll-Gated Visibility
- Move the suggested follow-up chips from the static layout above the composer to the **very bottom of the chat transcript**:
  - Render as a trailing sliver item immediately following the final assistant response.
  - Alternatively, if displayed as a floating bottom bar, listen to `_scroll.position` and only make the container visible (with slide-up and fade-in animation via `AnimatedSlide` and `AnimatedOpacity`) when:
    ```dart
    bool get isScrolledToBottom =>
        _scroll.hasClients &&
        _scroll.offset >= _scroll.position.maxScrollExtent - 48.0;
    ```
  - While the user is scrolling through earlier messages in the history, the suggestion chips remain completely hidden to preserve a clean reading environment.

### 3.2 Dynamic AI Suggestion Generation (`study_desk_controller.dart`)
- **Background Suggestion Generator**:
  - When an AI response completes streaming, trigger an asynchronous background completion request:
    - Context: Current topic, last user question, assistant answer, and cited note headings.
    - System Instruction: *"Generate 3 concise, highly relevant follow-up questions or next exploration steps for a student studying this material. Return as a clean JSON array of strings."*
  - Update `StudyDeskController.dynamicSuggestions`:
    - Display the generated chips with a sparkling AI icon badge (`AppIcons.sparkle`).
    - Include a subtle "↻ Refresh suggestions" icon button.
    - Tapping a suggestion chip automatically inserts the text, dispatches it to the controller, and smoothly scrolls to the response.

---

## 4. Rich Multimodal Chat Rendering Engine

### 4.1 Native Multimodal Widget Extensions (`lib/features/editor/widgets/ai_assistant_panel.dart`, `chat_math.dart`)
Extend the chat answer parser and markdown renderer to recognize and display rich multimodal widgets:

1. **SVG Vector Diagram Renderer**:
   - Detect markdown code fences tagged with ````svg ... ```` or inline `<svg>` blocks.
   - Parse and render them using `flutter_svg.SvgPicture.string(...)` wrapped in a clean, zoomable card.
   - Ensures geometric shapes, biology diagrams, physics force vectors, and flowchart illustrations render with infinite resolution and crisp vectors.
2. **Enhanced LaTeX / Math Typesetting**:
   - Support both inline math (`$E = mc^2$`) and multi-line display blocks (`$$\int_{0}^{\infty} e^{-x^2} dx = \frac{\sqrt{\pi}}{2}$$`).
   - Ensure high text-contrast against theme backgrounds (following user rules for dark/light contrast) with horizontal scroll containers for wide formulas so they never cause layout overflow errors.
3. **Formatted Code Blocks with 1-Tap Copy**:
   - Render programming code with subtle background card, language pill (`python`, `dart`, `cpp`), line numbers, and a floating "Copy" button with feedback tooltip.
4. **Visual Callout Blocks (Admonitions)**:
   - Parse GitHub-style blockquotes (`> [!NOTE]`, `> [!THEOREM]`, `> [!FORMULA]`, `> [!CAUTION]`).
   - Render as rounded, color-coded callout banners with appropriate icon badges.
5. **Interactive Note Diagram Crop Cards**:
   - When an answer cites a diagram chunk (`StudyChunkKind.diagram`), render a preview card displaying a cropped thumbnail of the student's actual handwritten diagram from the note.
   - Tapping the crop card opens the inspection pane centered on that exact diagram.

---

## 5. Course/Class Organization & Historical Conversation Sidebar

### 5.1 Hierarchical Data Model (`study_desk_models.dart`, `study_desk_store.dart`)
Refactor session persistence to support academic course grouping:

```dart
@immutable
class StudyCourse {
  const StudyCourse({
    required this.id,
    required this.name,
    required this.colorHex,
    required this.createdAt,
    this.associatedFolderIds = const <String>[],
    this.associatedNoteIds = const <String>[],
  });

  final String id;
  final String name;       // e.g. "AP Physics C: Mechanics"
  final String colorHex;   // Color tag for badges/icons
  final DateTime createdAt;
  final List<String> associatedFolderIds;
  final List<String> associatedNoteIds;
}

@immutable
class StudySession {
  const StudySession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.courseId,         // Belongs to a course/class (nullable for general study)
    this.messages = const <StudyMessage>[],
    this.isPinned = false,
  });

  final String id;
  final String title;      // Auto-generated topic title, user editable
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? courseId;
  final List<StudyMessage> messages;
  final bool isPinned;

  StudySession copyWith({String? title, bool? isPinned, String? courseId}) => ...
}
```

### 5.2 Collapsible Course & History Drawer / Sidebar (`study_history_sidebar.dart`)
Implement a dedicated history and course navigation drawer (collapsible sidebar on tablets/desktop):

1. **Class / Course Filter Header**:
   - Dropdown or horizontal scroll pill bar listing all classes (`All Classes`, `Physics`, `Calculus`, `Biology`) plus a `+ Add Class` button.
   - Selecting a class filters the conversation history to only sessions belonging to that subject.
2. **Search Bar**:
   - Real-time search filter matching keywords across past conversation titles, user queries, and dates.
3. **Categorized Conversation List**:
   - Group sessions chronologically:
     - **Pinned** (always at top with pin icon)
     - **Today**
     - **Previous 7 Days**
     - **Older Sessions**
   - Each conversation item card displays:
     - Session title (e.g. *"Rotational Inertia & Torque"*).
     - Associated course badge with custom color dot.
     - Number of messages, last active timestamp, and 1-line snippet of the latest query.
     - Context menu on long-press or hover: **Rename**, **Assign to Class**, **Pin/Unpin**, **Export Transcript**, **Delete**.
4. **Primary "+ New Study Chat" Action**:
   - Prominently anchored button at the top/bottom of the drawer.
   - Prompts user to select the active Course and source notes for the new session, resetting the transcript cleanly without losing previous history.

---

## 6. Implementation Steps & Verification

1. **Smooth Highlight & Scroll Decoupling**:
   - Replace scroll-driven `_controller.focusCitation()` with debounced `focusedParagraphNotifier`.
   - Update `_Paragraph` to use `AnimatedContainer` with 220ms ease-out transitions.
   - Profile with Flutter DevTools Performance overlay: confirm zero jank and solid 60/120 FPS during rapid scrolling.
2. **Bottom-Gated Suggestions**:
   - Relocate suggestion chips to the bottom sliver of the transcript.
   - Wire dynamic background suggestion generation on `StudyDeskController` and verify entrance animations.
3. **Multimodal Markdown Renderer**:
   - Integrate SVG rendering via `flutter_svg` into `AiAnswerMarkdown`.
   - Add support for LaTeX blocks, code copy widgets, and blockquote callouts.
   - Test rendering complex answers containing formulas and vector graphics.
4. **Course & History Sidebar**:
   - Create `StudyCourse` models and update `StudyDeskStore` migration logic.
   - Build `StudyHistorySidebar` with course filtering, search, and session management.
   - Wire switching between sessions with instant transcript restoration.
5. **Automated & Manual Tests**:
   - Add widget tests verifying that scrolling does not trigger unneeded transcript rebuilds.
   - Add unit tests for `StudyCourse` and `StudySession` serialization and filtering.
