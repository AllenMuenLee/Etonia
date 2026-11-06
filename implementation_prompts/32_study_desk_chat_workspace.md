# Study Desk chat workspace

Open the Study Desk from the library directly into a fresh chat. Use a quiet,
ChatGPT-style layout: persistent navigation on the left on wide windows and a
centered reading column with the composer at the bottom on the right. On narrow
windows, show navigation in a dismissible drawer. Keep existing citation previews,
handwriting, chat history, grading, and practice players working.

Switch the main content between Chat and Study material. Within Study material,
switch between Flashcards and Tests. The sidebar's history follows the active
tab, searches saved titles, and keeps conversation rename, pin, class assignment,
export, and delete actions available.

Place Classes above history. Users can create a class with a name, color, and
optional notes or folders. Clicking a class opens its page on the right, with a
centered chat composer and all past chats, tests, and flashcard decks below it.
Typing keeps the class page visible; submitting opens the full conversation in
that class. Reopening saved work opens its existing chat or player. Remove the
General study section; New chat starts a conversation outside any class.
Opening class material restores its owning class context;
explicit ownership wins when multiple classes share the same notes.

Sources are optional. Without attached sources, retrieve relevant passages from
all non-deleted notes throughout the in-app library and its folders. Keep this
fallback separate from the explicit source list. Selected sources restrict
retrieval; disabling every selected source must never widen to the library.
Apply the same scope to flashcard and test generation. Keep citations grounded
in retrieved material, and use general tutoring when the library is empty.

Provide Add to library or folder on saved test cards and the active paper.
Export the paper, including current handwriting and available grading, to a
writable PDF note using the existing import pipeline. Let users choose Library
or any nested folder, stay in the Study Desk after saving, and leave the library
unchanged if they cancel the destination picker. Surface failures and avoid
starting duplicate saves while an export is in progress.

Verify class navigation, history and mode switching, mobile and large-text
layouts, retrieval across folders, source scoping, exclusion of deleted notes,
and saving/cancelling at both library root and a nested folder. Run the existing
study, practice, and test-paper regressions and static analysis.
