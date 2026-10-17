# Implementation Prompt 17: Google Drive Connection — Online Backup & Goodnotes Folder Replication

You are extending **Greatnote**, a Flutter tablet note application for Android and iPadOS. The app already opens to a persisted library of nested folders and notes (`NoteRepository`, `FileNoteRepository`, `InMemoryNoteRepository`), supports importing PDFs and `.goodnotes` archives (`DocumentImporter`, `GoodnotesArchiveExtractor`), and exports notes as PDFs. Preserve all existing library, editor, undo/redo, AI, and storage behaviors.

## Product outcome

Allow the user to connect their **Google Drive** account from the library screen to perform two cloud workflows:

1. **Online Backup (and Restore) of their Greatnote library:**
   - Back up the user's entire local Greatnote library (all folders, folder colors, parent-child hierarchy, notes, pages, ink strokes, sticky notes, and PDF/image assets) to a dedicated app backup folder in Google Drive, and allow restoring/syncing from that backup.
2. **Search for the `GoodNotes` (or `Goodnotes`) folder in Google Drive and replicate its exact folder structure and all of its files:**
   - Locate the user's Goodnotes backup/auto-backup folder on Google Drive, traverse its complete nested subfolder tree, replicate the exact folder hierarchy inside Greatnote's library, and import every supported file inside (`.goodnotes` files via `GoodnotesArchiveExtractor` and `.pdf` files via `DocumentImporter`, including Goodnotes PDF ink recovery when applicable).

## Architecture and platform seams

Before editing, inspect:
- `lib/features/library/note_repository.dart`, `file_note_repository.dart`, `library_models.dart`, `note_content.dart`
- `lib/features/library/library_screen.dart` and `library_dialogs.dart`
- `lib/features/editor/document_io/document_importer.dart`, `document_io_config.dart`, `goodnotes_pdf_recovery.dart`, and `goodnotes_archive_extractor.dart`
- `test/helpers/`

### Injectable `GoogleDriveClient` abstraction
Put all Google Sign-In / OAuth and Google Drive REST v3 operations behind a clean, mockable interface in `lib/features/library/cloud/google_drive_client.dart` so unit and widget tests never make network calls or touch platform auth channels:

- **Account & Auth:**
  - `GoogleDriveAccount? get currentAccount` (email, displayName)
  - `Future<GoogleDriveAccount?> signIn()` (returns `null` if the user cancels)
  - `Future<void> signOut()`
- **Drive file/folder primitives (`GoogleDriveItem`):**
  - `id`, `name`, `mimeType`, `parentIds`, `modifiedTime`, `sizeBytes`
  - `Future<List<GoogleDriveItem>> searchFoldersByName(String name)` (case-insensitive match for `'GoodNotes'` / `'Goodnotes'` where `mimeType == 'application/vnd.google-apps.folder'` and `trashed == false`)
  - `Future<List<GoogleDriveItem>> listChildren(String folderId)` (handles pagination via `nextPageToken`)
  - `Future<GoogleDriveItem> ensureFolder({required String name, String? parentId})`
  - `Future<void> uploadFile({required String parentId, required String name, required Uint8List bytes, required String mimeType, String? existingFileId})`
  - `Future<Uint8List> downloadFile(String fileId)`
- Provide a production HTTP/OAuth client (`HttpGoogleDriveClient`) and a deterministic fake (`FakeGoogleDriveClient` in `test/helpers/google_drive_fakes.dart`).

## Workflow 1: Online Backup to Google Drive

Create `GoogleDriveBackupService` in `lib/features/library/cloud/google_drive_backup_service.dart`:

- **Backup structure on Google Drive:**
  - Store backups inside a root folder named `Greatnote Backup` on the user's Google Drive.
  - Upload a deterministic, atomic snapshot (either a single versioned `.greatnote-backup.zip` archive or a structured `library.json` + `notes/<noteId>.json` + `notes/<noteId>.assets/` tree with a manifest containing `schema`, `exportedAt`, `folderCount`, `noteCount`, and per-note content/asset hashes for incremental upload so unchanged assets are not re-uploaded).
- **Backup execution:**
  - Flush any pending autosaves before starting.
  - Report determinate progress (`phase`, `completedItems`, `totalItems`, current note/asset name) and honor a cancellation token.
  - Record the last successful backup timestamp and display it in the Cloud/Google Drive sheet.
- **Restore from backup (optional action in the same sheet):**
  - Allow the user to restore their library from the Google Drive backup, merging or replacing local folders/notes atomically only after all required files and assets have been downloaded and validated.

## Workflow 2: Search for `GoodNotes` Folder & Replicate Structure and Files

Create `GoodnotesDriveReplicator` in `lib/features/library/cloud/goodnotes_drive_replicator.dart`:

1. **Discovering the Goodnotes root folder:**
   - Search the user's Google Drive for non-trashed folders matching `GoodNotes` or `Goodnotes` (case-insensitive).
   - If multiple matching root folders exist, let the user pick which one to replicate (showing its path/modified date) or default to the primary root `GoodNotes` folder.
   - If no `GoodNotes` folder is found, show a clear, friendly message (`No Goodnotes folder was found in your Google Drive`).
2. **Exact folder structure replication:**
   - Traverse the remote `GoodNotes` folder tree breadth-first (all subfolders to arbitrary depth).
   - Create corresponding Greatnote `Folder` entries via `NoteRepository.createFolder`, preserving exact folder names and parent-child nesting under a top-level `Goodnotes` folder (or directly in the target folder, avoiding duplicate folder creation on re-runs by matching existing relative folder paths or a persisted remote-ID map).
3. **Importing all files into their replicated folders:**
   - For every file in each remote folder:
     - **`.goodnotes` files:** Download bytes and extract via `GoodnotesArchiveExtractor` (`Prompt 16`), creating a Greatnote note in the corresponding replicated local folder with all pages, embedded PDF backgrounds, and reconstructed editable vector strokes (`Pen` and `Highlighter`).
     - **`.pdf` files:** Download bytes and import via `DocumentImporter.importPdfAsNote(..., recoverGoodnotesInk: true, folderId: targetFolderId)`, so both Goodnotes PDF exports (with recoverable ink) and standard PDFs are imported into the exact same folder location.
     - **Unsupported files:** Skip unsupported ancillary files gracefully and list any skipped/failed items in the completion summary without aborting the rest of the replication.
   - Support cancellation between files, determinate progress (`Replicating folder X / Y`, `Importing file A of B`), and safe rollback of any partially imported note if cancelled mid-file.

## UI in the Library Screen

- Add a **Google Drive / Cloud** button in the library top bar or sidebar header (with a `48 x 48` minimum touch target, tooltip `'Google Drive'`, visible focus, and semantic label).
- Tapping it opens a clean, responsive modal sheet (`GoogleDriveSheet`):
  - **Connection status:** Shows whether Google Drive is disconnected or connected (displaying account name/email and a **Connect** or **Disconnect** button).
  - **Action 1 — Back up library now:** Runs the online backup with a determinate progress indicator, cancel button, and last-backup status.
  - **Action 2 — Import Goodnotes folder from Drive:** Searches for the `GoodNotes` folder, previews or starts replicating the folder tree and files with determinate progress, and refreshes the library view as folders and notes are created.
- Ensure the sheet fits without overflow at `390 x 844`, `800 x 1280`, and `1194 x 834` in both light and dark themes.

## Automated Tests

Add unit and widget tests using `FakeGoogleDriveClient`:

- **Authentication states:** connect, cancel sign-in, disconnect, and error handling when offline or unauthorized.
- **Online backup & restore:**
  - backing up a library with nested folders, colored folders, multi-page notes, strokes, sticky notes, PDF assets, and image assets uploads all data to `FakeGoogleDriveClient`;
  - incremental backup skips re-uploading unchanged note assets;
  - restoring into a fresh `InMemoryNoteRepository` / `FileNoteRepository` reproduces every folder, note, page, stroke, and asset identically.
- **Goodnotes folder search & exact replication:**
  - searching finds `GoodNotes` / `Goodnotes` case-insensitively and handles missing folders with a clear message;
  - a multi-level remote `GoodNotes` folder tree (e.g., `GoodNotes/MGY377/Lectures` and `GoodNotes/MGY377/Labs`) containing both `.goodnotes` archives and `.pdf` files replicates the exact nested folder hierarchy in `NoteRepository` and imports every `.goodnotes` and `.pdf` file into its matching folder with editable strokes and PDF backgrounds intact;
  - re-running replication reuses existing replicated folders cleanly rather than failing;
  - cancelling mid-replication keeps already-completed notes and rolls back the in-flight note cleanly.
- **Widget & accessibility tests:**
  - `GoogleDriveSheet` controls, progress states, semantic labels, and `48 x 48` touch targets.

Run formatting, static analysis, and tests:

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```
