import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import '../../backend/backend_service.dart';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../app/theme/app_tokens.dart';
import '../../app/theme/app_icons.dart';
import '../../shared/layout/breakpoints.dart';
import '../editor/ai/ai_client.dart';
import '../editor/ink/input_defaults.dart';
import '../editor/ink/pen_settings.dart';
import '../editor/page/page_setup.dart';
import '../editor/document_io/document_importer.dart';
import '../editor/document_io/document_io_config.dart';
import '../editor/document_io/document_platform.dart';
import '../editor/document_io/goodnotes_archive_extractor.dart';
import '../editor/document_io/pdf_exporter.dart';
import '../editor/widgets/export_options_sheet.dart';
import '../editor/widgets/document_io_progress_dialog.dart';
import '../editor/widgets/tool_palette.dart';

import 'cloud/auto_backup_scheduler.dart';
import 'cloud/cloud_sync_state.dart';
import 'cloud/goodnotes_drive_replicator.dart';
import 'cloud/google_drive_backup_service.dart';
import 'cloud/google_drive_client.dart';
import 'cloud/google_drive_sheet.dart';
import 'file_note_repository.dart';
import 'library_dialogs.dart';
import 'library_models.dart';
import 'note_content.dart';
import 'note_editor_page.dart';
import 'note_repository.dart';
import 'note_tabs_page.dart';
import 'note_thumbnails.dart';
import 'open_notes.dart';
import 'shared_note_clipboard.dart';
import '../../shared/widgets/ignore_keyboard.dart';
import '../../shared/widgets/processing.dart';
import '../../shared/widgets/pressable.dart';
import '../payment/in_app_purchase_gateway.dart';
import '../payment/payment_models.dart';
import '../payment/payment_page.dart';
import '../payment/plans_button.dart';
import '../payment/subscription_controller.dart';

/// Opens the library on this device, then shows it. With a [repository]
/// that one is used instead.
class LibraryHome extends StatefulWidget {
  const LibraryHome({super.key, this.repository, this.subscription});

  final NoteRepository? repository;

  /// The user's plan and AI credits. Without one, the device's library
  /// gets one beside it, connected to the platform store; a library
  /// supplied from outside gets one with no store.
  final SubscriptionController? subscription;

  @override
  State<LibraryHome> createState() => _LibraryHomeState();
}

class _LibraryHomeState extends State<LibraryHome> {
  late final Future<NoteRepository> _repository = widget.repository == null
      ? FileNoteRepository.openDefault()
      : Future<NoteRepository>.value(widget.repository);

  SubscriptionController? _subscription;

  /// The store's subscription, kept beside the device's library.
  SubscriptionController? _subscriptionFor(NoteRepository repository) {
    if (widget.repository != null || repository is! FileNoteRepository) {
      return null;
    }
    return _subscription ??= SubscriptionController(
      store: FileSubscriptionStore(
        File('${repository.directory.path}/subscription.json'),
      ),
      gateway: PlatformInAppPurchaseGateway(),
      backend: BackendService.instance,
      config: const PaymentConfig.fromEnvironment(),
    )..load().then((void _) => _subscription?.connectStore());
  }

  @override
  void dispose() {
    _subscription?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<NoteRepository>(
      future: _repository,
      builder: (BuildContext context, AsyncSnapshot<NoteRepository> snapshot) {
        final NoteRepository? repository = snapshot.data;
        if (repository != null) {
          return LibraryScreen(
            repository: repository,
            subscription: widget.subscription ?? _subscriptionFor(repository),
          );
        }
        return Scaffold(
          backgroundColor: AppColors.of(context).background,
          body: Center(
            child: snapshot.hasError
                ? const Text("The library couldn't be opened.")
                : const SizedBox(
                    width: AppSpacing.xxl * 2,
                    child: ShimmerTrack(semanticsLabel: 'Loading'),
                  ),
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
  rename('Rename', AppIcons.rename),
  color('Color…', AppIcons.color),
  move('Move to…', AppIcons.move),
  duplicate('Duplicate', AppIcons.duplicate),
  exportPdf('Export as PDF', AppIcons.share),
  delete('Delete', AppIcons.delete),
  restore('Restore', AppIcons.restore),
  deleteForever('Delete permanently', AppIcons.deleteForever);

  /// Shown in the danger color.
  bool get destructive => this == delete || this == deleteForever;

  const _ItemAction(this.label, this.icon);

  final String label;
  final IconData icon;

  static const List<_ItemAction> forFolders = <_ItemAction>[
    rename,
    color,
    move,
    delete,
  ];

  static const List<_ItemAction> forNotes = <_ItemAction>[
    rename,
    move,
    duplicate,
    exportPdf,
    delete,
  ];

  static const List<_ItemAction> forDeleted = <_ItemAction>[
    restore,
    deleteForever,
  ];
}

/// One entry of a popup menu: an icon, the label, and a check when it is
/// the current choice. Destructive entries are set in the danger color.
PopupMenuItem<T> _menuItem<T>(
  BuildContext context, {
  required T value,
  required String label,
  IconData? icon,
  bool checked = false,
  bool danger = false,
}) {
  final AppColors colors = AppColors.of(context);
  final Color foreground = danger ? colors.danger : colors.textPrimary;
  return PopupMenuItem<T>(
    value: value,
    height: 44,
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
    child: Row(
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(
            icon,
            size: 20,
            color: danger ? colors.danger : colors.textSecondary,
          ),
          const SizedBox(width: AppSpacing.sm),
        ],
        Expanded(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium!.copyWith(
              color: foreground,
              fontWeight: checked ? FontWeight.w600 : null,
            ),
          ),
        ),
        if (checked) ...<Widget>[
          const SizedBox(width: AppSpacing.md),
          Icon(AppIcons.check, size: 18, color: colors.accent),
        ],
      ],
    ),
  );
}

/// A note or a folder being dragged, by a long press, to another folder.
@immutable
class _Dragged {
  const _Dragged.note(NoteEntry this.note) : folder = null;
  const _Dragged.folder(Folder this.folder) : note = null;

  final NoteEntry? note;
  final Folder? folder;

  String get title => note?.title ?? folder!.name;

  /// The folder it is in now; null at the top level.
  String? get parentId => note != null ? note!.folderId : folder!.parentId;
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
    this.googleDriveClient,
    this.cloudStateStore,
    this.subscription,
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

  /// Google sign-in and Drive; tests supply a fake. Made on first use
  /// otherwise, so nothing reaches the platform until then.
  final GoogleDriveClient? googleDriveClient;

  /// What is remembered about Google Drive between launches; kept beside
  /// the library by default.
  final CloudStateStore? cloudStateStore;

  /// The user's plan and AI credits, shown in the top bar and passed to
  /// the editor. Without one, the screen keeps its own beside the library,
  /// with no store to buy from.
  final SubscriptionController? subscription;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final SharedNoteClipboard _sharedClipboard = SharedNoteClipboard();
  final ValueNotifier<bool> _stylusOnly = ValueNotifier<bool>(
    InputDefaults.stylusOnly,
  );
  final ValueNotifier<PenSettings> _penSettings = ValueNotifier<PenSettings>(
    PenSettings.defaults(),
  );
  final ValueNotifier<PalettePlacement> _palettePlacement =
      ValueNotifier<PalettePlacement>(const PalettePlacement());
  final OpenNotes _openNotes = OpenNotes();
  bool _tabsShowing = false;

  /// Whether Recently Deleted is shown in place of a folder, and how many
  /// notes it holds.
  bool _inTrash = false;
  int _trashCount = 0;

  /// Notes stay in Recently Deleted this long.
  static const Duration _trashKeeps = Duration(days: 30);

  final TextEditingController _search = TextEditingController();

  /// Each note's first page, drawn once.
  late ThumbnailCache _thumbnails = ThumbnailCache(
    repository: widget.repository,
    rasterizer: widget.pdfRasterizer,
  );
  String? _folderId;
  LibrarySort _sort = LibrarySort.modified;
  bool _grid = true;
  FolderListing? _listing;
  List<Folder> _path = const <Folder>[];
  Map<String, Folder> _folders = const <String, Folder>{};
  Map<String, int> _counts = const <String, int>{};
  int _loads = 0;

  /// Whether taps pick items for a bulk action instead of opening them, and
  /// the notes and folders picked.
  bool _selecting = false;
  final Set<String> _selectedNotes = <String>{};
  final Set<String> _selectedFolders = <String>{};

  /// The folders opened out in the sidebar, beyond those on the way to the
  /// open folder, which always are.
  final Set<String> _expanded = <String>{};

  /// The template the last new note was made with, offered first next
  /// time.
  PageSetup _template = const PageSetup();

  final GlobalKey<ScaffoldState> _scaffold = GlobalKey<ScaffoldState>();

  NoteRepository get _repository => widget.repository;

  late final GoogleDriveClient _drive =
      widget.googleDriveClient ?? HttpGoogleDriveClient();

  late final CloudStateStore _cloudState =
      widget.cloudStateStore ??
      switch (widget.repository) {
        final FileNoteRepository files => FileCloudStateStore(
          File('${files.directory.path}/cloud_state.json'),
        ),
        _ => InMemoryCloudStateStore(),
      };

  /// One for the screen's life, so a backup asked for in the sheet and an
  /// automatic one take turns.
  late final GoogleDriveBackupService _backup = GoogleDriveBackupService(
    client: _drive,
    repository: _repository,
    state: _cloudState,
    clock: widget.clock,
  );

  late final AutoBackupScheduler _autoBackup = AutoBackupScheduler(
    backup: _backup,
    client: _drive,
    library: _repository,
    clock: widget.clock,
  );

  SubscriptionController? _ownedSubscription;

  SubscriptionController get _subscription =>
      widget.subscription ??
      (_ownedSubscription ??= SubscriptionController(
        store: switch (widget.repository) {
          final FileNoteRepository files => FileSubscriptionStore(
            File('${files.directory.path}/subscription.json'),
          ),
          _ => InMemorySubscriptionStore(),
        },
      )..load());

  Future<void> _openPlans() => showPaymentPage(context, _subscription);

  String get _query => _search.text.trim();

  /// Recently Deleted is shown, rather than a folder or search results.
  bool get _showingTrash => _inTrash && _query.isEmpty;

  @override
  void initState() {
    super.initState();
    _repository.addListener(_reload);
    _search.addListener(_reload);
    _reload();
    _repository.purgeTrash(_trashKeeps);
    _autoBackup.start();
  }

  @override
  void didUpdateWidget(LibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      oldWidget.repository.removeListener(_reload);
      widget.repository.addListener(_reload);
      _thumbnails.dispose();
      _thumbnails = ThumbnailCache(
        repository: widget.repository,
        rasterizer: widget.pdfRasterizer,
      );
      _folderId = null;
      _reload();
    }
  }

  @override
  void dispose() {
    _repository.removeListener(_reload);
    _search.dispose();
    _thumbnails.dispose();
    _stylusOnly.dispose();
    _penSettings.dispose();
    _palettePlacement.dispose();
    _openNotes.dispose();
    _autoBackup.dispose();
    _ownedSubscription?.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final int load = ++_loads;
    final String query = _query;
    final List<NoteEntry> trash = await _repository.trash();
    final bool inTrash = _inTrash && query.isEmpty;
    final FolderListing listing = inTrash
        ? FolderListing(folders: const <Folder>[], notes: trash)
        : query.isEmpty
        ? await _repository.list(_folderId)
        : await _repository.search(query);
    final List<Folder> path = await _repository.pathTo(_folderId);
    final List<Folder> folders = await _repository.allFolders();
    final Map<String, int> counts = await _repository.itemCounts();
    if (!mounted || load != _loads) {
      return;
    }
    setState(() {
      _trashCount = trash.length;
      _listing = FolderListing(
        folders: List<Folder>.of(listing.folders)..sort(_sort.compareFolders),
        // The most recently deleted first, as they were.
        notes: inTrash
            ? listing.notes
            : (List<NoteEntry>.of(listing.notes)..sort(_sort.compareNotes)),
      );
      _path = path;
      _folders = <String, Folder>{
        for (final Folder folder in folders) folder.id: folder,
      };
      _counts = counts;
      if (query.isEmpty && _folderId == null && !inTrash) {
        _thumbnails.retainOnly(<String>{
          for (final NoteEntry note in listing.notes) note.id,
          for (final NoteEntry note in trash) note.id,
        });
      }
      // What is no longer shown is no longer selected.
      _selectedNotes.retainAll(<String>{
        for (final NoteEntry note in listing.notes) note.id,
      });
      _selectedFolders.retainAll(<String>{
        for (final Folder folder in listing.folders) folder.id,
      });
      if (listing.isEmpty) {
        _selecting = false;
      }
    });
  }

  void _openFolder(String? id) {
    if (id == _folderId && _query.isEmpty && !_inTrash) {
      return;
    }
    setState(() {
      _inTrash = false;
      _clearSelection();
      _folderId = id;
      _listing = null;
      // What was open on the way stays open in the sidebar.
      for (String? at = id; at != null; at = _folders[at]?.parentId) {
        _expanded.add(at);
      }
    });
    _search.clear();
    _reload();
  }

  void _setSort(LibrarySort sort) {
    setState(() => _sort = sort);
    _reload();
  }

  /// Shows [note] in a tab beside the notes already open, which stay open
  /// on the way back to the library.
  Future<void> _openNote(NoteEntry note) async {
    _openNotes.open(note);
    setState(() => _tabsShowing = true);
  }

  void _showLibrary() => setState(() => _tabsShowing = false);

  Widget _noteTab(
    NoteEntry note,
    Widget Function(VoidCallback rename) tabs,
    VoidCallback onBack,
    ValueChanged<NoteEntry> onRenamed,
  ) {
    return NoteEditorPage(
      repository: _repository,
      note: note,
      preview: _thumbnails.peek(note, Theme.of(context).brightness),
      aiClient: widget.aiClient,
      subscription: _subscription,
      documentPicker: widget.documentPicker,
      pdfRasterizer: widget.pdfRasterizer,
      exportSink: widget.exportSink,
      documentIoConfig: widget.documentIoConfig,
      sharedClipboard: _sharedClipboard,
      stylusOnly: _stylusOnly,
      penSettings: _penSettings,
      palettePlacement: _palettePlacement,
      initialNotationEnabled: widget.initialNotationEnabled,
      tabsBuilder: tabs,
      onBack: onBack,
      onRenamed: onRenamed,
    );
  }

  /// Asks for the new note's name, page size, and paper together.
  Future<void> _newNote() async {
    final NoteDraft? draft = await pickNoteTemplate(
      context,
      initial: _template,
    );
    if (draft == null || !mounted) {
      return;
    }
    _template = draft.setup;
    final NoteEntry note = await _repository.createNote(
      title: draft.name,
      folderId: _folderId,
      setup: draft.setup,
    );
    if (mounted) {
      await _openNote(note);
    }
  }

  /// A new folder inside [parentId], or inside the open folder.
  Future<void> _newFolder([String? parentId]) async {
    final String? parent = parentId ?? _folderId;
    final Folder? inside = parent == null ? null : _folders[parent];
    final FolderDraft? draft = await askForFolder(
      context,
      title: inside == null ? 'New folder' : 'New folder in ${inside.name}',
      action: 'Create',
    );
    if (draft != null) {
      await _repository.createFolder(
        draft.name,
        parentId: parent,
        color: draft.color,
      );
      if (parent != null && mounted) {
        setState(() => _expanded.add(parent));
      }
    }
  }

  /// Imports a PDF as a new note. A [fromGoodnotes] export also has its
  /// handwriting extracted into editable strokes, and a native `.goodnotes`
  /// notebook comes in whole: pages, paper, and editable ink.
  Future<void> _importPdf({bool fromGoodnotes = false}) async {
    final PickedDocument? picked = fromGoodnotes
        ? await widget.documentPicker.pickGoodnotes()
        : await widget.documentPicker.pickPdf();
    if (picked == null || !mounted) return;
    final bool notebook = GoodnotesArchiveExtractor.isGoodnotesArchive(
      picked.bytes,
    );
    NoteEntry? note;
    bool noInk = false;
    final ImportCancellationToken cancellation = ImportCancellationToken();
    final DocumentIoProgressResult result = await showDocumentIoProgress(
      context,
      title: notebook
          ? 'Importing Goodnotes notebook'
          : fromGoodnotes
          ? 'Importing Goodnotes PDF'
          : 'Importing PDF',
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
              recoverGoodnotesInk: fromGoodnotes,
              onNoInkRecovered: () => noInk = true,
            );
      },
    );
    if (result.error == null && note != null && mounted) {
      if (noInk) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No Goodnotes handwriting was found, so this was imported as '
              'a regular PDF',
            ),
          ),
        );
      }
      await _openNote(note!);
    } else if (result.error != null && !result.cancelled) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.error is DocumentImportException
                ? (result.error! as DocumentImportException).message
                : notebook
                ? 'This Goodnotes file could not be imported'
                : 'This PDF could not be imported',
          ),
        ),
      );
    }
  }

  Future<void> _openGoogleDrive() {
    return showGoogleDriveSheet(
      context,
      client: _drive,
      backup: _backup,
      autoBackup: _autoBackup,
      replicator: GoodnotesDriveReplicator(
        client: _drive,
        repository: _repository,
        importer: DocumentImporter(
          rasterizer: widget.pdfRasterizer,
          config: widget.documentIoConfig,
        ),
        state: _cloudState,
      ),
      onOpenFolder: _openFolder,
      clock: widget.clock,
    );
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
      case _ItemAction.color:
        return;
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
        // Kept in Recently Deleted, so there is nothing to confirm; the
        // snack bar offers to take it straight back.
        _openNotes.close(note.id);
        await _repository.deleteNote(note.id);
        _announceDeleted(<NoteEntry>[note]);
      case _ItemAction.restore:
        await _repository.restoreNote(note.id);
        if (mounted) {
          _showMessage(
            'Restored "${note.title}" to ${_folders[note.folderId]?.name ?? 'Library'}',
          );
        }
      case _ItemAction.deleteForever:
        final bool confirmed = await confirmAction(
          context,
          title: 'Delete permanently?',
          message:
              '"${note.title}" and all of its pages will be deleted. '
              'This cannot be undone.',
          action: 'Delete',
        );
        if (confirmed) {
          await _repository.deleteForever(note.id);
        }
    }
  }

  void _showMessage(String message, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  /// Says where deleted [notes] went, with a way to bring them back.
  void _announceDeleted(List<NoteEntry> notes) {
    if (!mounted || notes.isEmpty) return;
    _showMessage(
      notes.length == 1
          ? 'Moved "${notes.single.title}" to Recently Deleted'
          : 'Moved ${notes.length} notes to Recently Deleted',
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () async {
          for (final NoteEntry note in notes) {
            await _repository.restoreNote(note.id);
          }
        },
      ),
    );
  }

  Future<void> _emptyTrash() async {
    final bool confirmed = await confirmAction(
      context,
      title: 'Delete all permanently?',
      message:
          'Every note in Recently Deleted will be deleted. This cannot be '
          'undone.',
      action: 'Delete',
    );
    if (confirmed) {
      await _repository.emptyTrash();
    }
  }

  void _openTrash() {
    setState(() {
      _clearSelection();
      _inTrash = true;
      _listing = null;
    });
    _search.clear();
    _reload();
  }

  Future<void> _folderAction(Folder folder, _ItemAction action) async {
    switch (action) {
      case _ItemAction.color:
        final FolderColor? color = await pickFolderColor(
          context,
          title: 'Color for "${folder.name}"',
          initial: folder.color,
        );
        if (color != null) {
          await _repository.recolorFolder(folder.id, color);
        }
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
      case _ItemAction.restore:
      case _ItemAction.deleteForever:
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
      if (totals.folders > 0)
        'the ${count(totals.folders, 'folder')} inside it will be deleted',
      if (totals.notes > 0)
        'the ${count(totals.notes, 'note')} inside it will move to Recently '
            'Deleted',
    ];
    return '"${folder.name}" will be deleted, and ${parts.join(', and ')}.';
  }

  /// Whether [item] can be dropped into the folder [folderId], or the top
  /// level when null: not where it already is, and a folder not into
  /// itself or a folder inside it.
  bool _canDrop(_Dragged item, String? folderId) {
    if (item.parentId == folderId) {
      return false;
    }
    final Folder? folder = item.folder;
    return folder == null ||
        folderId == null ||
        !_subtree(folder.id).contains(folderId);
  }

  Future<void> _drop(_Dragged item, String? folderId) async {
    if (!_canDrop(item, folderId)) {
      return;
    }
    final NoteEntry? note = item.note;
    if (note != null) {
      await _repository.moveNote(note.id, folderId);
    } else {
      await _repository.moveFolder(item.folder!.id, folderId);
    }
    if (!mounted) {
      return;
    }
    final String where = folderId == null
        ? 'Library'
        : _folders[folderId]?.name ?? 'folder';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Moved "${item.title}" to $where'),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  void _clearSelection() {
    _selecting = false;
    _selectedNotes.clear();
    _selectedFolders.clear();
  }

  void _stopSelecting() => setState(_clearSelection);

  void _toggle(Set<String> selected, String id) {
    setState(() {
      if (!selected.remove(id)) {
        selected.add(id);
      }
    });
  }

  bool get _allSelected {
    final FolderListing? listing = _listing;
    return listing != null &&
        _selectedNotes.length == listing.notes.length &&
        _selectedFolders.length == listing.folders.length;
  }

  /// Selects everything shown, or nothing when everything already is.
  void _selectAll() {
    final FolderListing? listing = _listing;
    if (listing == null) {
      return;
    }
    setState(() {
      if (_allSelected) {
        _selectedNotes.clear();
        _selectedFolders.clear();
      } else {
        _selectedNotes.addAll(listing.notes.map((NoteEntry n) => n.id));
        _selectedFolders.addAll(listing.folders.map((Folder f) => f.id));
      }
    });
  }

  /// The selected folders that are not inside another selected folder, and
  /// the selected notes that are not inside any of them: what a bulk action
  /// acts on. They differ from the selection only in search results, which
  /// can show a folder and what is inside it.
  (List<Folder>, List<NoteEntry>) _selectedRoots() {
    final FolderListing listing = _listing!;
    final List<Folder> picked = <Folder>[
      for (final Folder folder in listing.folders)
        if (_selectedFolders.contains(folder.id)) folder,
    ];
    final Set<String> below = <String>{
      for (final Folder folder in picked)
        ..._subtree(folder.id).difference(<String>{folder.id}),
    };
    return (
      <Folder>[
        for (final Folder folder in picked)
          if (!below.contains(folder.id)) folder,
      ],
      <NoteEntry>[
        for (final NoteEntry note in listing.notes)
          if (_selectedNotes.contains(note.id) &&
              !below.contains(note.folderId) &&
              !_selectedFolders.contains(note.folderId))
            note,
      ],
    );
  }

  static String _countLabel(int notes, int folders) {
    String count(int n, String one) => n == 1 ? '1 $one' : '$n ${one}s';
    return <String>[
      if (notes > 0) count(notes, 'note'),
      if (folders > 0) count(folders, 'folder'),
    ].join(' and ');
  }

  Future<void> _moveSelected() async {
    final (List<Folder> folders, List<NoteEntry> notes) = _selectedRoots();
    if (folders.isEmpty && notes.isEmpty) {
      return;
    }
    final String what = _countLabel(notes.length, folders.length);
    final FolderChoice? choice = await pickFolder(
      context,
      title: 'Move $what to',
      folders: _folders.values.toList(),
      excluded: <String>{
        for (final Folder folder in folders) ..._subtree(folder.id),
      },
    );
    if (choice == null || !mounted) {
      return;
    }
    final String? target = choice.folder?.id;
    for (final Folder folder in folders) {
      if (folder.parentId != target) {
        await _repository.moveFolder(folder.id, target);
      }
    }
    for (final NoteEntry note in notes) {
      if (note.folderId != target) {
        await _repository.moveNote(note.id, target);
      }
    }
    if (!mounted) {
      return;
    }
    _stopSelecting();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Moved $what to ${choice.folder?.name ?? 'Library'}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _deleteSelected() async {
    final (List<Folder> folders, List<NoteEntry> notes) = _selectedRoots();
    if (folders.isEmpty && notes.isEmpty) {
      return;
    }
    final String what = _countLabel(notes.length, folders.length);
    // Notes alone go to Recently Deleted; folders themselves are not kept.
    if (folders.isNotEmpty) {
      final bool confirmed = await confirmAction(
        context,
        title: 'Delete $what?',
        message:
            'The selected folders will be deleted, and every note inside '
            'them, with the selected notes, will move to Recently Deleted.',
        action: 'Delete',
      );
      if (!confirmed) {
        return;
      }
    }
    for (final Folder folder in folders) {
      await _repository.deleteFolder(folder.id);
    }
    for (final NoteEntry note in notes) {
      _openNotes.close(note.id);
      await _repository.deleteNote(note.id);
    }
    if (mounted) {
      _stopSelecting();
      if (folders.isEmpty) _announceDeleted(notes);
    }
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
    // Keep the bounded tab host mounted when browsing the library. Popping
    // its route used to destroy every editor before opening a second note.
    return PopScope(
      canPop: !_tabsShowing,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop && _tabsShowing) _showLibrary();
      },
      child: _LibraryEditorTransition(
        showEditor: _tabsShowing,
        library: _buildLibrary(context),
        editor: NoteTabsPage(
          notes: _openNotes,
          builder: _noteTab,
          onBack: _showLibrary,
        ),
      ),
    );
  }

  Widget _buildLibrary(BuildContext context) {
    final WindowSizeClass sizeClass = WindowSizeClass.fromWidth(
      MediaQuery.sizeOf(context).width,
    );
    final bool compact = sizeClass == WindowSizeClass.compact;
    // Short of the widest layout, the folders slide in from the edge, so
    // the notes have the whole width; a tablet held upright included.
    final bool drawer = sizeClass != WindowSizeClass.expanded;
    final Widget sidebar = _FolderSidebar(
      folders: _folders,
      counts: _counts,
      openFolderId: _query.isEmpty && !_inTrash ? _folderId : null,
      libraryOpen: _query.isEmpty && !_inTrash && _folderId == null,
      trashOpen: _showingTrash,
      trashCount: _trashCount,
      onOpenTrash: () {
        if (drawer) {
          _scaffold.currentState?.closeDrawer();
        }
        _openTrash();
      },
      onDropInTrash: (_Dragged item) async {
        final NoteEntry? note = item.note;
        if (note == null) return;
        _openNotes.close(note.id);
        await _repository.deleteNote(note.id);
        _announceDeleted(<NoteEntry>[note]);
      },
      expanded: _expanded,
      onOpenFolder: (String? id) {
        if (drawer) {
          _scaffold.currentState?.closeDrawer();
        }
        _openFolder(id);
      },
      onToggle: (String id) => setState(() {
        if (!_expanded.remove(id)) {
          _expanded.add(id);
        }
      }),
      onNewFolder: () => _newFolder(),
      onAction: _folderAction,
      canDrop: _canDrop,
      onDrop: _drop,
    );
    final _LibraryBar bar = _LibraryBar(
      path: _showingTrash ? const <Folder>[] : _path,
      compact: compact,
      trash: _showingTrash,
      onLeaveTrash: () => _openFolder(null),
      onEmptyTrash: _showingTrash && (_listing?.notes.isNotEmpty ?? false)
          ? _emptyTrash
          : null,
      onOpenSidebar: drawer ? () => _scaffold.currentState?.openDrawer() : null,
      search: _search,
      sort: _sort,
      grid: _grid,
      onOpenFolder: _openFolder,
      onSort: _setSort,
      onToggleView: () => setState(() => _grid = !_grid),
      onNewFolder: _newFolder,
      onGoogleDrive: _openGoogleDrive,
      subscription: _subscription,
      onPlans: _openPlans,
      canDrop: _canDrop,
      onDrop: _drop,
      selecting: _selecting,
      selectedCount: _selectedNotes.length + _selectedFolders.length,
      allSelected: _allSelected,
      onSelect: _showingTrash || (_listing?.isEmpty ?? true)
          ? null
          : () => setState(() => _selecting = true),
      onCancelSelection: _stopSelecting,
      onSelectAll: _selectAll,
      onMoveSelected: _moveSelected,
      onDeleteSelected: _deleteSelected,
    );
    return PopScope(
      canPop: _tabsShowing || (_folderId == null && !_selecting && !_inTrash),
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop || _tabsShowing) {
          return;
        }
        if (_selecting) {
          _stopSelecting();
        } else if (_inTrash) {
          _openFolder(null);
        } else {
          _openFolder(_path.length > 1 ? _path[_path.length - 2].id : null);
        }
      },
      child: Scaffold(
        key: _scaffold,
        backgroundColor: Colors.transparent,
        drawer: drawer
            ? Drawer(
                backgroundColor: Colors.transparent,
                child: GlassSurface(child: SafeArea(child: sidebar)),
              )
            : null,
        // Beside the sidebar, the bar spans only the items, so the sidebar
        // runs the window's full height.
        appBar: drawer ? bar : null,
        floatingActionButton: _selecting || _showingTrash
            ? null
            : _NewNoteButton(
                onNewNote: _newNote,
                onImportPdf: () => _importPdf(),
                onImportGoodnotesPdf: () => _importPdf(fromGoodnotes: true),
              ),
        body: drawer
            ? SafeArea(top: false, child: _buildBody(context, compact))
            // Tab goes through the bar first, then the folders, then the
            // items, though the sidebar comes first across the screen.
            : FocusTraversalGroup(
                policy: OrderedTraversalPolicy(),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    FocusTraversalOrder(
                      order: const NumericFocusOrder(2),
                      child: SizedBox(
                        width: _FolderSidebar.width,
                        child: GlassSurface(
                          child: SafeArea(right: false, child: sidebar),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          FocusTraversalOrder(
                            order: const NumericFocusOrder(1),
                            child: FocusTraversalGroup(
                              // The bar keeps clear of the status bar
                              // itself, so it is that much taller.
                              child: SizedBox(
                                height:
                                    bar.preferredSize.height +
                                    MediaQuery.paddingOf(context).top,
                                child: bar,
                              ),
                            ),
                          ),
                          Expanded(
                            child: FocusTraversalOrder(
                              order: const NumericFocusOrder(3),
                              child: SafeArea(
                                top: false,
                                left: false,
                                child: FocusTraversalGroup(
                                  child: _buildBody(context, compact),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, bool compact) {
    final FolderListing? listing = _listing;
    if (listing == null) {
      return const Center(
        child: SizedBox(
          width: AppSpacing.xxl * 2,
          child: ShimmerTrack(semanticsLabel: 'Loading'),
        ),
      );
    }
    if (listing.isEmpty) {
      return _EmptyState(
        query: _query,
        onNewNote: _newNote,
        trash: _showingTrash,
      );
    }
    final bool trash = _showingTrash;
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
          leading: _FolderArt(color: folder.color, alignment: Alignment.center),
          dragIcon: Icon(
            AppIcons.folder,
            color: resolveFolderColor(context, folder.color),
          ),
          actions: _ItemAction.forFolders,
          selecting: _selecting,
          selected: _selectedFolders.contains(folder.id),
          onOpen: _selecting
              ? () => _toggle(_selectedFolders, folder.id)
              : () => _openFolder(folder.id),
          onAction: (_ItemAction action) => _folderAction(folder, action),
          dragData: _Dragged.folder(folder),
          canAccept: (_Dragged item) => _canDrop(item, folder.id),
          onAccept: (_Dragged item) => _drop(item, folder.id),
        ),
    ];
    final List<Widget> notes = <Widget>[
      for (final NoteEntry note in listing.notes)
        _LibraryItem(
          key: ValueKey<String>('note-${note.id}'),
          grid: _grid,
          kind: 'Note',
          title: note.title,
          subtitle: trash
              ? _daysLeft(note, now)
              : searching
              ? _locationOf(note.folderId)
              : null,
          date: trash
              ? formatModified(note.deleted!, now)
              : formatModified(note.modified, now),
          leading: _NoteThumbnail(
            note: note,
            cache: _thumbnails,
            alignment: Alignment.center,
          ),
          dragIcon: const Icon(AppIcons.note),
          actions: trash ? _ItemAction.forDeleted : _ItemAction.forNotes,
          selecting: _selecting,
          selected: _selectedNotes.contains(note.id),
          // A deleted note is not opened: a tap offers its actions.
          menuOnTap: trash,
          draggable: !trash,
          onOpen: _selecting
              ? () => _toggle(_selectedNotes, note.id)
              : () => _openNote(note),
          onAction: (_ItemAction action) => _noteAction(note, action),
          dragData: _Dragged.note(note),
        ),
    ];
    final EdgeInsets padding = EdgeInsets.fromLTRB(
      compact ? AppSpacing.md : AppSpacing.lg,
      compact ? AppSpacing.xs : AppSpacing.md,
      compact ? AppSpacing.md : AppSpacing.lg,
      // Room for the floating button.
      AppSpacing.xxl + AppSpacing.xl,
    );
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        key: const ValueKey<String>('library-items'),
        constraints: const BoxConstraints(maxWidth: AppSizes.maxContentWidth),
        child: _grid
            ? GridView(
                padding: padding,
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: compact ? 180 : 200,
                  mainAxisSpacing: AppSpacing.lg,
                  crossAxisSpacing: compact ? AppSpacing.md : AppSpacing.lg,
                  childAspectRatio: 0.72,
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

  /// How long [note] stays in Recently Deleted.
  String _daysLeft(NoteEntry note, DateTime now) {
    final int left = _trashKeeps.inDays - now.difference(note.deleted!).inDays;
    return switch (left) {
      <= 1 => '1 day left',
      _ => '$left days left',
    };
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
class _LibraryEditorTransition extends StatefulWidget {
  const _LibraryEditorTransition({
    required this.showEditor,
    required this.library,
    required this.editor,
  });

  final bool showEditor;
  final Widget library;
  final Widget editor;

  @override
  State<_LibraryEditorTransition> createState() =>
      _LibraryEditorTransitionState();
}

class _LibraryEditorTransitionState extends State<_LibraryEditorTransition> {
  bool _transitioning = false;

  /// While the two slide past each other, each is drawn once into a
  /// picture and the pictures move. Fading the live screens would draw
  /// them, frosted glass and all, offscreen again on every frame.
  final SnapshotController _librarySnapshot = SnapshotController();
  final SnapshotController _editorSnapshot = SnapshotController();

  @override
  void didUpdateWidget(_LibraryEditorTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showEditor != widget.showEditor) {
      _transitioning = true;
    }
    _librarySnapshot.allowSnapshotting = _transitioning;
    _editorSnapshot.allowSnapshotting = _transitioning;
  }

  @override
  void dispose() {
    _librarySnapshot.dispose();
    _editorSnapshot.dispose();
    super.dispose();
  }

  void _finishTransition() {
    if (!_transitioning || !mounted) return;
    setState(() => _transitioning = false);
    _librarySnapshot.allowSnapshotting = false;
    _editorSnapshot.allowSnapshotting = false;
  }

  @override
  Widget build(BuildContext context) {
    final bool showEditor = widget.showEditor;
    final Duration duration = AppMotion.resolve(context, AppMotion.gentle);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Offstage(
          offstage: showEditor && !_transitioning,
          child: IgnorePointer(
            ignoring: showEditor,
            child: ExcludeSemantics(
              excluding: showEditor,
              child: ExcludeFocus(
                excluding: showEditor,
                child: AnimatedSlide(
                  offset: showEditor ? const Offset(-0.035, 0) : Offset.zero,
                  duration: duration,
                  curve: AppMotion.gentleCurve,
                  child: AnimatedOpacity(
                    opacity: showEditor ? 0 : 1,
                    duration: duration,
                    curve: AppMotion.gentleCurve,
                    child: TickerMode(
                      enabled: !showEditor,
                      child: IgnoreKeyboard(
                        ignoring: showEditor,
                        child: SnapshotWidget(
                          controller: _librarySnapshot,
                          mode: SnapshotMode.permissive,
                          child: RepaintBoundary(child: widget.library),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Offstage(
          offstage: !showEditor && !_transitioning,
          child: IgnorePointer(
            ignoring: !showEditor,
            child: ExcludeSemantics(
              excluding: !showEditor,
              child: ExcludeFocus(
                excluding: !showEditor,
                child: AnimatedSlide(
                  offset: showEditor ? Offset.zero : const Offset(0.055, 0),
                  duration: duration,
                  curve: AppMotion.gentleCurve,
                  child: AnimatedOpacity(
                    opacity: showEditor ? 1 : 0,
                    duration: duration,
                    curve: AppMotion.gentleCurve,
                    onEnd: _finishTransition,
                    child: TickerMode(
                      enabled: showEditor,
                      child: SnapshotWidget(
                        controller: _editorSnapshot,
                        mode: SnapshotMode.permissive,
                        child: RepaintBoundary(child: widget.editor),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

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
    required this.onGoogleDrive,
    required this.subscription,
    required this.onPlans,
    required this.canDrop,
    required this.onDrop,
    required this.selecting,
    required this.selectedCount,
    required this.allSelected,
    required this.onSelect,
    required this.onCancelSelection,
    required this.onSelectAll,
    required this.onMoveSelected,
    required this.onDeleteSelected,
    this.onOpenSidebar,
    this.trash = false,
    this.onLeaveTrash,
    this.onEmptyTrash,
  });

  /// Whether Recently Deleted is shown; the bar then names it, leads back
  /// to the library, and offers to empty it.
  final bool trash;
  final VoidCallback? onLeaveTrash;

  /// Empties Recently Deleted; null while it is empty.
  final VoidCallback? onEmptyTrash;

  /// Whether items are being picked for a bulk action; the bar then shows
  /// how many are, and what can be done with them.
  final bool selecting;
  final int selectedCount;
  final bool allSelected;

  /// Starts picking items; null when there is nothing to pick.
  final VoidCallback? onSelect;
  final VoidCallback onCancelSelection;
  final VoidCallback onSelectAll;
  final VoidCallback onMoveSelected;
  final VoidCallback onDeleteSelected;

  final List<Folder> path;
  final bool compact;

  /// Opens the folder sidebar, where it is a drawer.
  final VoidCallback? onOpenSidebar;
  final TextEditingController search;
  final LibrarySort sort;
  final bool grid;
  final ValueChanged<String?> onOpenFolder;
  final ValueChanged<LibrarySort> onSort;
  final VoidCallback onToggleView;
  final VoidCallback onNewFolder;

  /// Opens the Google Drive sheet: backup, restore, and Goodnotes import.
  final VoidCallback onGoogleDrive;

  /// Shown in the Plans & Credits pill, which [onPlans] opens.
  final SubscriptionController subscription;
  final VoidCallback onPlans;

  /// Whether a dragged item can go into a folder on the path, and moving
  /// it there; the folders above the open one take drops.
  final bool Function(_Dragged item, String? folderId) canDrop;
  final void Function(_Dragged item, String? folderId) onDrop;

  @override
  Size get preferredSize => Size.fromHeight(
    AppSizes.appBarHeight +
        (compact ? AppSizes.minTouchTarget + AppSpacing.xs : 0),
  );

  Widget _buildSelectionRow(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool any = selectedCount > 0;
    return Row(
      children: <Widget>[
        IconButton(
          tooltip: 'Done selecting',
          onPressed: onCancelSelection,
          icon: const Icon(AppIcons.close),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            child: Semantics(
              header: true,
              liveRegion: true,
              child: Text(
                any ? '$selectedCount selected' : 'Select items',
                style: text.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: allSelected ? 'Deselect all' : 'Select all',
          onPressed: onSelectAll,
          icon: Icon(allSelected ? AppIcons.deselectAll : AppIcons.selectAll),
        ),
        IconButton(
          tooltip: 'Move selected',
          onPressed: any ? onMoveSelected : null,
          icon: const Icon(AppIcons.move),
        ),
        IconButton(
          tooltip: 'Delete selected',
          onPressed: any ? onDeleteSelected : null,
          icon: const Icon(AppIcons.delete),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final Widget field = _SearchField(controller: search);
    return GlassMaterial(
      color: AppGlass.surface(colors),
      child: SafeArea(
        bottom: false,
        left: compact,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppSizes.maxContentWidth,
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? AppSpacing.xxs : AppSpacing.xs,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    height: AppSizes.appBarHeight,
                    child: selecting
                        ? _buildSelectionRow(context)
                        : Row(
                            children: <Widget>[
                              if (onOpenSidebar != null)
                                IconButton(
                                  tooltip: 'Folders',
                                  onPressed: onOpenSidebar,
                                  icon: const Icon(AppIcons.sidebar),
                                ),
                              if (trash)
                                IconButton(
                                  tooltip: 'Back to library',
                                  onPressed: onLeaveTrash,
                                  icon: const Icon(AppIcons.back),
                                )
                              else if (path.isNotEmpty)
                                IconButton(
                                  tooltip: 'Up one folder',
                                  onPressed: () => onOpenFolder(
                                    path.length > 1
                                        ? path[path.length - 2].id
                                        : null,
                                  ),
                                  icon: const Icon(AppIcons.back),
                                )
                              else if (onOpenSidebar == null)
                                const SizedBox(width: AppSpacing.md),
                              Expanded(
                                child: trash
                                    ? Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: AppSpacing.xs,
                                        ),
                                        child: Semantics(
                                          header: true,
                                          child: Text(
                                            'Recently Deleted',
                                            style: Theme.of(
                                              context,
                                            ).textTheme.titleLarge,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      )
                                    : _Breadcrumbs(
                                        path: path,
                                        onOpenFolder: onOpenFolder,
                                        canDrop: canDrop,
                                        onDrop: onDrop,
                                      ),
                              ),
                              if (trash && onEmptyTrash != null)
                                TextButton(
                                  onPressed: onEmptyTrash,
                                  style: TextButton.styleFrom(
                                    foregroundColor: AppColors.of(
                                      context,
                                    ).danger,
                                  ),
                                  child: const Text('Empty'),
                                ),
                              if (!compact) ...<Widget>[
                                SizedBox(width: 240, child: field),
                                const SizedBox(width: AppSpacing.xs),
                              ],
                              PlansButton(
                                controller: subscription,
                                onPressed: onPlans,
                                compact: compact,
                              ),
                              IconButton(
                                tooltip: 'Google Drive',
                                onPressed: onGoogleDrive,
                                icon: const Icon(AppIcons.cloud),
                              ),
                              // On compact widths, where the bar is full,
                              // the view toggle is in this menu too.
                              PopupMenuButton<Object>(
                                tooltip: 'Sort',
                                icon: const Icon(AppIcons.sort),
                                onSelected: (Object choice) {
                                  if (choice is LibrarySort) {
                                    onSort(choice);
                                  } else {
                                    onToggleView();
                                  }
                                },
                                itemBuilder: (BuildContext context) {
                                  return <PopupMenuEntry<Object>>[
                                    for (final LibrarySort option
                                        in LibrarySort.values)
                                      _menuItem<Object>(
                                        context,
                                        value: option,
                                        label: option.label,
                                        checked: option == sort,
                                      ),
                                    if (compact) ...<PopupMenuEntry<Object>>[
                                      const PopupMenuDivider(),
                                      _menuItem<Object>(
                                        context,
                                        value: #toggleView,
                                        label: grid
                                            ? 'Show as list'
                                            : 'Show as grid',
                                        checked: false,
                                      ),
                                    ],
                                  ];
                                },
                              ),
                              if (!compact)
                                IconButton(
                                  tooltip: grid
                                      ? 'Show as list'
                                      : 'Show as grid',
                                  onPressed: onToggleView,
                                  icon: Icon(
                                    grid
                                        ? AppIcons.listView
                                        : AppIcons.gridView,
                                  ),
                                ),
                              // Beside the folders where they are shown.
                              if (onOpenSidebar != null)
                                IconButton(
                                  tooltip: 'New folder',
                                  onPressed: onNewFolder,
                                  icon: const Icon(AppIcons.newFolder),
                                ),
                              IconButton(
                                tooltip: 'Select',
                                onPressed: onSelect,
                                icon: const Icon(AppIcons.select),
                              ),
                            ],
                          ),
                  ),
                  if (compact)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.sm,
                        AppSpacing.xxs,
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
    return SizedBox(
      height: 40,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (BuildContext context, TextEditingValue value, Widget? _) {
          return TextField(
            controller: controller,
            textInputAction: TextInputAction.search,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlignVertical: TextAlignVertical.center,
            decoration: InputDecoration(
              hintText: 'Search notes',
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              // On the bar's background the field needs a touch more fill.
              fillColor: Color.alphaBlend(
                colors.textPrimary.withValues(alpha: 0.03),
                colors.surfaceMuted,
              ),
              prefixIcon: const Icon(AppIcons.search, size: 20),
              prefixIconConstraints: const BoxConstraints(minWidth: 40),
              suffixIcon: value.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: controller.clear,
                      icon: const Icon(AppIcons.clear, size: 18),
                    ),
            ),
          );
        },
      ),
    );
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({
    required this.path,
    required this.onOpenFolder,
    required this.canDrop,
    required this.onDrop,
  });

  final List<Folder> path;
  final ValueChanged<String?> onOpenFolder;
  final bool Function(_Dragged item, String? folderId) canDrop;
  final void Function(_Dragged item, String? folderId) onDrop;

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
              AppIcons.disclosure,
              size: 18,
              color: colors.textSecondary.withValues(alpha: 0.6),
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
                    style: text.titleLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
            : _DropTarget(
                canAccept: (_Dragged item) => canDrop(item, id),
                onAccept: (_Dragged item) => onDrop(item, id),
                radius: AppRadii.medium,
                child: TextButton(
                  onPressed: () => onOpenFolder(id),
                  style: TextButton.styleFrom(
                    foregroundColor: colors.textSecondary,
                    textStyle: text.titleMedium!.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs,
                    ),
                    minimumSize: const Size(
                      AppSizes.minTouchTarget,
                      AppSizes.minTouchTarget,
                    ),
                  ),
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
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
/// floating shadow, like the editor's palette. Its menu makes a blank note
/// from a template, or imports a PDF as one: any PDF as it is, or one
/// exported from Goodnotes with its handwriting made editable.
class _NewNoteButton extends StatelessWidget {
  const _NewNoteButton({
    required this.onNewNote,
    required this.onImportPdf,
    required this.onImportGoodnotesPdf,
  });

  final VoidCallback onNewNote;
  final VoidCallback onImportPdf;
  final VoidCallback onImportGoodnotesPdf;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final BorderRadius radius = BorderRadius.circular(AppRadii.large);
    // The menu lines up with the button's trailing edge: laid out in the
    // opposite direction, it grows away from the corner the button sits
    // in. With no room below, it flips to sit above the button, clear of
    // it. Its rows and the button keep the reading direction.
    final TextDirection reading = Directionality.of(context);
    final TextDirection opposite = reading == TextDirection.ltr
        ? TextDirection.rtl
        : TextDirection.ltr;
    Widget reads(Widget child) =>
        Directionality(textDirection: reading, child: child);
    return Directionality(
      textDirection: opposite,
      child: MenuAnchor(
        // Under the opposite direction above, directional start resolves to
        // the button's trailing edge and aligns the menu's trailing edge to it.
        style: const MenuStyle(alignment: AlignmentDirectional.topStart),
        alignmentOffset: const Offset(0, AppSpacing.sm),
        menuChildren: <Widget>[
          reads(
            MenuItemButton(
              leadingIcon: const Icon(AppIcons.newNote),
              onPressed: onNewNote,
              child: const Text('Blank note'),
            ),
          ),
          reads(
            MenuItemButton(
              leadingIcon: const Icon(AppIcons.pdf),
              onPressed: onImportPdf,
              child: const Text('Import PDF'),
            ),
          ),
          reads(
            MenuItemButton(
              leadingIcon: const Icon(AppIcons.pen),
              onPressed: onImportGoodnotesPdf,
              child: const Text('Import editable PDF'),
            ),
          ),
        ],
        builder: (BuildContext context, MenuController menu, Widget? child) {
          return reads(
            Tooltip(
              message: 'New note',
              excludeFromSemantics: true,
              child: Pressable(
                pressedScale: 0.94,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    boxShadow: AppShadows.floating(colors),
                  ),
                  child: FilledButton.icon(
                    onPressed: () => menu.isOpen ? menu.close() : menu.open(),
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.accent,
                      foregroundColor: colors.onAccent,
                      minimumSize: const Size(
                        0,
                        AppSpacing.xxl + AppSpacing.xxs,
                      ),
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        AppSpacing.md + 2,
                        0,
                        AppSpacing.lg - 2,
                        0,
                      ),
                      shape: RoundedRectangleBorder(borderRadius: radius),
                    ),
                    icon: const Icon(AppIcons.add, size: 22),
                    label: const Text('New note'),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Takes notes and folders dropped on [child], outlining it in the accent
/// color while one that [canAccept] is held over it.
class _DropTarget extends StatelessWidget {
  const _DropTarget({
    required this.canAccept,
    required this.onAccept,
    required this.child,
    this.radius = AppRadii.large,
  });

  final bool Function(_Dragged item) canAccept;
  final ValueChanged<_Dragged> onAccept;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return DragTarget<_Dragged>(
      onWillAcceptWithDetails: (DragTargetDetails<_Dragged> details) =>
          canAccept(details.data),
      onAcceptWithDetails: (DragTargetDetails<_Dragged> details) =>
          onAccept(details.data),
      builder:
          (
            BuildContext context,
            List<_Dragged?> candidates,
            List<dynamic> rejected,
          ) {
            final bool over = candidates.isNotEmpty;
            return AnimatedContainer(
              duration: AppMotion.resolve(context, AppMotion.fast),
              foregroundDecoration: BoxDecoration(
                color: over ? colors.accent.withValues(alpha: 0.10) : null,
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(
                  color: over ? colors.accent : Colors.transparent,
                  width: AppSizes.focusRingWidth,
                ),
              ),
              child: child,
            );
          },
    );
  }
}

/// What follows the finger while a note or folder is dragged.
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.icon, required this.title});

  final Widget icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final BorderRadius radius = BorderRadius.circular(AppRadii.large);
    return Transform.rotate(
      angle: -0.03,
      child: Material(
        color: AppGlass.surface(colors),
        elevation: 8,
        shadowColor: colors.shadow.withValues(alpha: 0.5),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: colors.accent, width: AppSizes.hairline),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconTheme.merge(
                  data: IconThemeData(
                    size: AppSizes.icon,
                    color: colors.textSecondary,
                  ),
                  child: icon,
                ),
                const SizedBox(width: AppSpacing.sm),
                Flexible(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.query,
    required this.onNewNote,
    this.trash = false,
  });

  final String query;
  final VoidCallback onNewNote;

  /// For an empty Recently Deleted.
  final bool trash;

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
            DecoratedBox(
              decoration: BoxDecoration(
                color: AppGlass.muted(colors),
                shape: BoxShape.circle,
              ),
              child: SizedBox.square(
                dimension: 72,
                child: Icon(
                  searching
                      ? AppIcons.noResults
                      : trash
                      ? AppIcons.trash
                      : AppIcons.emptyLibrary,
                  size: 32,
                  color: colors.textSecondary,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              searching
                  ? 'No notes match "$query"'
                  : trash
                  ? 'No recently deleted notes'
                  : 'Nothing here yet',
              style: text.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (trash) ...<Widget>[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Notes you delete stay here for 30 days.',
                style: text.bodyMedium?.copyWith(color: colors.textSecondary),
                textAlign: TextAlign.center,
              ),
            ] else if (!searching) ...<Widget>[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Create a note to start writing.',
                style: text.bodyMedium?.copyWith(color: colors.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton.icon(
                onPressed: onNewNote,
                icon: const Icon(AppIcons.add, size: 20),
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
/// an overflow menu that a right click also opens. A long press picks it
/// up to drag into a folder; a folder takes what is dropped on it.
class _LibraryItem extends StatefulWidget {
  const _LibraryItem({
    super.key,
    required this.grid,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.date,
    required this.leading,
    required this.dragIcon,
    required this.actions,
    required this.onOpen,
    required this.onAction,
    required this.dragData,
    this.selecting = false,
    this.selected = false,
    this.menuOnTap = false,
    this.draggable = true,
    this.canAccept,
    this.onAccept,
  });

  /// A tap opens the item's actions instead of the item.
  final bool menuOnTap;

  /// Whether a long press picks it up to move it.
  final bool draggable;

  final bool grid;
  final String kind;
  final String title;
  final String? subtitle;
  final String date;
  final Widget leading;

  /// Shown beside the title while it is dragged.
  final Widget dragIcon;
  final List<_ItemAction> actions;
  final VoidCallback onOpen;
  final ValueChanged<_ItemAction> onAction;
  final _Dragged dragData;

  /// While picking items for a bulk action, a tap toggles [selected], which
  /// shows as a check mark; there is no menu and no dragging.
  final bool selecting;
  final bool selected;

  /// For a folder: whether a dragged item may be dropped into it, and
  /// moving it there. Null for a note, which takes no drops.
  final bool Function(_Dragged item)? canAccept;
  final ValueChanged<_Dragged>? onAccept;

  @override
  State<_LibraryItem> createState() => _LibraryItemState();
}

class _LibraryItemState extends State<_LibraryItem> {
  /// The height of a row in the list.
  static const double _rowHeight = 64;

  /// Around a grid item, so its selection fill and press highlight have
  /// room beyond the picture.
  static const double _gridInset = 6;

  final GlobalKey<PopupMenuButtonState<_ItemAction>> _menu =
      GlobalKey<PopupMenuButtonState<_ItemAction>>();

  void _openMenu() => _menu.currentState?.showButtonMenu();

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final bool grid = widget.grid;
    final Widget menu = PopupMenuButton<_ItemAction>(
      key: _menu,
      tooltip: 'More actions for ${widget.title}',
      icon: Icon(AppIcons.more, size: 20, color: colors.textSecondary),
      onSelected: widget.onAction,
      itemBuilder: (BuildContext context) {
        return <PopupMenuEntry<_ItemAction>>[
          for (final _ItemAction action in widget.actions)
            _menuItem<_ItemAction>(
              context,
              value: action,
              label: action.label,
              icon: action.icon,
              danger: action.destructive,
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
        const SizedBox(height: 2),
        Text(
          widget.subtitle == null
              ? widget.date
              : '${widget.subtitle} · ${widget.date}',
          style: text.bodySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
    final Widget body = grid
        ? Padding(
            padding: const EdgeInsets.all(_gridInset),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // Every item gets the same space, whatever its page's shape,
                // so rows and captions line up; the page floats centered.
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    child: widget.leading,
                  ),
                ),
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(
                    2,
                    AppSpacing.sm - 2,
                    AppSizes.minTouchTarget - AppSpacing.xs,
                    0,
                  ),
                  child: caption,
                ),
              ],
            ),
          )
        : SizedBox(
            height: _rowHeight,
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                AppSpacing.sm,
                AppSpacing.xs,
                AppSizes.minTouchTarget + AppSpacing.xs,
                AppSpacing.xs,
              ),
              child: Row(
                children: <Widget>[
                  SizedBox(width: 40, height: 48, child: widget.leading),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(child: caption),
                ],
              ),
            ),
          );
    final BorderRadius radius = BorderRadius.circular(
      grid ? AppRadii.large : AppRadii.medium,
    );
    final Widget check = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.selected ? colors.accent : colors.surface,
        border: Border.all(
          color: widget.selected ? colors.accent : colors.textSecondary,
          width: 1.5,
        ),
        boxShadow: AppShadows.paper(colors),
      ),
      child: SizedBox.square(
        dimension: 22,
        child: widget.selected
            ? Icon(AppIcons.check, size: 14, color: colors.onAccent)
            : null,
      ),
    );
    final Widget card = Semantics(
      container: true,
      button: true,
      label: '${widget.kind}, ${widget.title}, modified ${widget.date}',
      selected: widget.selecting ? widget.selected : null,
      onTap: widget.onOpen,
      onLongPress: widget.selecting ? null : _openMenu,
      customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
        if (!widget.selecting)
          for (final _ItemAction action in widget.actions)
            CustomSemanticsAction(label: action.label): () =>
                widget.onAction(action),
      },
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: widget.menuOnTap && !widget.selecting
              ? _openMenu
              : widget.onOpen,
          onSecondaryTap: widget.selecting ? null : _openMenu,
          hoverColor: colors.textPrimary.withValues(alpha: 0.04),
          focusColor: colors.textPrimary.withValues(alpha: 0.08),
          highlightColor: colors.textPrimary.withValues(alpha: 0.06),
          child: ExcludeSemantics(child: body),
        ),
      ),
    );
    final Widget item = Padding(
      padding: grid
          ? EdgeInsets.zero
          : const EdgeInsets.only(bottom: AppSpacing.xxs),
      child: AnimatedContainer(
        duration: AppMotion.resolve(context, AppMotion.fast),
        curve: AppMotion.standard,
        decoration: BoxDecoration(
          borderRadius: radius,
          color: widget.selected
              ? colors.selected
              : colors.selected.withValues(alpha: 0),
        ),
        child: Stack(
          children: <Widget>[
            Positioned.fill(child: card),
            // Where the menu button is otherwise, beside the title.
            if (widget.selecting)
              PositionedDirectional(
                end: grid ? 0 : AppSpacing.xxs,
                bottom: grid ? 0 : null,
                top: grid ? null : 0,
                child: IgnorePointer(
                  child: SizedBox(
                    width: AppSizes.minTouchTarget,
                    height: grid ? AppSizes.minTouchTarget : _rowHeight,
                    child: Center(child: check),
                  ),
                ),
              )
            else
              PositionedDirectional(
                end: grid ? 0 : AppSpacing.xxs,
                bottom: grid ? 0 : null,
                top: grid ? null : 0,
                child: grid
                    ? menu
                    : SizedBox(
                        height: _rowHeight,
                        child: Center(child: menu),
                      ),
              ),
            if (!grid)
              const SizedBox(height: _rowHeight, width: double.infinity),
          ],
        ),
      ),
    );
    final Widget target = widget.canAccept == null || widget.onAccept == null
        ? item
        : _DropTarget(
            canAccept: widget.canAccept!,
            onAccept: widget.onAccept!,
            radius: grid ? AppRadii.large : AppRadii.medium,
            child: item,
          );
    return LongPressDraggable<_Dragged>(
      data: widget.dragData,
      maxSimultaneousDrags: widget.selecting || !widget.draggable ? 0 : null,
      feedback: _DragFeedback(icon: widget.dragIcon, title: widget.title),
      childWhenDragging: Opacity(opacity: 0.35, child: target),
      child: Pressable(pressedScale: 0.97, child: target),
    );
  }
}

/// Fits a box of [aspect], width over height, in its parent, placed at
/// [alignment], and builds [child] at that size.
class _Contained extends StatelessWidget {
  const _Contained({
    required this.aspect,
    required this.alignment,
    required this.child,
  });

  final double aspect;
  final AlignmentGeometry alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        double width = constraints.maxWidth;
        double height = width / aspect;
        if (height > constraints.maxHeight) {
          height = constraints.maxHeight;
          width = height * aspect;
        }
        return Align(
          alignment: alignment,
          child: SizedBox(width: width, height: height, child: child),
        );
      },
    );
  }
}

/// A folder, in its color: a soft folder shape, its tab at the back.
class _FolderArt extends StatelessWidget {
  const _FolderArt({
    required this.color,
    this.alignment = Alignment.bottomCenter,
  });

  /// Wider than tall, like a folder on a desk.
  static const double aspect = 1.2;

  final FolderColor color;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final Color tint = resolveFolderColor(context, color);
    final AppColors colors = AppColors.of(context);
    return _Contained(
      aspect: aspect,
      alignment: alignment,
      child: CustomPaint(
        painter: _FolderPainter(
          tint: tint,
          surface: colors.surface,
          dark: Theme.of(context).brightness == Brightness.dark,
        ),
      ),
    );
  }
}

class _FolderPainter extends CustomPainter {
  const _FolderPainter({
    required this.tint,
    required this.surface,
    required this.dark,
  });

  final Color tint;
  final Color surface;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    final double r = math.min(w, h) * 0.08;
    final double tabHeight = h * 0.1;
    final double tabWidth = w * 0.4;
    // The back, with its tab.
    final Path back = Path()
      ..moveTo(0, r)
      ..quadraticBezierTo(0, 0, r, 0)
      ..lineTo(tabWidth - r * 0.5, 0)
      ..quadraticBezierTo(tabWidth, 0, tabWidth + r * 0.6, tabHeight * 0.6)
      ..lineTo(tabWidth + r * 0.9, tabHeight)
      ..lineTo(w - r, tabHeight)
      ..quadraticBezierTo(w, tabHeight, w, tabHeight + r)
      ..lineTo(w, h - r)
      ..quadraticBezierTo(w, h, w - r, h)
      ..lineTo(r, h)
      ..quadraticBezierTo(0, h, 0, h - r)
      ..close();
    // A soft shadow under the folder's body: a blurred rounded rectangle,
    // which is drawn analytically rather than through a blur pass.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(w * 0.04, tabHeight + h * 0.14, w * 0.96, h + 3),
        Radius.circular(r),
      ),
      Paint()
        ..color = Colors.black.withValues(alpha: dark ? 0.4 : 0.14)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
    canvas.drawPath(
      back,
      Paint()
        ..color = Color.alphaBlend(
          tint.withValues(alpha: dark ? 0.62 : 0.55),
          surface,
        ),
    );
    // The front, a little lower, lighter, catching the light.
    final RRect front = RRect.fromRectAndRadius(
      Rect.fromLTRB(0, tabHeight + h * 0.08, w, h),
      Radius.circular(r),
    );
    canvas.drawRRect(
      front,
      Paint()
        ..color = Color.alphaBlend(
          tint.withValues(alpha: dark ? 0.86 : 0.78),
          surface,
        ),
    );
  }

  @override
  bool shouldRepaint(_FolderPainter oldDelegate) {
    return oldDelegate.tint != tint ||
        oldDelegate.surface != surface ||
        oldDelegate.dark != dark;
  }
}

/// A note's first page, floating above the desk: its picture from the
/// [ThumbnailCache], drawn once and only shown here.
class _NoteThumbnail extends StatelessWidget {
  const _NoteThumbnail({
    required this.note,
    required this.cache,
    this.alignment = Alignment.center,
  });

  final NoteEntry note;
  final ThumbnailCache cache;

  /// Where the page sits in the space it is given.
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final ThumbnailStyle style = ThumbnailStyle(
      brightness: Theme.of(context).brightness,
      paper: colors.writingSurface,
      rule: colors.pageRule,
      marginRule: colors.pageMarginRule,
    );
    final BorderRadius radius = BorderRadius.circular(AppRadii.small + 2);
    return ThumbnailView(
      image: cache.watch(note, style),
      placeholderAspect: 3 / 4,
      builder: (BuildContext context, ui.Image? image, double aspect) {
        return _Contained(
          aspect: aspect,
          alignment: alignment,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.writingSurface,
              borderRadius: radius,
              boxShadow: AppShadows.floating(colors),
            ),
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(
                  color: colors.textPrimary.withValues(alpha: 0.06),
                  width: AppSizes.hairline,
                ),
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: AnimatedOpacity(
                  opacity: image == null ? 0 : 1,
                  duration: AppMotion.resolve(context, AppMotion.medium),
                  curve: AppMotion.standard,
                  child: image == null
                      ? const SizedBox.expand()
                      : RawImage(
                          image: image,
                          fit: BoxFit.fill,
                          filterQuality: FilterQuality.medium,
                        ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The folders, as a tree down the left of the library: the library itself
/// at the top, then every folder, each in its color, nested under its
/// parent. A folder with folders inside opens out with its chevron; the
/// open folder is highlighted.
/// New folder, at the top, makes one inside the open folder.
class _FolderSidebar extends StatelessWidget {
  const _FolderSidebar({
    required this.folders,
    required this.counts,
    required this.openFolderId,
    required this.expanded,
    required this.onOpenFolder,
    required this.onToggle,
    required this.onNewFolder,
    required this.onAction,
    required this.canDrop,
    required this.onDrop,
    required this.libraryOpen,
    required this.trashOpen,
    required this.trashCount,
    required this.onOpenTrash,
    required this.onDropInTrash,
  });

  static const double width = 280;

  /// Whether the top level, or Recently Deleted, is shown.
  final bool libraryOpen;
  final bool trashOpen;
  final int trashCount;
  final VoidCallback onOpenTrash;

  /// Deletes a note dropped on Recently Deleted.
  final ValueChanged<_Dragged> onDropInTrash;

  /// How far each level of folders is indented.
  static const double _indent = AppSpacing.md;

  final Map<String, Folder> folders;
  final Map<String, int> counts;

  /// The folder being shown, or null for the top level or a search.
  final String? openFolderId;
  final Set<String> expanded;
  final ValueChanged<String?> onOpenFolder;
  final ValueChanged<String> onToggle;
  final VoidCallback onNewFolder;
  final Future<void> Function(Folder, _ItemAction) onAction;

  /// Whether a dragged item can go into a folder, or the top level when
  /// null, and moving it there: each row takes drops.
  final bool Function(_Dragged item, String? folderId) canDrop;
  final void Function(_Dragged item, String? folderId) onDrop;

  Widget _target(String? folderId, Widget row) {
    return _DropTarget(
      canAccept: (_Dragged item) => canDrop(item, folderId),
      onAccept: (_Dragged item) => onDrop(item, folderId),
      radius: AppRadii.medium,
      child: row,
    );
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final AppColors colors = AppColors.of(context);
    final Map<String?, List<Folder>> children = <String?, List<Folder>>{};
    for (final Folder folder in folders.values) {
      children.putIfAbsent(folder.parentId, () => <Folder>[]).add(folder);
    }
    final List<Widget> rows = <Widget>[];
    void walk(String? parent, int depth) {
      final List<Folder> here = List<Folder>.of(
        children[parent] ?? const <Folder>[],
      )..sort(LibrarySort.title.compareFolders);
      for (final Folder folder in here) {
        final bool hasChildren = children[folder.id]?.isNotEmpty ?? false;
        final bool open = hasChildren && expanded.contains(folder.id);
        rows.add(
          _target(
            folder.id,
            _SidebarRow(
              key: ValueKey<String>('sidebar-folder-${folder.id}'),
              depth: depth,
              label: folder.name,
              count: counts[folder.id] ?? 0,
              selected: folder.id == openFolderId,
              expanded: hasChildren ? open : null,
              icon: Icon(
                open ? AppIcons.folderOpen : AppIcons.folder,
                color: resolveFolderColor(context, folder.color),
                size: AppSizes.icon,
              ),
              onTap: () => onOpenFolder(folder.id),
              onToggle: () => onToggle(folder.id),
              actions: _ItemAction.forFolders,
              onAction: (_ItemAction action) => onAction(folder, action),
            ),
          ),
        );
        if (open) {
          walk(folder.id, depth + 1);
        }
      }
    }

    walk(null, 0);
    return Semantics(
      key: const ValueKey<String>('library-sidebar'),
      container: true,
      explicitChildNodes: true,
      label: 'Folders',
      child: FocusTraversalGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // As tall as the bar beside it, so the two read as one line.
            Container(
              height: AppSizes.appBarHeight,
              padding: const EdgeInsetsDirectional.only(
                start: AppSpacing.md + AppSpacing.xxs,
                end: AppSpacing.xs,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text('Folders', style: text.titleMedium),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey<String>('sidebar-new-folder'),
                    tooltip: 'New folder',
                    onPressed: onNewFolder,
                    icon: Icon(AppIcons.newFolder, color: colors.textSecondary),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xs,
                  AppSpacing.xxs,
                  AppSpacing.xs,
                  AppSpacing.lg,
                ),
                children: <Widget>[
                  _target(
                    null,
                    _SidebarRow(
                      key: const ValueKey<String>('sidebar-library'),
                      depth: 0,
                      label: 'Library',
                      count: null,
                      selected: libraryOpen,
                      expanded: null,
                      icon: Icon(
                        AppIcons.library,
                        color: colors.textSecondary,
                        size: AppSizes.icon,
                      ),
                      onTap: () => onOpenFolder(null),
                      onToggle: null,
                      actions: const <_ItemAction>[],
                      onAction: null,
                    ),
                  ),
                  ...rows,
                  if (folders.isEmpty)
                    Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        AppSizes.minTouchTarget,
                        AppSpacing.xs,
                        AppSpacing.md,
                        AppSpacing.xs,
                      ),
                      child: Text(
                        'Folders you make appear here.',
                        style: text.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
            // Recently Deleted, pinned to the bottom corner: deleted notes
            // wait here, and a note dropped here is deleted.
            const Divider(indent: AppSpacing.md, endIndent: AppSpacing.md),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.xs),
              child: _DropTarget(
                canAccept: (_Dragged item) => item.note != null,
                onAccept: onDropInTrash,
                radius: AppRadii.medium,
                child: _SidebarRow(
                  key: const ValueKey<String>('sidebar-trash'),
                  depth: 0,
                  label: 'Recently Deleted',
                  count: trashCount,
                  selected: trashOpen,
                  expanded: null,
                  icon: Icon(
                    AppIcons.trash,
                    color: colors.textSecondary,
                    size: AppSizes.icon,
                  ),
                  onTap: onOpenTrash,
                  onToggle: null,
                  actions: const <_ItemAction>[],
                  onAction: null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One folder in the sidebar: its chevron, if it has folders inside, its
/// glyph in its color, its name, how much it holds, and its actions, which
/// a long press also opens.
class _SidebarRow extends StatefulWidget {
  const _SidebarRow({
    super.key,
    required this.depth,
    required this.label,
    required this.count,
    required this.selected,
    required this.expanded,
    required this.icon,
    required this.onTap,
    required this.onToggle,
    required this.actions,
    required this.onAction,
  });

  final int depth;
  final String label;
  final int? count;
  final bool selected;

  /// Whether its folders are shown; null when it has none.
  final bool? expanded;
  final Widget icon;
  final VoidCallback onTap;
  final VoidCallback? onToggle;
  final List<_ItemAction> actions;
  final ValueChanged<_ItemAction>? onAction;

  @override
  State<_SidebarRow> createState() => _SidebarRowState();
}

class _SidebarRowState extends State<_SidebarRow> {
  final GlobalKey<PopupMenuButtonState<_ItemAction>> _menu =
      GlobalKey<PopupMenuButtonState<_ItemAction>>();

  void _openMenu() => _menu.currentState?.showButtonMenu();

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final BorderRadius radius = BorderRadius.circular(AppRadii.medium);
    final bool? expanded = widget.expanded;
    final bool hasMenu = widget.actions.isNotEmpty && widget.onAction != null;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: Material(
        color: widget.selected ? colors.selected : Colors.transparent,
        borderRadius: radius,
        child: Row(
          children: <Widget>[
            SizedBox(width: _FolderSidebar._indent * widget.depth),
            if (expanded != null)
              IconButton(
                tooltip: expanded
                    ? 'Collapse ${widget.label}'
                    : 'Expand ${widget.label}',
                onPressed: widget.onToggle,
                icon: AnimatedRotation(
                  turns: expanded ? 0.25 : 0,
                  duration: AppMotion.resolve(context, AppMotion.fast),
                  child: Icon(
                    AppIcons.disclosure,
                    size: 20,
                    color: colors.textSecondary,
                  ),
                ),
              )
            else
              const SizedBox(width: AppSizes.minTouchTarget),
            Expanded(
              child: Semantics(
                button: true,
                selected: widget.selected,
                // Folders have actions; Library and Recently Deleted have
                // none.
                label: widget.actions.isEmpty
                    ? widget.label
                    : 'Folder, ${widget.label}',
                onTap: widget.onTap,
                onLongPress: hasMenu ? _openMenu : null,
                customSemanticsActions: hasMenu
                    ? <CustomSemanticsAction, VoidCallback>{
                        for (final _ItemAction action in widget.actions)
                          CustomSemanticsAction(label: action.label): () =>
                              widget.onAction!(action),
                      }
                    : null,
                excludeSemantics: true,
                child: InkWell(
                  borderRadius: radius,
                  onTap: widget.onTap,
                  onLongPress: hasMenu ? _openMenu : null,
                  onSecondaryTap: hasMenu ? _openMenu : null,
                  child: SizedBox(
                    height: AppSizes.minTouchTarget,
                    child: Row(
                      children: <Widget>[
                        widget.icon,
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            widget.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodyMedium?.copyWith(
                              color: widget.selected
                                  ? colors.accent
                                  : colors.textPrimary,
                              fontWeight: widget.selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (widget.count != null && widget.count! > 0)
                          Padding(
                            padding: const EdgeInsetsDirectional.only(
                              start: AppSpacing.xs,
                            ),
                            child: Text(
                              '${widget.count}',
                              style: text.labelMedium!.copyWith(
                                fontFeatures: const <FontFeature>[
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                        const SizedBox(width: AppSpacing.xs),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (hasMenu)
              PopupMenuButton<_ItemAction>(
                key: _menu,
                tooltip: 'More actions for ${widget.label}',
                icon: Icon(
                  AppIcons.more,
                  size: 20,
                  color: colors.textSecondary,
                ),
                onSelected: widget.onAction,
                itemBuilder: (BuildContext context) {
                  return <PopupMenuEntry<_ItemAction>>[
                    for (final _ItemAction action in widget.actions)
                      _menuItem<_ItemAction>(
                        context,
                        value: action,
                        label: action.label,
                        icon: action.icon,
                        danger: action.destructive,
                      ),
                  ];
                },
              ),
          ],
        ),
      ),
    );
  }
}
