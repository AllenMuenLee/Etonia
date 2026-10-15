import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import '../editor/ai/ai_assistant_controller.dart';
import '../editor/ai/ai_client.dart';
import '../editor/editor_screen.dart';
import '../editor/document_io/document_io_config.dart';
import '../editor/document_io/document_models.dart';
import '../editor/document_io/document_platform.dart';
import '../editor/page/note_document.dart';
import 'library_dialogs.dart';
import 'library_models.dart';
import 'note_autosaver.dart';
import 'note_content.dart';
import 'note_repository.dart';
import 'shared_note_clipboard.dart';

/// Opens [note] from [repository] in the editor and keeps it saved.
///
/// Shows progress while the note loads and a message if it cannot be read.
/// The editor's navigation control leaves, and its title renames the note.
/// Changes are saved by a [NoteAutosaver], and once more on the way out.
class NoteEditorPage extends StatefulWidget {
  const NoteEditorPage({
    super.key,
    required this.repository,
    required this.note,
    this.saveDelay = const Duration(milliseconds: 800),
    this.aiClient,
    this.documentPicker = const SystemDocumentPicker(),
    this.pdfRasterizer = const PdfrxRasterizer(),
    this.exportSink = const SystemExportSink(),
    this.documentIoConfig = const DocumentIoConfig(),
    this.sharedClipboard,
    this.stylusOnly,
    this.initialNotationEnabled = true,
  });

  final NoteRepository repository;
  final NoteEntry note;
  final Duration saveDelay;

  /// Passed to the editor; tests supply one.
  final AiClient? aiClient;
  final DocumentPicker documentPicker;
  final PdfRasterizer pdfRasterizer;
  final ExportSink exportSink;
  final DocumentIoConfig documentIoConfig;
  final SharedNoteClipboard? sharedClipboard;

  /// Passed to the editor, so the choice carries from note to note.
  final ValueNotifier<bool>? stylusOnly;

  /// Passed to the editor.
  final bool initialNotationEnabled;

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  NoteDocument? _document;
  NoteAutosaver? _autosaver;
  Object? _error;
  late String _title = widget.note.title;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final NoteContent content = await widget.repository.loadNote(
        widget.note.id,
      );
      final clipboard = await widget.sharedClipboard?.materialize(
        widget.repository,
        widget.note.id,
      );
      final Set<String> referenced = _referencedAssets(content)
        ..addAll(<String>{
          for (final NoteImageElement image
              in clipboard?.images ?? const <NoteImageElement>[])
            image.assetId,
        });
      await widget.repository.cleanupAssets(widget.note.id, referenced);
      if (!mounted) {
        return;
      }
      final NoteDocument document = content.toDocument();
      for (final NotePage page in document.pages) {
        page.ink.takeClipboard(clipboard);
      }
      setState(() {
        _document = document;
        _autosaver = NoteAutosaver(
          document: document,
          delay: widget.saveDelay,
          save: (NoteContent content) {
            return widget.repository.saveNote(widget.note.id, content);
          },
          onError: _onSaveFailed,
        );
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = error);
      }
    }
  }

  void _onSaveFailed(Object error) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text("Couldn't save this note. It will be tried again."),
      ),
    );
  }

  Future<void> _rename() async {
    final String? title = await askForName(
      context,
      title: 'Rename note',
      action: 'Rename',
      initial: _title,
    );
    if (title == null || title == _title || !mounted) {
      return;
    }
    await widget.repository.renameNote(widget.note.id, title);
    if (mounted) {
      setState(() => _title = title);
    }
  }

  void _leave() {
    _autosaver?.flush();
    Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    // Read the pages before they go; the save finishes on its own.
    _autosaver?.flush();
    _autosaver?.dispose();
    final NoteDocument? document = _document;
    if (document != null) {
      final NoteContent content = NoteContent.fromDocument(document);
      final Set<String> referenced = _referencedAssets(content);
      for (final NotePage page in document.pages) {
        for (final NoteImageElement image
            in page.ink.clipboard?.images ?? const <NoteImageElement>[]) {
          referenced.add(image.assetId);
        }
      }
      widget.repository.cleanupAssets(widget.note.id, referenced);
      document.dispose();
    }
    super.dispose();
  }

  static Set<String> _referencedAssets(NoteContent content) => <String>{
    for (final StoredPage page in content.pages)
      if (page.pdfSource != null) page.pdfSource!.assetId,
    for (final StoredPage page in content.pages)
      for (final image in page.images) image.assetId,
    // What saved AI conversations were drawn over, read again on reopening.
    ...AiAssistantController.referencedAssets(content.aiSession),
  };

  @override
  Widget build(BuildContext context) {
    final NoteDocument? document = _document;
    if (document != null) {
      return EditorScreen(
        document: document,
        title: _title,
        onBack: _leave,
        onTitlePressed: _rename,
        aiClient: widget.aiClient,
        repository: widget.repository,
        noteId: widget.note.id,
        documentPicker: widget.documentPicker,
        pdfRasterizer: widget.pdfRasterizer,
        exportSink: widget.exportSink,
        documentIoConfig: widget.documentIoConfig,
        stylusOnly: widget.stylusOnly,
        initialNotationEnabled: widget.initialNotationEnabled,
        assetReader: (String assetId) async {
          try {
            return (await widget.repository.readAsset(
              widget.note.id,
              assetId,
            )).bytes;
          } on Object {
            return null;
          }
        },
        onClipboardChanged: (clipboard) {
          widget.sharedClipboard?.capture(
            widget.repository,
            widget.note.id,
            clipboard,
          );
        },
      );
    }
    final AppColors colors = AppColors.of(context);
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.background,
        leading: BackButton(onPressed: () => Navigator.of(context).maybePop()),
        title: Text(_title),
      ),
      body: Center(
        child: _error == null
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Text(
                  "This note couldn't be opened.",
                  style: Theme.of(context).textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
              ),
      ),
    );
  }
}
