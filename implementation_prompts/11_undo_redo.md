# Implementation Prompt 11: Undo and Redo

You are adding undo and redo to **Greatnote**, a Flutter tablet application for Android and iPadOS. The editor already has multi-page notes (prompt 2), one pen with hold-to-shape (prompt 3), area and stroke erasers (prompt 4), lasso selection with move, scale, rotate, copy, cut, and paste (prompt 5), the AI assistant and AI notation (prompts 6 to 8), a persisted library with autosave (prompt 9), and imported PDF pages and images (prompt 10). Earlier prompts deferred history and kept every committed change a single controller-level mutation so it could be recorded now. Preserve every existing behavior.

## Goal

The user can take back a mistake and apply it again: an Undo and a Redo button in the editor's top bar, and the standard keyboard shortcuts, step backward and forward through the changes made to the current page.

## Scope

Implement only:

- a per-page, per-session history of committed ink changes, owned by `InkController`;
- Undo and Redo buttons in the top bar;
- `Ctrl`/`Cmd`+Z for Undo, and `Ctrl`/`Cmd`+Shift+Z and `Ctrl`+Y for Redo.

Do not add a history panel, history persisted across sessions, a note-wide history spanning pages, undo of page add, delete, reorder, or page setup changes, undo of library operations, or undo of AI conversations.

## History model

- One step per committed change, exactly the mutations earlier prompts kept whole: a completed stroke; a committed hold-to-shape shape; one whole erase gesture, from pointer-down to pointer-up, however many strokes it cut; a committed transform; a cut; a paste; an inserted image; an applied AI notation. An identity transform, an erase that touched nothing, a copy, and a selection change are not steps.
- Record a step where the controller already marks a committed change (where it bumps the document revision), so no mutation path can be missed. Keep the committed state from before an in-progress gesture, since the eraser changes the strokes live during its gesture: the step's "before" is the page as it was when the gesture began.
- A step is a snapshot of the page's strokes and images. Both are immutable, so a snapshot shares them and costs one list each; do not deep-copy points.
- A new change after an undo drops the redo history.
- Bound the history with a named `historyLimit` (default 100) on the controller, forgetting the oldest steps first; `0` turns history off.
- History lives in memory for the editor session. It is not saved with the note, and asset cleanup at note open/close is unaffected (images removed by an undo stay available for redo for the whole session because cleanup only runs at open/close).

## Undo and redo

- `undo()` and `redo()` return whether they changed anything; `canUndo` and `canRedo` report whether they could.
- Both do nothing while any gesture is in progress (stroke, shape adjust, erase, lasso, transform), so a pointer gesture is never cut short.
- Both drop the selection, keep the clipboard, notify the completed-ink and selection layers once, and bump the document revision, so autosave saves the result and an AI request captured before the undo is treated as stale.
- AI notation playbacks follow the strokes: a playing notation whose strokes leave the page through an undo is let go; strokes that come back through a redo are ordinary finished ink.
- History is per page. Undo acts on the current page; moving to another page and back keeps each page's history.

## Top bar

- Add Undo and Redo icon buttons to the top bar, before the page controls, after the title in focus order. Use the platform's standard undo and redo glyphs, tooltips `Undo` and `Redo`, 48 × 48 targets, and visible disabled states.
- Each is enabled only when it can act, and updates when the current page's document revision changes or the current page changes.
- They fit without overflow at `390 x 844`, `800 x 1280`, and `1194 x 834`, in both orientations, alongside the title, page controls, and overflow control.
- Using either hides any pending Paste prompt.

## Keyboard

- Extend the editor's existing clipboard shortcut handler: `Ctrl`/`Cmd`+Z undoes; `Ctrl`/`Cmd`+Shift+Z and `Ctrl`+Y redo. A focused text field (the AI composer) keeps these keys for its own text.

## Automated tests

- each kind of committed change is exactly one step, and an erase gesture over several strokes is one step;
- undo then redo restores the exact stroke and image lists; a new change clears redo; the limit forgets the oldest steps;
- undo and redo refuse during a gesture, drop the selection, keep the clipboard, and bump the revision;
- an undone AI notation stops playing;
- the buttons' enabled states follow the history, they are labelled, keyboard-reachable, and at least 48 × 48;
- the shortcuts work and are left to a focused text field;
- update goldens that show the top bar.

## Acceptance criteria

- Every change the user or the AI makes to a page can be undone and redone, one committed change at a time, from the top bar or the keyboard.
- Undo and redo never interrupt a gesture, never lose the clipboard, and are saved by autosave like any other change.
- Formatting, static analysis, unit tests, widget tests, and golden tests pass.

## Completion report

At the end, describe the history model and where steps are recorded, the memory cost of a step, the history limit, how undo interacts with selection, clipboard, autosave, AI staleness, and notation playback, the tests added and the goldens changed, and the deferred work (page-structure undo, note-wide history, persisted history).
