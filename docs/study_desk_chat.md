# Study Desk chat

The tutor uses simple, professional language, briefly defines new terminology
and symbols, and explains prerequisites without assuming subject knowledge.
Examples start with fresh foundational checks. Once an actual mistake is
evidenced in the notes or conversation, the tutor revisits it constructively,
explains the correction, and reminds the student how to avoid repeating it.
Uncertain handwriting and general pitfalls are not attributed to the student.

For requests with a manageable source scope, a configured, accessible x1 model
(Luna or Haiku, preferring the selected provider) classifies the request as a
focused question, a new topic, or a continuation. It receives retrieved passages
and conversation history and creates a bounded lesson plan with step-specific
retrieval queries and fresh foundational exercises. The selected answer model
receives that plan plus newly retrieved passages for the active step. It teaches
one step and checks understanding before progressing. Side questions preserve
the lesson position. Within a lesson, `next` refers to the next lesson step;
explicit chapter requests retain normal source navigation.

The plan, original source scope, and active step are saved with the session and
restored on reopening. Progress commits only after a successful teaching answer.
Planner calls use the regular response envelope and usage accounting, never
enter the visible transcript, and cannot affect a different chat after a switch.
If planning fails or no inexpensive model is available, the selected model can
still answer with the same teaching guidance. Oversized books and unknown
chapters retain the scope clarification flow before lesson planning begins.

Citation focus has its own listenables. Scrolling waits for 150 ms of idle before
changing focus; dragging and ballistic scrolling do not load citation pages.
Paragraphs animate their decoration for 220 ms while retaining the answer widget.
The inspection pane retains its viewport on the same page, interpolates its matrix
for 300 ms, and cross-fades between pages. Reduced motion skips spatial animation.

Follow-up questions are generated in a separate request after an answer completes.
They appear as the final transcript item and scroll away with history. Refresh and
selection do not replace the completed answer. Results from a previous question,
session, or disposed controller are discarded. This request uses the same SVG
transport envelope as the production AI client, with a JSON array inside its
message. Backend usage accounting applies to the suggestion request too.

The shared answer renderer supports self-contained SVG diagrams with zoom, inline
and horizontally scrolling display math, code cards with line numbers and copy
feedback, and NOTE/THEOREM/FORMULA/CAUTION callouts. Remote answer images remain
placeholders. Note diagram cards use the original note's crop; merged citations
retain separate diagram regions so each card opens at the correct location.

The Classes & history control opens a collapsible desktop sidebar or a compact
overlay. It supports class creation and source associations, title/query/date
search, chronological groups, pins, renaming, class assignment, Markdown transcript
export, and deletion. New Study Chat asks for a class and sources. Session switches
restore their source selections and clear the composer draft.

The store writes schema 2. Schema 1 sessions retain their derived titles and creation
dates and receive a snapshot of the old shared sources. Course, pin, title override,
last-active date, and per-session sources survive restart. Chats are no longer
silently evicted after twenty conversations.

Whole-page source citations show the page without a ring. This applies to scanned
PDF chunks and saved page-sized circles; circles around smaller details remain.

The tutor cites a note or PDF only when an entire paragraph directly discusses
its specific problem, equation, diagram, statement, or data. Rewritten pages,
generated variations, changed numbers, fresh exercises, and general explanations
of the same topic receive no citation. Mixed paragraphs are split so only direct
source discussion is cited. Practice and exam generation use the same policy:
adapted or original questions have an empty source instead of linking the page
that inspired them. This semantic distinction is enforced in the model prompts;
the citation resolver continues to validate the source tags the model returns.

Before retrieving answer passages, Study Desk assesses source page counts and
estimated text size and extracts a bounded catalogue of chapter headings. Broad
requests on large sources send the catalogue without chapter bodies or rendered
pages, and ask which chapter to start with. The answer model also receives source
scope for focused requests so it can recognize other tasks that need narrowing.
Chapter numbers, titles, and page ranges restrict subsequent retrieval; short
follow-ups retain the chapter, and “next chapter” advances it. Contents entries and
repeated running headers are excluded from chapter boundaries. When headings
cannot be detected reliably, the tutor asks for a small note page range rather
than inventing chapters. This is based on indexed text; scanned pages without
recognized headings use that fallback. Catalogue bytes count against the excerpt
budget. Focused topic questions continue to search directly.

## Verification

```powershell
flutter test --no-pub test/features/library/study_desk_redesign_test.dart test/features/library/study_desk_test.dart test/features/editor/ai/chat_math_test.dart test/features/editor/ai/ai_citation_test.dart test/features/editor/widgets/ai_citation_panel_test.dart
flutter test --no-pub test/features/library/study_desk/study_context_plan_test.dart test/features/library/study_desk/study_page_citation_test.dart
npx --yes deno test --config supabase/functions/deno.json --allow-env supabase/tests/ai_policy_test.ts
```

The redesign tests cover migration and round trips, source restoration, history
retention/filtering, stale suggestions, the production response envelope, no global
broadcasts during citation focus, transcript identity while scrolling, persistent
animated viewports, sidebar actions, diagram crop reuse, code copying, SVG parsing,
and wide formulas in both themes. Backend tests keep SVG paragraph numbering in
sync with the app.

## Physical-device profile

```powershell
flutter drive --no-dds --no-pub --profile --driver=test_driver/perf_driver.dart --target=integration_test/study_desk_chat_performance_test.dart -d DEVICE_ID
```

Use a physical tablet. DDS must be disabled so the on-device timeline client can
connect to the VM service. The fixture keeps its notes and history entirely in
memory: 64 messages containing math, diagrams, callouts and code, with two 1,200
stroke note pages. It exercises repeated flings and same-page/page-changing
citation transitions, checks that the controller broadcasts zero transcript
updates, and saves frame statistics to `build/study_desk_frame_stats.json` plus a
timeline summary under `build/`. UI/raster p50, p90, p99, worst frames, observed
refresh rate and over-budget counts are reported separately.

Widget tests prove state isolation and behavior; they do not establish 60/120 FPS.
Frame measurements have no before-change baseline and should not be described as
a measured speedup. Repeat with real PDFs, cold caches, larger notes, text scaling,
and supported 60/120 Hz hardware before certifying those frame targets.

On 2026-11-04, the combined Flutter regression run passed 160 tests; the expanded
redesign suite passed 16 tests, and the backend policy suite passed 15 tests.
Targeted analysis found no errors or warnings; the installed development SDK
reports informational deprecations for the repository's Material import.
The Android profile APK built successfully for the connected 25097RP43G tablet
(Android 16, Skia). An initial driver connection required `--no-dds`; the subsequent
installation was rejected with `INSTALL_FAILED_USER_RESTRICTED: Install canceled
by user`. The driver's automatic retry was stopped. No completed frame trace or
60/120 Hz certification is claimed from that attempt.
