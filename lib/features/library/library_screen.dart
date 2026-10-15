import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../app/theme/app_tokens.dart';
import '../../shared/layout/breakpoints.dart';
import '../editor/ai/ai_client.dart';
import '../editor/ink/ink_painter.dart';
import '../editor/ink/stroke.dart';
import '../editor/page/page_background.dart';
import '../editor/page/page_setup.dart';
import '../editor/document_io/document_importer.dart';
import '../editor/document_io/document_io_config.dart';
import '../editor/document_io/document_platform.dart';
import '../editor/document_io/pdf_exporter.dart';
import '../editor/widgets/export_options_sheet.dart';
import '../editor/widgets/document_io_progress_dialog.dart';

import 'file_note_repository.dart';
import 'library_dialogs.dart';
import 'library_models.dart';
import 'note_content.dart';
import 'note_editor_page.dart';
import 'note_repository.dart';
import 'shared_note_clipboard.dart';

/// Opens the library on this device, then shows it. With a [repository]
/// that one is used instead.
class LibraryHome extends StatefulWidget {
  const LibraryHome({super.key, this.repository});

  final NoteRepository? repository;

  @override
  State<LibraryHome> createState() => _LibraryHomeState();
}

class _LibraryHomeState extends State<LibraryHome> {
  late final Future<NoteRepository> _repository = widget.repository == null
      ? FileNoteRepository.openDefault()
      : Future<NoteRepository>.value(widget.repository);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<NoteRepository>(
      future: _repository,
      builder: (BuildContext context, AsyncSnapshot<NoteRepository> snapshot) {
        final NoteRepository? repository = snapshot.data;
        if (repository != null) {
          return LibraryScreen(repository: repository);
        }
        return Scaffold(
          backgroundColor: AppColors.of(context).background,
          body: Center(
            child: snapshot.hasError
                ? const Text("The library couldn't be opened.")
                : const CircularProgressIndicator(),
          ),
        );
      },
    );
  }
}

/// A short, human date for when something changed.
String formatModified(DateTime time, DateTime now) {
  const List<String> months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  String two(int value) => value.toString().padLeft(2, '0');
  final int days = DateTime(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime(time.year, time.month, time.day)).inDays;
  if (days == 0) {
    return 'Today, ${two(time.hour)}:${two(time.minute)}';
  }
  if (days == 1) {
    return 'Yesterday';
  }
  final String day = '${months[time.month - 1]} ${time.day}';
  return time.year == now.year ? day : '$day, ${time.year}';
}

enum _ItemAction {
  rename('Rename', Icons.drive_file_rename_outline),
  move('Move to…', Icons.drive_file_move_outline),
  duplicate('Duplicate', Icons.copy_outlined),
  exportPdf('Export as PDF', Icons.ios_share_outlined),
  delete('Delete', Icons.delete_outline);

  const _ItemAction(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// The home screen: the folders and notes in one folder, or the notes and
/// folders matching a search.
///
/// Folders come first, then notes, each sorted by [LibrarySort]. The open
/// folder, the sort, the view, and the search live in this state, so they
/// survive opening a note and coming back.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.repository,
    this.clock = DateTime.now,
    this.aiClient,
    this.documentPicker = const SystemDocumentPicker(),
    this.pdfRasterizer = const PdfrxRasterizer(),
    this.exportSink = const SystemExportSink(),
    this.documentIoConfig = const DocumentIoConfig(),
    this.initialNotationEnabled = true,
  });

  final NoteRepository repository;
  final DateTime Function() clock;

  /// Passed to the editor; tests supply one.
  final AiClient? aiClient;
  final DocumentPicker documentPicker;
  final PdfRasterizer pdfRasterizer;
  final ExportSink exportSink;
  final DocumentIoConfig documentIoConfig;

  /// Passed to the editor.
  final bool initialNotationEnabled;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final SharedNoteClipboard _sharedClipboard = SharedNoteClipboard();
  final ValueNotifier<bool> _stylusOnly = ValueNotifier<bool>(false);
  final TextEditingController _search = TextEditingController();
  final Map<String, Future<NoteContent>> _thumbnails =
      <String, Future<NoteContent>>{};
  String? _folderId;
  LibrarySort _sort = LibrarySort.modified;
  bool _grid = true;
  FolderListing? _listing;
  List<Folder> _path = const <Folder>[];
  Map<String, Folder> _folders = const <String, Folder>{};
  Map<String, int> _counts = const <String, int>{};
  int _loads = 0;

  NoteRepository get _repository => widget.repository;

  String get _query => _search.text.trim();

  @override
  void initState() {
    super.initState();
    _repository.addListener(_reload);
    _search.addListener(_reload);
    _reload();
  }

  @override
  void didUpdateWidget(LibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      oldWidget.repository.removeListener(_reload);
      widget.repository.addListener(_reload);
      _thumbnails.clear();
      _folderId = null;
      _reload();
    }
  }

  @override
  void dispose() {
    _repository.removeListener(_reload);
    _search.dispose();
    _stylusOnly.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final int load = ++_loads;
    final String query = _query;
    final FolderListing listing = query.isEmpty
        ? await _repository.list(_folderId)
        : await _repository.search(query);
    final List<Folder> path = await _repository.pathTo(_folderId);
    final List<Folder> folders = await _repository.allFolders();
    final Map<String, int> counts = await _repository.itemCounts();
    if (!mounted || load != _loads) {
      return;
    }
    setState(() {
      _listing = FolderListing(
        folders: List<Folder>.of(listing.folders)..sort(_sort.compareFolders),
        notes: List<NoteEntry>.of(listing.notes)..sort(_sort.compareNotes),
      );
      _path = path;
      _folders = <String, Folder>{
        for (final Folder folder in folders) folder.id: folder,
      };
      _counts = counts;
    });
  }

  void _openFolder(String? id) {
    if (id == _folderId && _query.isEmpty) {
      return;
    }
    setState(() {
      _folderId = id;
      _listing = null;
    });
    _search.clear();
    _reload();
  }

  void _setSort(LibrarySort sort) {
    setState(() => _sort = sort);
    _reload();
  }

  Future<NoteContent> _thumbnail(NoteEntry note) {
    final String key = '${note.id}@${note.modified.microsecondsSinceEpoch}';
    return _thumbnails.putIfAbsent(key, () => _repository.loadNote(note.id));
  }

  Future<void> _openNote(NoteEntry note) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => NoteEditorPage(
          repository: _repository,
          note: note,
          aiClient: widget.aiClient,
          documentPicker: widget.documentPicker,
          pdfRasterizer: widget.pdfRasterizer,
          exportSink: widget.exportSink,
          documentIoConfig: widget.documentIoConfig,
          sharedClipboard: _sharedClipboard,
          stylusOnly: _stylusOnly,
          initialNotationEnabled: widget.initialNotationEnabled,
        ),
      ),
    );
  }

  Future<void> _newNote() async {
    final NoteEntry note = await _repository.createNote(folderId: _folderId);
    if (mounted) {
      await _openNote(note);
    }
  }

  Future<void> _newFolder() async {
    final String? name = await askForName(
      context,
      title: 'New folder',
      action: 'Create',
    );
    if (name != null) {
      await _repository.createFolder(name, parentId: _folderId);
    }
  }

  Future<void> _importPdf() async {
    final PickedDocument? picked = await widget.documentPicker.pickPdf();
    if (picked == null || !mounted) return;
    NoteEntry? note;
    final ImportCancellationToken cancellation = ImportCancellationToken();
    final DocumentIoProgressResult result = await showDocumentIoProgress(
      context,
      title: 'Importing PDF',
      onCancel: cancellation.cancel,
      operation: (_) async {
        note =
            await DocumentImporter(
              rasterizer: widget.pdfRasterizer,
              config: widget.documentIoConfig,
            ).importPdfAsNote(
              repository: _repository,
              picked: picked,
              folderId: _folderId,
              cancellation: cancellation,
            );
      },
    );
    if (result.error == null && note != null && mounted) {
      await _openNote(note!);
    } else if (result.error != null && !result.cancelled) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.error is DocumentImportException
                ? (result.error! as DocumentImportException).message
                : 'This PDF could not be imported',
          ),
        ),
      );
    }
  }

  Future<void> _noteAction(NoteEntry note, _ItemAction action) async {
    switch (action) {
      case _ItemAction.rename:
        final String? title = await askForName(
          context,
          title: 'Rename note',
          action: 'Rename',
          initial: note.title,
        );
        if (title != null) {
          await _repository.renameNote(note.id, title);
        }
      case _ItemAction.move:
        final FolderChoice? choice = await pickFolder(
          context,
          title: 'Move "${note.title}" to',
          folders: _folders.values.toList(),
        );
        if (choice != null) {
          await _repository.moveNote(note.id, choice.folder?.id);
        }
      case _ItemAction.duplicate:
        await _repository.duplicateNote(note.id);
      case _ItemAction.exportPdf:
        final PdfExportOptions? options = await showExportOptions(
          context,
          allowCurrentPage: false,
        );
        if (options != null && mounted) {
          final NoteContent content = await _repository.loadNote(note.id);
          if (!mounted) return;
          final ExportCancellationToken cancellation =
              ExportCancellationToken();
          final DocumentIoProgressResult result = await showDocumentIoProgress(
            context,
            title: 'Exporting PDF',
            onCancel: cancellation.cancel,
            operation: (report) =>
                PdfExporter(
                  rasterizer: widget.pdfRasterizer,
                  sink: widget.exportSink,
                  config: widget.documentIoConfig,
                ).exportAndShare(
                  noteId: note.id,
                  title: note.title,
                  content: content,
                  repository: _repository,
                  options: options,
                  cancellation: cancellation,
                  onProgress: report,
                ),
          );
          if (result.error != null && !result.cancelled && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('This note could not be exported')),
            );
          }
        }
      case _ItemAction.delete:
        final bool confirmed = await confirmAction(
          context,
          title: 'Delete note?',
          message: '"${note.title}" and all of its pages will be deleted.',
          action: 'Delete',
        );
        if (confirmed) {
          await _repository.deleteNote(note.id);
        }
    }
  }

  Future<void> _folderAction(Folder folder, _ItemAction action) async {
    switch (action) {
      case _ItemAction.rename:
        final String? name = await askForName(
          context,
          title: 'Rename folder',
          action: 'Rename',
          initial: folder.name,
        );
        if (name != null) {
          await _repository.renameFolder(folder.id, name);
        }
      case _ItemAction.move:
        final Set<String> below = _subtree(folder.id);
        final FolderChoice? choice = await pickFolder(
          context,
          title: 'Move "${folder.name}" to',
          folders: _folders.values.toList(),
          excluded: below,
        );
        if (choice != null) {
          await _repository.moveFolder(folder.id, choice.folder?.id);
        }
      case _ItemAction.duplicate:
      case _ItemAction.exportPdf:
        return;
      case _ItemAction.delete:
        final FolderTotals totals = await _repository.totals(folder.id);
        if (!mounted) {
          return;
        }
        final bool confirmed = await confirmAction(
          context,
          title: 'Delete folder?',
          message: _deleteMessage(folder, totals),
          action: 'Delete',
        );
        if (confirmed) {
          await _repository.deleteFolder(folder.id);
        }
    }
  }

  static String _deleteMessage(Folder folder, FolderTotals totals) {
    String count(int n, String one) => n == 1 ? '1 $one' : '$n ${one}s';
    if (totals.notes == 0 && totals.folders == 0) {
      return '"${folder.name}" is empty and will be deleted.';
    }
    final List<String> parts = <String>[
      if (totals.notes > 0) count(totals.notes, 'note'),
      if (totals.folders > 0) count(totals.folders, 'folder'),
    ];
    return '"${folder.name}" and the ${parts.join(' and ')} inside it will '
        'be deleted.';
  }

  Set<String> _subtree(String id) {
    final Set<String> found = <String>{id};
    bool grew = true;
    while (grew) {
      grew = false;
      for (final Folder folder in _folders.values) {
        if (found.contains(folder.parentId) && found.add(folder.id)) {
          grew = true;
        }
      }
    }
    return found;
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final WindowSizeClass sizeClass = WindowSizeClass.fromWidth(
      MediaQuery.sizeOf(context).width,
    );
    final bool compact = sizeClass == WindowSizeClass.compact;
    return PopScope(
      canPop: _folderId == null,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) {
          _openFolder(_path.length > 1 ? _path[_path.length - 2].id : null);
        }
      },
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: _LibraryBar(
          path: _path,
          compact: compact,
          search: _search,
          sort: _sort,
          grid: _grid,
          onOpenFolder: _openFolder,
          onSort: _setSort,
          onToggleView: () => setState(() => _grid = !_grid),
          onNewFolder: _newFolder,
          onImportPdf: _importPdf,
        ),
        floatingActionButton: _NewNoteButton(onPressed: _newNote),
        body: SafeArea(top: false, child: _buildBody(context, compact)),
      ),
    );
  }

  Widget _buildBody(BuildContext context, bool compact) {
    final FolderListing? listing = _listing;
    if (listing == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (listing.isEmpty) {
      return _EmptyState(query: _query, onNewNote: _newNote);
    }
    final bool searching = _query.isNotEmpty;
    final DateTime now = widget.clock();
    final List<Widget> folders = <Widget>[
      for (final Folder folder in listing.folders)
        _LibraryItem(
          key: ValueKey<String>('folder-${folder.id}'),
          grid: _grid,
          kind: 'Folder',
          title: folder.name,
          subtitle: searching
              ? _locationOf(folder.parentId)
              : _itemSummary(folder),
          date: formatModified(folder.modified, now),
          leading: const _FolderArt(),
          actions: const <_ItemAction>[
            _ItemAction.rename,
            _ItemAction.move,
            _ItemAction.delete,
          ],
          onOpen: () => _openFolder(folder.id),
          onAction: (_ItemAction action) => _folderAction(folder, action),
        ),
    ];
    final List<Widget> notes = <Widget>[
      for (final NoteEntry note in listing.notes)
        _LibraryItem(
          key: ValueKey<String>('note-${note.id}'),
          grid: _grid,
          kind: 'Note',
          title: note.title,
          subtitle: searching ? _locationOf(note.folderId) : null,
          date: formatModified(note.modified, now),
          leading: _NoteThumbnail(
            content: _thumbnail(note),
            noteId: note.id,
            repository: _repository,
            rasterizer: widget.pdfRasterizer,
          ),
          actions: _ItemAction.values,
          onOpen: () => _openNote(note),
          onAction: (_ItemAction action) => _noteAction(note, action),
        ),
    ];
    final EdgeInsets padding = EdgeInsets.fromLTRB(
      compact ? AppSpacing.md : AppSpacing.lg,
      AppSpacing.xs,
      compact ? AppSpacing.md : AppSpacing.lg,
      // Room for the floating button.
      AppSpacing.xxl + AppSpacing.xl,
    );
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppSizes.maxContentWidth),
        child: _grid
            ? GridView(
                padding: padding,
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: compact ? 180 : 220,
                  mainAxisSpacing: AppSpacing.md,
                  crossAxisSpacing: AppSpacing.md,
                  childAspectRatio: 0.74,
                ),
                children: <Widget>[...folders, ...notes],
              )
            : ListView(
                padding: padding,
                children: <Widget>[...folders, ...notes],
              ),
      ),
    );
  }

  String _locationOf(String? folderId) {
    final Folder? folder = folderId == null ? null : _folders[folderId];
    return folder == null ? 'In Library' : 'In ${folder.name}';
  }

  String _itemSummary(Folder folder) {
    final int items = _counts[folder.id] ?? 0;
    return switch (items) {
      0 => 'Empty',
      1 => '1 item',
      _ => '$items items',
    };
  }
}

/// The top bar: where you are, search, sort, view, and New folder.
class _LibraryBar extends StatelessWidget implements PreferredSizeWidget {
  const _LibraryBar({
    required this.path,
    required this.compact,
    required this.search,
    required this.sort,
    required this.grid,
    required this.onOpenFolder,
    required this.onSort,
    required this.onToggleView,
    required this.onNewFolder,
    required this.onImportPdf,
  });

  final List<Folder> path;
  final bool compact;
  final TextEditingController search;
  final LibrarySort sort;
  final bool grid;
  final ValueChanged<String?> onOpenFolder;
  final ValueChanged<LibrarySort> onSort;
  final VoidCallback onToggleView;
  final VoidCallback onNewFolder;
  final VoidCallback onImportPdf;

  @override
  Size get preferredSize => Size.fromHeight(
    AppSizes.appBarHeight +
        (compact ? AppSizes.minTouchTarget + AppSpacing.xs : 0),
  );

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final Widget field = _SearchField(controller: search);
    return Material(
      color: colors.background,
      child: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppSizes.maxContentWidth,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    height: AppSizes.appBarHeight,
                    child: Row(
                      children: <Widget>[
                        if (path.isNotEmpty)
                          IconButton(
                            tooltip: 'Up one folder',
                            onPressed: () => onOpenFolder(
                              path.length > 1 ? path[path.length - 2].id : null,
                            ),
                            icon: const Icon(Icons.arrow_back),
                          )
                        else
                          const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: _Breadcrumbs(
                            path: path,
                            onOpenFolder: onOpenFolder,
                          ),
                        ),
                        if (!compact) SizedBox(width: 260, child: field),
                        PopupMenuButton<LibrarySort>(
                          tooltip: 'Sort',
                          icon: const Icon(Icons.sort),
                          initialValue: sort,
                          onSelected: onSort,
                          itemBuilder: (BuildContext context) {
                            return <PopupMenuEntry<LibrarySort>>[
                              for (final LibrarySort option
                                  in LibrarySort.values)
                                CheckedPopupMenuItem<LibrarySort>(
                                  value: option,
                                  checked: option == sort,
                                  child: Text(option.label),
                                ),
                            ];
                          },
                        ),
                        IconButton(
                          tooltip: grid ? 'Show as list' : 'Show as grid',
                          onPressed: onToggleView,
                          icon: Icon(
                            grid
                                ? Icons.view_list_outlined
                                : Icons.grid_view_outlined,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Import PDF',
                          onPressed: onImportPdf,
                          icon: const Icon(Icons.picture_as_pdf_outlined),
                        ),
                        IconButton(
                          tooltip: 'New folder',
                          onPressed: onNewFolder,
                          icon: const Icon(Icons.create_new_folder_outlined),
                        ),
                      ],
                    ),
                  ),
                  if (compact)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.sm,
                        0,
                        AppSpacing.sm,
                        AppSpacing.xs,
                      ),
                      child: field,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final OutlineInputBorder border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadii.medium),
      borderSide: BorderSide(color: colors.divider),
    );
    return SizedBox(
      height: AppSizes.minTouchTarget,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (BuildContext context, TextEditingValue value, Widget? _) {
          return TextField(
            controller: controller,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search notes',
              isDense: true,
              filled: true,
              fillColor: colors.surface,
              prefixIcon: const Icon(Icons.search, size: AppSizes.icon),
              suffixIcon: value.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: controller.clear,
                      icon: const Icon(Icons.close, size: AppSizes.icon),
                    ),
              border: border,
              enabledBorder: border,
              focusedBorder: border.copyWith(
                borderSide: BorderSide(
                  color: colors.focus,
                  width: AppSizes.focusRingWidth,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.path, required this.onOpenFolder});

  final List<Folder> path;
  final ValueChanged<String?> onOpenFolder;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final List<Widget> crumbs = <Widget>[];
    final List<(String?, String)> stops = <(String?, String)>[
      (null, 'Library'),
      for (final Folder folder in path) (folder.id, folder.name),
    ];
    for (int i = 0; i < stops.length; i++) {
      final (String? id, String name) = stops[i];
      final bool last = i == stops.length - 1;
      if (i > 0) {
        crumbs.add(
          ExcludeSemantics(
            child: Icon(
              Icons.chevron_right,
              size: AppSizes.icon,
              color: colors.textSecondary,
            ),
          ),
        );
      }
      crumbs.add(
        last
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                child: Semantics(
                  header: true,
                  child: Text(
                    name,
                    style: text.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
            : TextButton(
                onPressed: () => onOpenFolder(id),
                style: TextButton.styleFrom(
                  foregroundColor: colors.textSecondary,
                  minimumSize: const Size(
                    AppSizes.minTouchTarget,
                    AppSizes.minTouchTarget,
                  ),
                ),
                child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
      );
    }
    // Starts at the leading edge; a trail too long to fit scrolls, showing
    // its end.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Row(children: crumbs),
          ),
        );
      },
    );
  }
}

/// The primary action, floating at the bottom: the accent color and the
/// floating shadow, like the editor's palette.
class _NewNoteButton extends StatelessWidget {
  const _NewNoteButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final BorderRadius radius = BorderRadius.circular(AppRadii.large);
    return Tooltip(
      message: 'New note',
      excludeFromSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: AppShadows.floating(colors),
        ),
        child: FilledButton.icon(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: colors.accent,
            foregroundColor: colors.onAccent,
            minimumSize: const Size(0, AppSpacing.xxl + AppSpacing.xs),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            shape: RoundedRectangleBorder(borderRadius: radius),
          ),
          icon: const Icon(Icons.add),
          label: const Text('New note'),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.query, required this.onNewNote});

  final String query;
  final VoidCallback onNewNote;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final bool searching = query.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              searching ? Icons.search_off : Icons.note_alt_outlined,
              size: AppSpacing.xxl,
              color: colors.textSecondary,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              searching ? 'No notes match "$query"' : 'Nothing here yet',
              style: text.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (!searching) ...<Widget>[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Create a note to start writing.',
                style: text.bodyMedium?.copyWith(color: colors.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton.icon(
                onPressed: onNewNote,
                icon: const Icon(Icons.add),
                label: const Text('New note'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A folder or a note, as a card in the grid or a row in the list, with
/// an overflow menu that a long press also opens.
class _LibraryItem extends StatefulWidget {
  const _LibraryItem({
    super.key,
    required this.grid,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.date,
    required this.leading,
    required this.actions,
    required this.onOpen,
    required this.onAction,
  });

  final bool grid;
  final String kind;
  final String title;
  final String? subtitle;
  final String date;
  final Widget leading;
  final List<_ItemAction> actions;
  final VoidCallback onOpen;
  final ValueChanged<_ItemAction> onAction;

  @override
  State<_LibraryItem> createState() => _LibraryItemState();
}

class _LibraryItemState extends State<_LibraryItem> {
  final GlobalKey<PopupMenuButtonState<_ItemAction>> _menu =
      GlobalKey<PopupMenuButtonState<_ItemAction>>();

  void _openMenu() => _menu.currentState?.showButtonMenu();

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final Widget menu = PopupMenuButton<_ItemAction>(
      key: _menu,
      tooltip: 'More actions for ${widget.title}',
      icon: const Icon(Icons.more_vert),
      onSelected: widget.onAction,
      itemBuilder: (BuildContext context) {
        return <PopupMenuEntry<_ItemAction>>[
          for (final _ItemAction action in widget.actions)
            PopupMenuItem<_ItemAction>(
              value: action,
              child: Row(
                children: <Widget>[
                  Icon(action.icon, size: AppSizes.icon),
                  const SizedBox(width: AppSpacing.sm),
                  Text(action.label),
                ],
              ),
            ),
        ];
      },
    );
    final Widget caption = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          widget.title,
          style: text.titleSmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppSpacing.xxs),
        Text(
          widget.subtitle == null
              ? widget.date
              : '${widget.subtitle} · ${widget.date}',
          style: text.bodySmall?.copyWith(color: colors.textSecondary),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
    final Widget body = widget.grid
        ? Padding(
            padding: const EdgeInsets.all(AppSpacing.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(child: widget.leading),
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(
                    AppSpacing.xxs,
                    AppSpacing.xs,
                    AppSizes.minTouchTarget,
                    AppSpacing.xxs,
                  ),
                  child: caption,
                ),
              ],
            ),
          )
        : ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                AppSpacing.sm,
                AppSpacing.xs,
                AppSizes.minTouchTarget + AppSpacing.xs,
                AppSpacing.xs,
              ),
              child: Row(
                children: <Widget>[
                  SizedBox(width: 44, height: 56, child: widget.leading),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(child: caption),
                ],
              ),
            ),
          );
    final BorderRadius radius = BorderRadius.circular(AppRadii.large);
    final Widget card = Semantics(
      container: true,
      button: true,
      label: '${widget.kind}, ${widget.title}, modified ${widget.date}',
      onTap: widget.onOpen,
      onLongPress: _openMenu,
      customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
        for (final _ItemAction action in widget.actions)
          CustomSemanticsAction(label: action.label): () =>
              widget.onAction(action),
      },
      child: Material(
        color: widget.grid ? colors.surface : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: widget.onOpen,
          onLongPress: _openMenu,
          hoverColor: colors.textPrimary.withValues(alpha: 0.04),
          focusColor: colors.textPrimary.withValues(alpha: 0.08),
          child: ExcludeSemantics(child: body),
        ),
      ),
    );
    return Padding(
      padding: widget.grid
          ? EdgeInsets.zero
          : const EdgeInsets.only(bottom: AppSpacing.xxs),
      child: DecoratedBox(
        decoration: widget.grid
            ? BoxDecoration(
                borderRadius: radius,
                border: Border.all(
                  color: colors.divider,
                  width: AppSizes.hairline,
                ),
                boxShadow: AppShadows.paper(colors),
              )
            : const BoxDecoration(),
        child: Stack(
          children: <Widget>[
            Positioned.fill(child: card),
            PositionedDirectional(
              end: 0,
              bottom: widget.grid ? 0 : null,
              top: widget.grid ? null : 0,
              child: widget.grid
                  ? menu
                  : SizedBox(height: 72, child: Center(child: menu)),
            ),
            if (!widget.grid)
              const SizedBox(height: 72, width: double.infinity),
          ],
        ),
      ),
    );
  }
}

class _FolderArt extends StatelessWidget {
  const _FolderArt();

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.selected,
        borderRadius: BorderRadius.circular(AppRadii.medium),
      ),
      child: Center(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            return Icon(
              Icons.folder_outlined,
              color: colors.accent,
              size:
                  math.min(constraints.maxWidth, constraints.maxHeight) * 0.42,
            );
          },
        ),
      ),
    );
  }
}

/// A note's first page, small, once its content has loaded.
class _NoteThumbnail extends StatelessWidget {
  const _NoteThumbnail({
    required this.content,
    required this.noteId,
    required this.repository,
    required this.rasterizer,
  });

  final Future<NoteContent> content;
  final String noteId;
  final NoteRepository repository;
  final PdfRasterizer rasterizer;

  Future<Uint8List?> _asset(String id) async {
    try {
      return (await repository.readAsset(noteId, id)).bytes;
    } on Object {
      return null;
    }
  }

  Future<Uint8List?> _pdf(StoredPage page) async {
    final source = page.pdfSource;
    if (source == null) return null;
    final Uint8List? bytes = await _asset(source.assetId);
    if (bytes == null) return null;
    final double ratio = source.pageSize.height / source.pageSize.width;
    return (await rasterizer.render(
      bytes,
      source.pageIndex,
      pixelWidth: 384,
      pixelHeight: math.max(1, (384 * ratio).round()),
    )).png;
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.small),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadii.small),
          border: Border.all(color: colors.divider, width: AppSizes.hairline),
        ),
        child: ColoredBox(
          color: colors.writingSurface,
          child: FutureBuilder<NoteContent>(
            future: content,
            builder:
                (BuildContext context, AsyncSnapshot<NoteContent> snapshot) {
                  final NoteContent? note = snapshot.data;
                  if (note == null) {
                    return const SizedBox.expand();
                  }
                  final StoredPage page = note.pages.first;
                  final Size paper = _ThumbnailPainter.pageSizeOf(page);
                  return FittedBox(
                    fit: BoxFit.fitWidth,
                    alignment: Alignment.topCenter,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: paper.width,
                      height: paper.height,
                      child: Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          CustomPaint(
                            painter: _ThumbnailPainter(
                              page: page,
                              brightness: Theme.of(context).brightness,
                              rule: colors.pageRule,
                              marginRule: colors.pageMarginRule,
                              paintInk: false,
                            ),
                          ),
                          if (page.pdfSource != null)
                            FutureBuilder<Uint8List?>(
                              future: _pdf(page),
                              builder: (_, AsyncSnapshot<Uint8List?> data) {
                                return data.data == null
                                    ? const SizedBox.expand()
                                    : Image.memory(
                                        data.data!,
                                        fit: BoxFit.fill,
                                      );
                              },
                            ),
                          for (final image in page.images)
                            Positioned(
                              left: image.center.x - image.size.width / 2,
                              top: image.center.y - image.size.height / 2,
                              width: image.size.width,
                              height: image.size.height,
                              child: Transform.rotate(
                                angle: image.rotation,
                                child: FutureBuilder<Uint8List?>(
                                  future: _asset(image.assetId),
                                  builder: (_, AsyncSnapshot<Uint8List?> data) {
                                    return data.data == null
                                        ? const SizedBox.expand()
                                        : Image.memory(
                                            data.data!,
                                            fit: BoxFit.fill,
                                          );
                                  },
                                ),
                              ),
                            ),
                          CustomPaint(
                            painter: _ThumbnailPainter(
                              page: page,
                              brightness: Theme.of(context).brightness,
                              rule: colors.pageRule,
                              marginRule: colors.pageMarginRule,
                              paintBackground: false,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
          ),
        ),
      ),
    );
  }
}

class _ThumbnailPainter extends CustomPainter {
  const _ThumbnailPainter({
    required this.page,
    required this.brightness,
    required this.rule,
    required this.marginRule,
    this.paintBackground = true,
    this.paintInk = true,
  });

  /// The smallest page a fit or infinite page is shown as, so a few lines
  /// of ink do not fill the card.
  static const Size _minimumPage = Size(640, 480);

  final StoredPage page;
  final Brightness brightness;
  final Color rule;
  final Color marginRule;
  final bool paintBackground;
  final bool paintInk;

  static Size pageSizeOf(StoredPage page) {
    if (page.pdfSource != null) return page.pdfSource!.pageSize;
    if (page.setup.size == PageSize.custom) return page.setup.customSize!;
    final Size? fixed = page.setup.size.fixedSize;
    if (fixed != null) {
      return fixed;
    }
    double right = page.extent?.width ?? _minimumPage.width;
    double bottom = page.extent?.height ?? _minimumPage.height;
    for (final Stroke stroke in page.strokes) {
      right = math.max(right, stroke.bounds.right);
      bottom = math.max(bottom, stroke.bounds.bottom);
    }
    return Size(right, bottom);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final Size pageSize = pageSizeOf(page);
    if (size.isEmpty || pageSize.isEmpty) {
      return;
    }
    // The top of the page, as wide as the card.
    final double scale = size.width / pageSize.width;
    canvas
      ..save()
      ..clipRect(Offset.zero & size)
      ..scale(scale);
    final Size visible = Size(pageSize.width, size.height / scale);
    if (paintBackground) {
      PageBackgroundPainter(
        background: page.setup.background,
        rule: rule,
        marginRule: marginRule,
      ).paint(canvas, visible);
    }
    if (paintInk) {
      for (final Stroke stroke in page.strokes) {
        if (stroke.bounds.top > visible.height) {
          continue;
        }
        paintInkStroke(
          canvas,
          color: stroke.style.ink.resolve(brightness),
          width: stroke.style.width,
          path: stroke.path,
          origin: stroke.points.first,
          isDot: stroke.isDot,
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ThumbnailPainter oldDelegate) {
    return oldDelegate.page != page ||
        oldDelegate.brightness != brightness ||
        oldDelegate.rule != rule ||
        oldDelegate.marginRule != marginRule ||
        oldDelegate.paintBackground != paintBackground ||
        oldDelegate.paintInk != paintInk;
  }
}
