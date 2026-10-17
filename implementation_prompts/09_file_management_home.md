# Implementation Prompt 9: Build the File-Management Home Screen

You are adding a home screen for managing notes to **Greatnote**, a Flutter tablet application for Android and iPadOS. The editor already has a responsive shell, multi-page notes with per-page size and background (prompt 2), one pen with hold-to-shape (prompt 3), an eraser, selection, and the AI features. Preserve the design system, testing setup, responsive behavior, and every editor behavior.

## Goal

Launch into a calm, tablet-first library where the user can create, find, open, organize, and delete notes and folders. Notes and folders persist on the device between app launches, and a note opened from the library is saved automatically while the user writes.

## Scope

Implement only:

- the library (home) screen with folders and notes;
- creating, renaming, moving, duplicating, and deleting notes and folders;
- nested folders (subfolders to any depth) with a folder sidebar and breadcrumb navigation;
- folder colors;
- choosing a template (page size and paper) for each new note;
- search by title, sorting, and a grid/list view toggle;
- local persistence of the library and of note content;
- opening a note in the existing editor, renaming it there, autosave, and returning to the library.

Do not add cloud synchronization, accounts, sharing, import/export, PDF, tags, favorites, trash/restore, multi-select, drag-and-drop reordering, or undo. Keep each mutation a single repository call so they can be added later.

## Existing code to build on

Read these first; the library must fit their structure rather than sit beside it:

- `lib/app/greatnote_app.dart`: the app's `home`, which today is the editor.
- `lib/features/editor/editor_screen.dart`: owns tools and settings, and today a single page's `InkController`.
- the note document and page model from prompt 2 (pages, page setup, current page).
- `lib/features/editor/ink/stroke.dart`: `Stroke.fromPoints` and `StrokeSource`.
- `lib/features/editor/widgets/editor_app_bar.dart`: the navigation affordance and the title, which until now were placeholders.
- `lib/app/theme/app_tokens.dart`: colors, spacing, radii, sizes, and motion.

## Data model

- A **folder** has an id, a name, an optional parent folder id (null for the root), created/modified times, and a color.
- A folder's **color** is one of a small named palette (blue, which follows the app's accent color and is the default, red, orange, yellow, green, teal, purple, pink, gray), each with a shade for light and for dark themes. It is stored by name; a folder stored without one, or with an unknown name, reads as the default.
- A **note entry** has an id, a title, an optional folder id, created/modified times, and a page count. Its content is stored separately from the index so listing the library never loads ink.
- **Note content** is the page list: each page's setup (size, background, and an infinite page's grown extent) and its strokes. A stroke is stored as its ink color id, width, filtered points, and, for a stroke of varying width (prompt 3), its per-point width factors (rounded to three decimals; factors that do not match the points are dropped and the stroke is drawn even). Raw samples are not stored: a loaded stroke is built with `Stroke.fromPoints` and is therefore `StrokeSource.derived`. Document this on the model.
- Version the stored format with an explicit schema number. Reject unknown future versions with a clear error instead of misreading them, and tolerate unknown fields.
- Ids are generated locally and are unique; do not use titles as keys.
- Names are trimmed, may not be empty, and are limited to a reasonable length. Duplicate names are allowed; they are told apart by modification time and location.

## Repository

- Define a `NoteRepository` interface with operations to: list a folder's subfolders and notes; create a note (with an initial page setup) and a folder (with a color); rename; recolor a folder; move a note or folder to another folder; duplicate a note; delete a note; delete a folder with everything inside it; load a note's content; save a note's content; and search titles across all folders.
- Moving a folder into itself or one of its descendants is rejected.
- Provide two implementations:
  - an in-memory repository for tests and previews;
  - a file repository using `dart:io` under the app's documents directory (via `path_provider`): one index file for folders and note entries, and one content file per note. Write each file atomically (write a temporary file, then rename) so a crash never leaves a half-written file. A corrupt or unreadable content file makes that note fail to open with a message; it does not break the library.
- Do repository work off the frame-critical path; keep it asynchronous and never block a pointer event on it.
- Notify listeners after each mutation so the visible library refreshes.

## Library screen

### Layout

- A top bar with the app name or the current folder's breadcrumb trail (`Library › Physics › Lab notes`, each crumb tappable), a search field, a sort control, and a grid/list toggle.
- A **folder sidebar** down the left at medium and expanded widths (280 px, on the surface color, divided from the content by a hairline); on compact widths it is a drawer opened from a Folders button at the start of the top bar, which closes when a folder is chosen. It has, in order:
  - a "Folders" header with a **New folder** button, which makes a folder inside the open folder (at the top level from the library);
  - a **Library** row for the top level;
  - every folder as a tree, sorted by name, each indented under its parent, drawn with a folder glyph in its color (open while it is unfolded), its name, and how many items it holds. A folder with folders inside has a chevron that folds and unfolds it (tooltip "Expand …"/"Collapse …"); opening a folder anywhere unfolds it and its ancestors.
  - The open folder's row is highlighted; tapping a row opens that folder. Each folder row has the folder's overflow menu (also on long press and secondary click, and as custom semantic actions).
- Primary actions: **New note** (a prominent floating button) and **New folder** (in the sidebar; in the top bar too on compact widths, where the sidebar is a drawer), always reachable.
- Folders first, then notes, each group sorted by the selected order: modified (newest first, the default), created, or title (A–Z, case-insensitive).
- Grid view: folder cards and note cards. A note card shows a live thumbnail of its first page (its background and ink, painted from the stored content at reduced detail, or a neutral placeholder until loaded), the title, and a relative or short modified date. Grid columns adapt to the width using the existing breakpoints.
- List view: one row per item with an icon or small thumbnail, the title, the date, and for folders the item count.
- An empty folder shows a quiet empty state with the New note action. A search with no results says so.
- Use the existing tokens for colors, spacing, radii, shadows, and motion. Keep the visual language of the editor: warm background, paper-white cards, one accent color.

### Actions

- Tap a folder to open it, in the grid or the sidebar; tap a note to open it in the editor.
- Folder cards and list rows show the folder glyph in the folder's color on a light tint of it.
- Each item has an overflow menu (also reachable with a long press and from the keyboard) with Rename, Move to…, Duplicate (notes only), and Delete.
- New note first asks for the note's **template** in a dialog: the paper (blank, lined, grid, dotted) and the page size (fit to screen, A4 portrait and landscape, Letter portrait and landscape, square, infinite), each a small picture of the page with its name, the chosen one ringed and announced as selected. Create makes `Untitled note` with one page of that setup in the current folder and opens it; Cancel makes nothing. The dialog offers the last template used first (fit to screen, blank, the first time).
- New folder asks for a name and a color (a row of swatches, the chosen one ringed and checked, each labelled for screen readers).
- A folder's overflow menu has New subfolder (asks for a name and a color, titled "New folder in …"), Rename, Color… (picks a new color), Move to…, and Delete. A note's has Rename, Move to…, Duplicate, Export as PDF, and Delete.
- Rename uses a dialog with the current name selected.
- Move to… shows a folder picker with the root and every folder except the item itself and, for a folder, its descendants.
- Delete asks for confirmation, stating what will be lost (for a folder: how many notes and folders it contains).
- Search filters titles across all folders as the user types; results show each note's folder.
- Sort order and view mode survive navigation for the session.

## Editor integration

- The app's default home is the library. `GreatnoteApp(home: ...)` still overrides it for tests and harnesses, and the editor can still be pumped on its own with no repository.
- Opening a note loads its content, then pushes the editor with that note's pages. Show a progress indicator while loading and an error message if it fails.
- In the editor, the navigation affordance returns to the library, and the title opens a rename dialog that renames the note in the repository.
- Autosave: when a page's ink, a page setup, or the page list changes, save the note after a short debounce (default 800 ms), and also when leaving the editor and when the app is paused. Never save mid-gesture: wait until the gesture ends. A save updates the entry's modified time and page count, and the library thumbnail reflects it when the user returns.
- Saving failures are reported unobtrusively (for example a snackbar) and retried on the next change; they never lose the in-memory ink.

## Accessibility and responsiveness

- Every control has a tooltip or label, a 48 × 48 target, and visible focus. Keyboard order is the top bar, then the sidebar, then the items, then New note. Cards and rows expose their title, kind (note or folder), and modified date to screen readers, and their overflow actions as custom semantic actions.
- Keyboard: Tab moves through the top bar, the primary actions, and the items in order; Enter opens; the overflow menu is reachable without a pointer.
- Layout works without overflow at `390 x 844`, `800 x 1280`, and `1194 x 834`, in light and dark themes, and in both orientations.

## Automated tests

### Model and repository

- serialization round-trips folders, entries, pages (every size and background, and an infinite page's extent), and strokes exactly; loaded strokes are derived;
- an unknown future schema version is rejected; unknown fields are ignored;
- create, rename, recolor, move, duplicate, and delete behave as specified in both repositories; folder colors survive a reload from disk, and a folder without a stored color reads as the default; deleting a folder removes its descendants; moving a folder into its own subtree is rejected;
- search matches titles case-insensitively across folders;
- the file repository writes atomically, survives a reload from disk with identical content, and reports a corrupt content file as a failure of that note only (use a temporary directory).

### Widget tests

- the library shows folders before notes, sorts by each order, and switches between grid and list;
- creating a note asks for its template first, then opens the editor on a page of the chosen size and paper; cancelling makes no note; the next new note offers the same template first;
- drawing and returning saves the ink, updates the modified time, and shows it in the thumbnail;
- the sidebar shows the folder tree in the folders' colors, unfolds and folds, and opens folders; on compact widths it is a drawer that closes on the folder chosen;
- new folders and subfolders take a name and a color, from the sidebar, the top bar, and a folder's menu; Color… recolors a folder;
- reopening the note restores every page, its setup, and its ink;
- renaming from the library and from the editor title both update the entry;
- moving, duplicating, and deleting (with confirmation) work from the overflow menu and the long press;
- breadcrumbs navigate up; empty and no-results states appear;
- semantics labels, tap targets, and keyboard focus order;
- goldens for the library grid (tablet landscape light and dark), the list view (tablet portrait light), and the compact layout.

## Acceptance criteria

- The app opens to a library of folders and notes that persists across launches.
- The user can create, open, rename, move, duplicate, delete, search, and sort notes and folders, nest folders, color them, and find them in the sidebar.
- Every new note starts from the template the user picks.
- Notes save automatically while writing and reopen exactly as left, with all pages, setups, and ink.
- Editor behavior is otherwise unchanged.
- Formatting, static analysis, unit tests, widget tests, and golden tests pass.

## Completion report

At the end, describe the storage layout and schema, the repository interface, how autosave is triggered and debounced, how loaded strokes are represented, the tests added and any existing tests changed and why, and anything left for later (sync, trash, import/export, thumbnail caching, moving saves to a background isolate).
