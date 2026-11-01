import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import '../../backend/backend_service.dart';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/semantics.dart';

import '../../app/theme/app_tokens.dart';
import '../../app/theme/app_icons.dart';
import '../../shared/layout/breakpoints.dart';
import '../../shared/memory/memory_pressure.dart';
import '../../shared/motion/motion_memory.dart';
import '../editor/ai/ai_client.dart';
import '../editor/ai/ai_config.dart';
import '../editor/handwriting/handwriting_calibration.dart';
import '../editor/handwriting/handwriting_calibration_screen.dart';
import '../editor/ink/input_defaults.dart';
import '../editor/ink/pen_settings.dart';
import '../editor/page/page_setup.dart';
import '../editor/document_io/document_importer.dart';
import '../editor/document_io/document_io_config.dart';
import '../editor/document_io/document_platform.dart';
import '../editor/document_io/pdf_preview_store.dart';
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
import 'cloud/google_sign_in_screen.dart';
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
import '../../shared/widgets/app_controls.dart';
import '../../shared/widgets/dog_ear.dart';
import '../../shared/widgets/ignore_keyboard.dart';
import '../../shared/widgets/scene_transitions.dart';
import '../../shared/widgets/processing.dart';
import '../../shared/widgets/pressable.dart';
import '../payment/account_page.dart';
import '../payment/billing_backend.dart';
import '../payment/in_app_purchase_gateway.dart';
import '../payment/payment_models.dart';
import '../payment/subscription_controller.dart';

/// Opens the library on this device, then shows it. With a [repository]
/// that one is used instead.
class LibraryHome extends StatefulWidget {
  const LibraryHome({
    super.key,
    this.repository,
    this.subscription,
    this.opening,
  });

  final NoteRepository? repository;

  /// The device's library, already being opened, as at startup alongside
  /// the platform services. Without one, it is opened here.
  final Future<FileNoteRepository>? opening;

  /// The user's plan and AI credits. Without one, the device's library
  /// gets one beside it, connected to the platform store; a library
  /// supplied from outside gets one with no store.
  final SubscriptionController? subscription;

  @override
  State<LibraryHome> createState() => _LibraryHomeState();
}

class _LibraryHomeState extends State<LibraryHome> {
  late final Future<NoteRepository> _repository = widget.repository == null
      ? (widget.opening ?? FileNoteRepository.openDefault())
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

  /// PDF pages' previews, in the device's cache, for the device's library.
  PdfPreviewStore? _pdfPreviews;

  bool _handwritingChecked = false;

  /// Loads the writer's handwriting profile for every note. The library
  /// itself asks for sign-in and offers calibration ([LibraryScreen.onboard]).
  void _checkHandwriting(NoteRepository repository) {
    if (_handwritingChecked || !_onDevice(repository)) return;
    _handwritingChecked = true;
    handwritingProfileStoreFor(repository).read().then((
      HandwritingCalibrationState? state,
    ) {
      HandwritingCalibration.current.value = state?.style;
      HandwritingCalibration.textSize.value =
          state?.textSize ?? AiTextSize.medium;
    });
  }

  /// Whether [repository] is the device's own library, not one supplied.
  bool _onDevice(NoteRepository repository) =>
      widget.repository == null && repository is FileNoteRepository;

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
        if (repository != null) _checkHandwriting(repository);
        final Color background = AppColors.of(context).background;
        // The library fades in over its empty background once it is read.
        return LoadingReveal(
          timing: LoadTimings.library,
          semanticsLabel: 'Loading',
          placeholder: Scaffold(backgroundColor: background),
          child: repository != null
              ? LibraryScreen(
                  repository: repository,
                  subscription:
                      widget.subscription ?? _subscriptionFor(repository),
                  onboard: _onDevice(repository),
                  pdfPreviewStore: _onDevice(repository)
                      ? _pdfPreviews ??= FilePdfPreviewStore.appCache()
                      : null,
                )
              : snapshot.hasError
              ? Scaffold(
                  backgroundColor: background,
                  body: const Center(
                    child: Text("The library couldn't be opened."),
                  ),
                )
              : null,
        );
      },
    );
  }
}

/// Where the handwriting profile of [repository] is kept: a file beside
/// the device's library, or memory for any other library.
HandwritingProfileStore handwritingProfileStoreFor(NoteRepository repository) =>
    switch (repository) {
      final FileNoteRepository files => FileHandwritingProfileStore(
        File('${files.directory.path}/handwriting_profile.json'),
      ),
      _ => InMemoryHandwritingProfileStore(),
    };

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
    this.sharedDocuments = const SystemSharedDocumentSource(),
    this.pdfRasterizer = const PdfrxRasterizer(),
    this.pdfPreviewStore,
    this.exportSink = const SystemExportSink(),
    this.documentIoConfig = const DocumentIoConfig(),
    this.initialNotationEnabled = true,
    this.googleDriveClient,
    this.cloudStateStore,
    this.subscription,
    this.onboard = false,
  });

  final NoteRepository repository;

  /// On opening, asks someone not signed in to sign in to Google and
  /// Google Drive first, then offers handwriting calibration if it has
  /// never been offered.
  final bool onboard;
  final DateTime Function() clock;

  /// Passed to the editor; tests supply one.
  final AiClient? aiClient;
  final DocumentPicker documentPicker;
  final SharedDocumentSource sharedDocuments;
  final PdfRasterizer pdfRasterizer;

  /// Passed to the editor, to keep PDF pages' previews between visits.
  final PdfPreviewStore? pdfPreviewStore;
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

  /// Which showing of a folder's contents this is, and the way the move to
  /// it went: into a folder, back out of one, or to the side. A new folder
  /// is a new scene, carried in as the last one goes out.
  int _scene = 0;
  int _sceneDirection = 0;

  /// Whether the scene shown was already in [_listings] as it was opened:
  /// a folder visited before arrives quickly, a new one slowly and smoothly.
  MotionPace _scenePace = MotionPace.standard;

  /// What each folder visited held, as last read, by [_listingKey], so a
  /// folder opened again is shown at once. There is no limit to how many
  /// are kept: they are let go only when the system runs low on memory.
  /// Search results are not kept.
  final Map<Object?, FolderListing> _listings = <Object?, FolderListing>{};

  /// Recently Deleted's key in [_listings]; a folder's is its id, and the
  /// library's null.
  static const Object _trashListing = #recentlyDeleted;
  static Object? _listingKey(String? folderId, {required bool trash}) =>
      trash ? _trashListing : folderId;

  /// Moves on with each change to the library, so an older re-read of the
  /// folders kept does not overwrite a newer one.
  int _listingsEpoch = 0;

  /// How fast the note opening now zooms in, by whether it has been opened
  /// before; its editor holds its heavy content back as long.
  final Map<String, MotionPace> _notePaces = <String, MotionPace>{};
  MotionPace _zoomPace = MotionPace.standard;
  StreamSubscription<PickedDocument>? _sharedDocumentsSubscription;
  final List<PickedDocument> _pendingSharedImports = <PickedDocument>[];
  bool _importingShared = false;

  /// Whether Recently Deleted is shown in place of a folder, and how many
  /// notes it holds.
  bool _inTrash = false;
  int _trashCount = 0;

  /// Notes stay in Recently Deleted this long.
  static const Duration _trashKeeps = Duration(days: 30);
  static const Duration _searchDelay = Duration(milliseconds: 120);

  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'Library search');
  Timer? _searchDebounce;

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
  /// time and used as is by Quick start. Blank A4 until one is chosen.
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
    isNoteOpen: (String id) =>
        _openNotes.notes.any((NoteEntry note) => note.id == id),
    clock: widget.clock,
  );

  late final AutoBackupScheduler _autoBackup = AutoBackupScheduler(
    backup: _backup,
    client: _drive,
    library: _repository,
    clock: widget.clock,
  );

  SubscriptionController? _ownedSubscription;

  late HandwritingProfileStore _handwritingProfileStore =
      handwritingProfileStoreFor(widget.repository);

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

  Future<void> _openPlans() => _openAccount(openPlans: true);

  Future<void> _calibrateHandwriting() async {
    await showHandwritingCalibration(context, store: _handwritingProfileStore);
  }

  String get _query => _search.text.trim();

  /// Recently Deleted is shown, rather than a folder or search results.
  bool get _showingTrash => _inTrash && _query.isEmpty;

  /// The system is low on memory: only the thumbnails likely on screen
  /// are kept.
  void _releaseMemory() {
    _thumbnails.releaseMemory();
    // Read again when next opened, at a first visit's pace.
    final Object? shownKey = _shownListingKey;
    final FolderListing? shown = _listings[shownKey];
    _listings.clear();
    if (shown != null) _listings[shownKey] = shown;
  }

  /// The key in [_listings] of what the library shows now, if it is kept.
  Object? get _shownListingKey =>
      _listingKey(_folderId, trash: _inTrash && _query.isEmpty);

  /// While the app is out of sight, the pictures of the notes just saved
  /// are drawn and stored even with a note in front: no one is watching,
  /// and the app may not be opened again before it is closed.
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    MemoryPressure.instance.addListener(_releaseMemory);
    _lifecycle = AppLifecycleListener(
      onHide: () => _thumbnails.resume(),
      onShow: () {
        if (_tabsShowing) _thumbnails.pause();
      },
      onResume: () {
        if (widget.onboard) _pullFromDrive();
      },
    );
    _repository.addListener(_onRepositoryChanged);
    _search.addListener(_scheduleSearchReload);
    _reload();
    _repository.purgeTrash(_trashKeeps);
    _autoBackup.start();
    _sharedDocumentsSubscription = widget.sharedDocuments.incomingDocuments
        .listen(_enqueueSharedDocument);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _takeInitialSharedDocuments();
      if (widget.onboard) _onboard();
    });
  }

  /// Sign-in first, then handwriting calibration once. Someone already
  /// signed in, with Google or with Apple, is not asked again.
  Future<void> _onboard() async {
    GoogleDriveAccount? account = _drive.currentAccount;
    account ??= await _drive.restoreSession();
    final BillingBackend? backend = _subscription.backend;
    if (account == null && backend?.userId == null && mounted) {
      account = await showGoogleSignIn(
        context,
        client: _drive,
        signInWithApple: backend != null && backend.canSignInWithApple
            ? () async {
                await backend.signInWithApple();
                return backend.userId != null;
              }
            : null,
      );
    }
    if (account != null) {
      // As connecting from the Drive sheet does, so backups may run.
      await _backup.setLinked(true);
      await _autoBackup.reschedule();
    }
    unawaited(_pullFromDrive());
    final HandwritingCalibrationState? state = await _handwritingProfileStore
        .read();
    if (state == null && mounted) await _calibrateHandwriting();
  }

  bool _pulling = false;

  /// Brings the library up to date with a Google Drive backup that another
  /// device has made since, on opening the app and on coming back to it.
  /// Quiet when there is nothing new, or Drive cannot be reached.
  Future<void> _pullFromDrive() async {
    if (_pulling) return;
    _pulling = true;
    try {
      if (!await _backup.isLinked()) return;
      final GoogleDriveAccount? account =
          _drive.currentAccount ?? await _drive.restoreSession();
      if (account == null) return;
      final SyncSummary? summary = await _backup.pullIfChangedElsewhere();
      if (!mounted || summary == null || summary.changedNotes == 0) return;
      final int count = summary.changedNotes;
      final String notes = count == 1 ? '1 note' : '$count notes';
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            summary.keptBoth > 0
                ? 'Updated $notes from Google Drive. A note changed on two '
                      'devices was kept in both versions.'
                : 'Updated $notes from Google Drive',
          ),
        ),
      );
    } on Object {
      // Offline or signed out: tried again when the app next opens.
    } finally {
      _pulling = false;
    }
  }

  @override
  void didUpdateWidget(LibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      oldWidget.repository.removeListener(_onRepositoryChanged);
      widget.repository.addListener(_onRepositoryChanged);
      _thumbnails.dispose();
      _thumbnails = ThumbnailCache(
        repository: widget.repository,
        rasterizer: widget.pdfRasterizer,
      );
      _handwritingProfileStore = handwritingProfileStoreFor(widget.repository);
      _folderId = null;
      _listings.clear();
      _reload();
    }
    if (oldWidget.sharedDocuments != widget.sharedDocuments) {
      _sharedDocumentsSubscription?.cancel();
      _sharedDocumentsSubscription = widget.sharedDocuments.incomingDocuments
          .listen(_enqueueSharedDocument);
      _takeInitialSharedDocuments();
    }
  }

  @override
  void dispose() {
    MemoryPressure.instance.removeListener(_releaseMemory);
    _lifecycle.dispose();
    _searchDebounce?.cancel();
    _sharedDocumentsSubscription?.cancel();
    _repository.removeListener(_onRepositoryChanged);
    _hiddenReload?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _thumbnails.dispose();
    _stylusOnly.dispose();
    _penSettings.dispose();
    _palettePlacement.dispose();
    _openNotes.dispose();
    _autoBackup.dispose();
    _ownedSubscription?.dispose();
    super.dispose();
  }

  /// While a note is in front of the library, its saves come every pause
  /// in the writing; the library behind reads them all once writing has
  /// paused for this long, or as soon as it is shown again.
  static const Duration _hiddenReloadDelay = Duration(seconds: 2);
  Timer? _hiddenReload;

  void _onRepositoryChanged() {
    unawaited(_refreshListings());
    if (!_tabsShowing) {
      _reload();
      return;
    }
    _hiddenReload?.cancel();
    _hiddenReload = Timer(_hiddenReloadDelay, _reload);
  }

  Future<void> _reload() async {
    _hiddenReload?.cancel();
    _hiddenReload = null;
    _searchDebounce?.cancel();
    final int load = ++_loads;
    final String query = _query;
    final bool inTrash = _inTrash && query.isEmpty;

    // These reads are independent. Start all of them before awaiting so a
    // slow filesystem operation does not turn library refresh into a serial
    // waterfall. The generation below still makes the latest refresh win.
    final Future<List<NoteEntry>> trashFuture = _repository.trash();
    final Future<FolderListing> listingFuture = inTrash
        ? trashFuture.then(
            (List<NoteEntry> trash) =>
                FolderListing(folders: const <Folder>[], notes: trash),
          )
        : query.isEmpty
        ? _repository.list(_folderId)
        : _repository.search(query);
    final Future<List<Folder>> pathFuture = _repository.pathTo(_folderId);
    final Future<List<Folder>> foldersFuture = _repository.allFolders();
    final Future<Map<String, int>> countsFuture = _repository.itemCounts();
    // Pictures are let go only for notes gone from every folder, not for
    // those merely in another one: theirs stay on disk for when it opens.
    final bool prune = query.isEmpty && _folderId == null && !inTrash;
    final Future<List<NoteEntry>> everyNoteFuture = prune
        ? _repository.allNotes()
        : Future<List<NoteEntry>>.value(const <NoteEntry>[]);

    final (
      List<NoteEntry> trash,
      FolderListing listing,
      List<Folder> path,
      List<Folder> folders,
      Map<String, int> counts,
      List<NoteEntry> everyNote,
    ) = await (
      trashFuture,
      listingFuture,
      pathFuture,
      foldersFuture,
      countsFuture,
      everyNoteFuture,
    ).wait;
    if (!mounted || load != _loads) {
      return;
    }
    if (query.isEmpty) {
      _listings[_listingKey(_folderId, trash: inTrash)] = listing;
    }
    setState(() {
      _trashCount = trash.length;
      _listing = _sorted(listing, trash: inTrash);
      _path = path;
      _folders = <String, Folder>{
        for (final Folder folder in folders) folder.id: folder,
      };
      _counts = counts;
      if (prune) {
        _thumbnails.retainOnly(<String>{
          for (final NoteEntry note in everyNote) note.id,
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
    // The folder's first pages start drawing now, not when each card is
    // built after the folder's transition. A note in front has them wait.
    if (!_tabsShowing) {
      _thumbnails.prefetch(_listing!.notes, _NoteThumbnail.styleOf(context));
    }
  }

  /// [listing] in the order chosen; Recently Deleted keeps the most
  /// recently deleted first, as they were.
  FolderListing _sorted(FolderListing listing, {required bool trash}) =>
      FolderListing(
        folders: List<Folder>.of(listing.folders)..sort(_sort.compareFolders),
        notes: trash
            ? listing.notes
            : (List<NoteEntry>.of(listing.notes)..sort(_sort.compareNotes)),
      );

  /// The folders from the library down to [id], from what is already known.
  List<Folder> _knownPathTo(String? id) {
    final List<Folder> path = <Folder>[];
    for (
      Folder? at = id == null ? null : _folders[id];
      at != null && path.length <= _folders.length;
      at = at.parentId == null ? null : _folders[at.parentId]
    ) {
      path.insert(0, at);
    }
    return path;
  }

  /// The library changed: every folder kept is read again, so the next
  /// visit to one shows it as it is now. The one shown is read by
  /// [_reload]. A folder that no longer exists is let go.
  Future<void> _refreshListings() async {
    final int epoch = ++_listingsEpoch;
    final Object? shown = _shownListingKey;
    final List<Object?> keys = <Object?>[
      for (final Object? key in _listings.keys)
        if (key != shown) key,
    ];
    if (keys.isEmpty) return;
    final (List<Folder> folders, List<FolderListing> listings) = await (
      _repository.allFolders(),
      Future.wait(<Future<FolderListing>>[
        for (final Object? key in keys)
          key == _trashListing
              ? _repository.trash().then(
                  (List<NoteEntry> trash) =>
                      FolderListing(folders: const <Folder>[], notes: trash),
                )
              : _repository.list(key as String?),
      ]),
    ).wait;
    if (!mounted || epoch != _listingsEpoch) return;
    final Set<String> ids = <String>{
      for (final Folder folder in folders) folder.id,
    };
    for (int i = 0; i < keys.length; i++) {
      final Object? key = keys[i];
      if (!_listings.containsKey(key)) continue;
      if (key is String && !ids.contains(key)) {
        _listings.remove(key);
      } else {
        _listings[key] = listings[i];
      }
    }
  }

  void _scheduleSearchReload() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(_searchDelay, _reload);
  }

  void _openFolder(String? id) {
    if (id == _folderId && _query.isEmpty && !_inTrash) {
      return;
    }
    // The pictures still on their way for the folder left are let go.
    _thumbnails.cancelPending();
    final int direction = _directionTo(id);
    // A folder visited before is shown at once from what it held, quickly,
    // and read again behind it; a new one slowly, as it is read.
    final FolderListing? kept = _listings[_listingKey(id, trash: false)];
    setState(() {
      _scene++;
      _sceneDirection = direction;
      _scenePace = kept == null ? MotionPace.first : MotionPace.revisit;
      _inTrash = false;
      _clearSelection();
      _folderId = id;
      _listing = kept == null ? null : _sorted(kept, trash: false);
      if (kept != null) _path = _knownPathTo(id);
      // What was open on the way stays open in the sidebar.
      for (String? at = id; at != null; at = _folders[at]?.parentId) {
        _expanded.add(at);
      }
    });
    _search.clear();
    if (kept != null && !_tabsShowing) {
      _thumbnails.prefetch(_listing!.notes, _NoteThumbnail.styleOf(context));
    }
    _reload();
  }

  /// Which way the move to folder [id] goes: 1 into it, -1 back out to a
  /// folder around the one shown, or 0 to one beside it.
  int _directionTo(String? id) {
    if (_inTrash) return -1;
    final String? from = _folderId;
    if (id == from) return 0;
    // Whether [inner] is somewhere inside [outer] (the library holds all).
    bool within(String? inner, String? outer) {
      for (String? at = inner; at != null; at = _folders[at]?.parentId) {
        if (at == outer) return true;
      }
      return outer == null;
    }

    if (within(id, from)) return 1;
    if (within(from, id)) return -1;
    return 0;
  }

  void _setSort(LibrarySort sort) {
    setState(() => _sort = sort);
    _reload();
  }

  /// Shows [note] in a tab beside the notes already open, which stay open
  /// on the way back to the library.
  Future<void> _openNote(NoteEntry note) async {
    // The note zooms out of its card, starting on this frame.
    _zoomRect = _artRect(note.id);
    // A note opened before zooms in quickly, a new one slowly and smoothly.
    _zoomPace = _notePaces[note.id] = MotionMemory.instance.recall((
      'note',
      note.id,
    ));
    // Nothing the library was still drawing holds up the note.
    _thumbnails.pause();
    _openNotes.open(note);
    setState(() => _tabsShowing = true);
    unawaited(BackendService.instance.trackProductEvent('note_opened'));
  }

  void _showLibrary() {
    final bool zooming = _tabsShowing;
    // It shrinks back into the card it came from, wherever that is now.
    final String? shown = _openNotes.active?.id;
    if (shown != null) _zoomRect = _artRect(shown) ?? _zoomRect;
    setState(() => _tabsShowing = false);
    // Pictures are drawn once the note has shrunk back into its card
    // ([_onLibraryShown]): until then the cards keep their old ones, and
    // nothing redraws the library under the moving note.
    if (!zooming) _thumbnails.resume();
    if (_hiddenReload != null) _reload();
  }

  /// The library is at rest in front again.
  void _onLibraryShown() {
    if (!_tabsShowing) _thumbnails.resume();
  }

  /// [note] was saved from its editor: its card's picture is drawn from
  /// the first page in memory, and stored, rather than read back from disk.
  void _onNoteSaved(NoteEntry note, NoteContent content) {
    if (!mounted || content.pages.isEmpty) return;
    _thumbnails.capture(note, content.pages.first);
  }

  /// The picture of each note's card, so a note can zoom out of it and back.
  final Map<String, GlobalKey> _artKeys = <String, GlobalKey>{};
  final GlobalKey<_LibraryEditorTransitionState> _transition =
      GlobalKey<_LibraryEditorTransitionState>();
  Rect? _zoomRect;

  GlobalKey _artKeyFor(String noteId) =>
      _artKeys.putIfAbsent(noteId, GlobalKey.new);

  /// The card's picture on screen, as the library lies at rest; null when
  /// it is not shown, such as scrolled away or in another folder.
  Rect? _artRect(String noteId) {
    final RenderObject? box = _artKeys[noteId]?.currentContext
        ?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final Rect shown = box.localToGlobal(Offset.zero) & box.size;
    return _transition.currentState?.atRest(shown) ?? shown;
  }

  Widget _noteTab(
    NoteEntry note,
    Widget Function(VoidCallback rename) tabs,
    VoidCallback onBack,
    ValueChanged<NoteEntry> onRenamed,
  ) {
    return NoteEditorPage(
      repository: _repository,
      note: note,
      entrance: AppMotion.paced(
        noteEntrance(),
        _notePaces.remove(note.id) ?? MotionPace.standard,
      ),
      preview: _thumbnails.peek(note, Theme.of(context).brightness),
      aiClient: widget.aiClient,
      subscription: _subscription,
      handwritingProfileStore: _handwritingProfileStore,
      documentPicker: widget.documentPicker,
      pdfRasterizer: widget.pdfRasterizer,
      pdfPreviewStore: widget.pdfPreviewStore,
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
      onSaved: _onNoteSaved,
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
    await _startNote(draft.name, draft.setup);
  }

  /// A new note on the last template, with no questions asked.
  Future<void> _quickNote() => _startNote(untitledNoteName, _template);

  Future<void> _startNote(String title, PageSetup setup) async {
    // The note opens on this frame; the disk catches up behind the zoom.
    final (:NoteEntry note, :Future<void> saved) = _repository.startNote(
      title: title,
      folderId: _folderId,
      setup: setup,
    );
    unawaited(_openNote(note));
    try {
      await saved;
      unawaited(BackendService.instance.trackProductEvent('note_created'));
    } on Object {
      if (!mounted) return;
      _openNotes.close(note.id);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Couldn't create the note.")),
      );
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

  Future<void> _takeInitialSharedDocuments() async {
    final List<PickedDocument> initial = await widget.sharedDocuments
        .takeInitialDocuments();
    if (!mounted || initial.isEmpty) return;
    for (final PickedDocument doc in initial) {
      _enqueueSharedDocument(doc);
    }
  }

  void _enqueueSharedDocument(PickedDocument picked) {
    _pendingSharedImports.add(picked);
    _drainSharedImports();
  }

  Future<void> _drainSharedImports() async {
    if (_importingShared || !mounted) return;
    _importingShared = true;
    try {
      while (_pendingSharedImports.isNotEmpty && mounted) {
        final PickedDocument next = _pendingSharedImports.removeAt(0);
        await _importPickedDocument(next);
      }
    } finally {
      _importingShared = false;
    }
  }

  /// Imports a PDF as a new note.
  Future<void> _importPdf() async {
    final PickedDocument? picked = await widget.documentPicker.pickPdf();
    if (picked == null || !mounted) return;
    await _importPickedDocument(picked);
  }

  /// Imports a PDF, or a native `.goodnotes` notebook whole: pages, paper,
  /// and editable ink.
  Future<void> _importPickedDocument(PickedDocument picked) async {
    if (!mounted) return;
    final bool notebook = GoodnotesArchiveExtractor.isGoodnotesArchive(
      picked.bytes,
    );
    NoteEntry? note;
    final ImportCancellationToken cancellation = ImportCancellationToken();
    final DocumentIoProgressResult result = await showDocumentIoProgress(
      context,
      title: notebook ? 'Importing Goodnotes notebook' : 'Importing PDF',
      onCancel: cancellation.cancel,
      operation: (_) async {
        note =
            await DocumentImporter(
              rasterizer: widget.pdfRasterizer,
              config: widget.documentIoConfig,
            ).importPdfAsNote(
              repository: _repository,
              picked: picked,
              folderId: _showingTrash ? null : _folderId,
              cancellation: cancellation,
            );
      },
    );
    if (result.error == null && note != null && mounted) {
      unawaited(
        BackendService.instance.trackProductEvent(
          'note_imported',
          detail: notebook ? 'goodnotes' : 'pdf',
        ),
      );
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

  /// The account: sign-in, the subscription, and backup to Google Drive.
  Future<void> _openAccount({bool openPlans = false}) {
    return showAccountPage(
      context,
      _subscription,
      openPlans: openPlans,
      backup: GoogleDriveSheet(
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
        embedded: true,
      ),
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
          } else if (!result.cancelled) {
            unawaited(
              BackendService.instance.trackProductEvent(
                'note_exported',
                detail: 'pdf',
              ),
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
    final FolderListing? kept = _listings[_trashListing];
    setState(() {
      _scene++;
      _sceneDirection = 1;
      _scenePace = kept == null ? MotionPace.first : MotionPace.revisit;
      _clearSelection();
      _inTrash = true;
      _listing = kept == null ? null : _sorted(kept, trash: true);
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

  /// The library as last built while it was in front. Opening a note flips
  /// [_tabsShowing] and nothing else, so the same widget goes back in and the
  /// whole library subtree is skipped on the frame the zoom starts, not
  /// rebuilt for nothing. It is built afresh as soon as it is shown again.
  Widget? _libraryInFront;

  @override
  Widget build(BuildContext context) {
    final Widget library = _tabsShowing && _libraryInFront != null
        ? _libraryInFront!
        : _libraryInFront = _buildLibrary(context);
    // Keep the bounded tab host mounted when browsing the library. Popping
    // its route used to destroy every editor before opening a second note.
    // One scope for both: with two, one back press both left the note and,
    // the library then in front, went up out of its folder.
    return PopScope(
      canPop: !_tabsShowing && _folderId == null && !_selecting && !_inTrash,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop) {
          return;
        }
        if (_tabsShowing) {
          _showLibrary();
        } else if (_selecting) {
          _stopSelecting();
        } else if (_inTrash) {
          _openFolder(null);
        } else {
          _openFolder(_path.length > 1 ? _path[_path.length - 2].id : null);
        }
      },
      child: _LibraryEditorTransition(
        key: _transition,
        showEditor: _tabsShowing,
        origin: _zoomRect,
        pace: _zoomPace,
        onLibraryShown: _onLibraryShown,
        library: library,
        editor: NoteTabsPage(
          notes: _openNotes,
          builder: _noteTab,
          onBack: _showLibrary,
        ),
      ),
    );
  }

  Widget _buildLibrary(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    final WindowSizeClass sizeClass = WindowSizeClass.fromWidth(screen.width);
    final bool compact = sizeClass == WindowSizeClass.compact;
    // Short of the widest layout, the folders slide in from the edge, so
    // the notes have the whole width; a tablet held upright included, and
    // a phone on its side, which is wide but too short for a sidebar.
    final bool drawer =
        sizeClass != WindowSizeClass.expanded ||
        screen.height < Breakpoints.medium;
    final Widget sidebar = _FolderSidebar(
      folders: _folders,
      counts: _counts,
      openFolderId: _query.isEmpty && !_inTrash ? _folderId : null,
      libraryOpen: _query.isEmpty && !_inTrash && _folderId == null,
      trashOpen: _showingTrash,
      trashCount: _trashCount,
      subscription: _subscription,
      onPlans: _openPlans,
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
      searchFocus: _searchFocus,
      sort: _sort,
      grid: _grid,
      onOpenFolder: _openFolder,
      onSort: _setSort,
      onToggleView: () => setState(() => _grid = !_grid),
      onNewFolder: _newFolder,
      onAccount: _openAccount,
      subscription: _subscription,
      onPlans: _openPlans,
      onCalibrateHandwriting: _calibrateHandwriting,
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
    // Back is handled in [build], for the note and the library alike.
    // Only search here wants the keyboard. Raised for anything else, such
    // as a dialog's field, the library would be laid out again on every
    // frame of its slide, under the dialog, and the slide would stutter.
    return ListenableBuilder(
      listenable: _searchFocus,
      builder: (BuildContext context, Widget? scaffold) =>
          IgnoreKeyboard(ignoring: !_searchFocus.hasFocus, child: scaffold!),
      child: Scaffold(
        key: _scaffold,
        backgroundColor: Colors.transparent,
        drawer: drawer
            ? Drawer(
                backgroundColor: Colors.transparent,
                // Opaque: it slides over the notes, whose titles would show
                // through the folder names.
                child: GlassSurface(
                  color: AppColors.of(context).surface,
                  child: SafeArea(child: sidebar),
                ),
              )
            : null,
        // Beside the sidebar, the bar spans only the items, so the sidebar
        // runs the window's full height.
        appBar: drawer ? bar : null,
        floatingActionButton: _selecting || _showingTrash
            ? null
            : _NewNoteButton(
                onQuickNote: _quickNote,
                onNewNote: _newNote,
                onImportPdf: _importPdf,
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
    // The last folder's items fade away toward where they came from as the
    // next folder's are read and rise into place.
    return SceneCrossfade(
      scope: _scene,
      direction: _sceneDirection,
      pace: _scenePace,
      child: LoadingReveal(
        timing: LoadTimings.library,
        semanticsLabel: 'Loading',
        memoryKey: ('folder', _shownListingKey),
        child: _listing == null
            ? null
            : _buildItems(context, compact, _listing!),
      ),
    );
  }

  Widget _buildItems(
    BuildContext context,
    bool compact,
    FolderListing listing,
  ) {
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
    final int folderCount = listing.folders.length;
    final int itemCount = folderCount + listing.notes.length;

    Widget buildItem(BuildContext context, int index) {
      if (index < folderCount) {
        final Folder folder = listing.folders[index];
        return _LibraryItem(
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
        );
      }

      final NoteEntry note = listing.notes[index - folderCount];
      return _LibraryItem(
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
          key: _artKeyFor(note.id),
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
      );
    }

    final EdgeInsets padding = EdgeInsets.fromLTRB(
      compact ? AppSpacing.md : AppSpacing.lg,
      compact ? AppSpacing.xs : AppSpacing.md,
      compact ? AppSpacing.md : AppSpacing.lg,
      // Room for the floating button.
      AppSpacing.xxl + AppSpacing.xl,
    );
    // Larger system text takes fewer, wider cards, so a title and its date
    // still fit beside the menu and the page keeps its size.
    final double textScale = MediaQuery.textScalerOf(
      context,
    ).scale(1).clamp(1.0, 2.0);
    return Align(
      key: ValueKey<int>(_scene),
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        key: const ValueKey<String>('library-items'),
        constraints: const BoxConstraints(maxWidth: AppSizes.maxContentWidth),
        child: _grid
            ? LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  const double aspect = 0.72;
                  // On a short screen, such as a phone on its side, a card
                  // stays shorter than the view, so its title is in sight.
                  final double fitsHeight =
                      (constraints.maxHeight - padding.top) * 0.8 * aspect;
                  return GridView.builder(
                    padding: padding,
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: math.min(
                        (compact ? 180 : 200) * textScale,
                        math.max(120, fitsHeight),
                      ),
                      mainAxisSpacing: AppSpacing.lg,
                      crossAxisSpacing: compact ? AppSpacing.md : AppSpacing.lg,
                      childAspectRatio: aspect,
                    ),
                    itemCount: itemCount,
                    itemBuilder: buildItem,
                  );
                },
              )
            : ListView.builder(
                padding: padding,
                itemCount: itemCount,
                itemBuilder: buildItem,
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
    super.key,
    required this.showEditor,
    required this.origin,
    required this.library,
    required this.editor,
    this.onLibraryShown,
    this.pace = MotionPace.standard,
  });

  final bool showEditor;

  /// How the note comes in: a new one zooms out of its card slowly and
  /// smoothly; one opened before only fades in slightly over the library
  /// ([AppMotion.glance]). Going back, the library is already there, so
  /// the note fades away the same way.
  final MotionPace pace;

  /// Called once the library is back at rest, the note gone from over it.
  final VoidCallback? onLibraryShown;

  /// The card the note opens from and closes into, in global coordinates.
  final Rect? origin;
  final Widget library;
  final Widget editor;

  @override
  State<_LibraryEditorTransition> createState() =>
      _LibraryEditorTransitionState();
}

class _LibraryEditorTransitionState extends State<_LibraryEditorTransition>
    with SingleTickerProviderStateMixin {
  bool _transitioning = false;

  /// How far the editor has come over the library: 0 for the library alone,
  /// 1 for the editor. One spring drives the editor's zoom out of its card,
  /// the library settling back, and the dim, all inside the frame update. A
  /// spring can be grabbed and reversed mid-flight with its velocity kept.
  late final AnimationController _progress =
      AnimationController(vsync: this, value: widget.showEditor ? 1 : 0)
        ..addStatusListener(_settled)
        ..addListener(_syncSnapshots);

  /// Whether the note only fades in or out where it is, with no zoom: it
  /// was opened before, or the library it goes back to is already there.
  bool _glance = false;

  /// How far the note must have come for it to be drawn live again. It builds
  /// its editor about now, and a picture of that, redrawn at full size on
  /// each change, costs more than the last sliver of motion saves.
  static const double _liveAt = 0.98;

  /// The library recedes a little as the note comes over it.
  late final Animation<double> _libraryScale = _progress.drive(
    Tween<double>(begin: 1, end: 0.96),
  );
  late final Animation<double> _dim = _progress.drive(
    Tween<double>(begin: 0, end: 0.12),
  );

  /// The editor fades in over the first part of the zoom, so the card's
  /// shape and the screen's need not match.
  late final Animation<double> _editorOpacity = _progress.drive(
    CurveTween(curve: const Interval(0, 0.3)),
  );

  /// Where the zoom starts and ends, in this widget's own coordinates.
  Rect? _origin;

  /// While the two move, each is drawn once into a picture and the pictures
  /// move, avoiding a full-screen alpha blend on every transition frame.
  final SnapshotController _librarySnapshot = SnapshotController();
  final SnapshotController _editorSnapshot = SnapshotController();

  /// [shown], a rect read off the library as it lies now, as it would lie at
  /// rest: the library is a little smaller while a note covers it.
  Rect atRest(Rect shown) {
    final RenderObject? box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return shown;
    final Offset center = box.localToGlobal(box.size.center(Offset.zero));
    final double scale = _libraryScale.value;
    Offset out(Offset point) => center + (point - center) / scale;
    return Rect.fromPoints(out(shown.topLeft), out(shown.bottomRight));
  }

  Rect? _local(Rect? global) {
    final RenderObject? box = context.findRenderObject();
    if (global == null || box is! RenderBox || !box.attached) return null;
    return Rect.fromPoints(
      box.globalToLocal(global.topLeft),
      box.globalToLocal(global.bottomRight),
    );
  }

  @override
  void didUpdateWidget(_LibraryEditorTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showEditor != widget.showEditor) {
      _transitioning = true;
      // A note with no card yet, as one just made, zooms from the middle, not
      // from where the last note's card was.
      _origin = widget.showEditor
          ? _local(widget.origin)
          : _local(widget.origin) ?? _origin;
      final double target = widget.showEditor ? 1 : 0;
      _glance = !AppMotion.travels(
        widget.showEditor ? widget.pace : MotionPace.revisit,
      );
      if (MediaQuery.disableAnimationsOf(context)) {
        _progress.animateTo(target, duration: AppMotion.reduced);
      } else if (_glance) {
        _progress.animateTo(
          target,
          duration: widget.showEditor ? AppMotion.glance : AppMotion.fadeOut,
          curve: widget.showEditor
              ? AppMotion.glanceCurve
              : AppMotion.fadeOutCurve,
        );
      } else {
        // Seeded with the velocity it had, so reversing mid-flight is smooth.
        _progress.animateWith(
          SpringSimulation(
            AppMotion.pacedSpring(AppMotion.smooth, widget.pace),
            _progress.value,
            target,
            _progress.velocity,
          ),
        );
      }
    }
    _syncSnapshots();
  }

  void _syncSnapshots() {
    _librarySnapshot.allowSnapshotting = _transitioning;
    _editorSnapshot.allowSnapshotting =
        _transitioning && !(widget.showEditor && _progress.value > _liveAt);
  }

  @override
  void dispose() {
    _progress.dispose();
    _librarySnapshot.dispose();
    _editorSnapshot.dispose();
    super.dispose();
  }

  void _settled(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      _finishTransition();
    }
  }

  void _finishTransition() {
    if (!_transitioning || !mounted) return;
    setState(() => _transitioning = false);
    _librarySnapshot.allowSnapshotting = false;
    _editorSnapshot.allowSnapshotting = false;
    if (!widget.showEditor) widget.onLibraryShown?.call();
  }

  /// The card's rect, or a small one at the middle when there is none.
  Rect _start(Size size) =>
      _origin ??
      Rect.fromCenter(
        center: size.center(Offset.zero),
        width: size.width * 0.3,
        height: size.height * 0.3,
      );

  @override
  Widget build(BuildContext context) {
    final bool showEditor = widget.showEditor;
    final AppColors colors = AppColors.of(context);
    final bool reduced = MediaQuery.disableAnimationsOf(context);
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
                child: ScaleTransition(
                  scale: reduced || _glance
                      ? const AlwaysStoppedAnimation<double>(1)
                      : _libraryScale,
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
        // The library dims as the note comes over it: one flat rect with
        // alpha, not a blend of two surfaces.
        Offstage(
          offstage: !_transitioning,
          child: IgnorePointer(
            child: FadeTransition(
              opacity: _dim,
              child: ColoredBox(color: colors.shadow),
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
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints box) {
                    final Size size = box.biggest;
                    return AnimatedBuilder(
                      animation: _progress,
                      builder: (BuildContext context, Widget? child) {
                        final double t = _progress.value.clamp(0.0, 1.0);
                        if (reduced) {
                          return FadeTransition(
                            opacity: _progress,
                            child: child,
                          );
                        }
                        // A glance keeps the zoom's widgets, at rest, so
                        // the editor below is never built anew.
                        final Rect start = _glance
                            ? Offset.zero & size
                            : _start(size);
                        final double scale = ui.lerpDouble(
                          (start.width / size.width).clamp(0.05, 1.0),
                          1,
                          t,
                        )!;
                        final Offset center = Offset.lerp(
                          start.center,
                          size.center(Offset.zero),
                          t,
                        )!;
                        return FadeTransition(
                          opacity: _glance ? _progress : _editorOpacity,
                          child: Transform(
                            transform: Matrix4.identity()
                              ..translateByDouble(center.dx, center.dy, 0, 1)
                              ..scaleByDouble(scale, scale, 1, 1)
                              ..translateByDouble(
                                -size.width / 2,
                                -size.height / 2,
                                0,
                                1,
                              ),
                            child: ClipRRect(
                              clipBehavior: _transitioning
                                  ? Clip.antiAlias
                                  : Clip.none,
                              // Concentric with the card at the start, square
                              // at the screen's edge.
                              borderRadius: BorderRadius.circular(
                                _glance
                                    ? 0
                                    : ui.lerpDouble(AppRadii.large, 0, t)! /
                                          scale,
                              ),
                              child: child,
                            ),
                          ),
                        );
                      },
                      child: TickerMode(
                        enabled: showEditor,
                        child: SnapshotWidget(
                          controller: _editorSnapshot,
                          mode: SnapshotMode.permissive,
                          child: RepaintBoundary(child: widget.editor),
                        ),
                      ),
                    );
                  },
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
    required this.searchFocus,
    required this.sort,
    required this.grid,
    required this.onOpenFolder,
    required this.onSort,
    required this.onToggleView,
    required this.onNewFolder,
    required this.onAccount,
    required this.subscription,
    required this.onPlans,
    required this.onCalibrateHandwriting,
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
  final FocusNode searchFocus;
  final LibrarySort sort;
  final bool grid;
  final ValueChanged<String?> onOpenFolder;
  final ValueChanged<LibrarySort> onSort;
  final VoidCallback onToggleView;
  final VoidCallback onNewFolder;

  /// Opens the account page: sign-in, the subscription, and backup.
  final VoidCallback onAccount;

  /// Shown in the Plans & Credits pill, which [onPlans] opens.
  final SubscriptionController subscription;
  final VoidCallback onPlans;

  /// Opens handwriting calibration, which teaches AI notation the writer's
  /// hand.
  final VoidCallback onCalibrateHandwriting;

  /// Whether a dragged item can go into a folder on the path, and moving
  /// it there. Every segment takes valid drops, including the open folder
  /// when a search result currently lives somewhere else.
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
    final Widget field = _SearchField(
      controller: search,
      focusNode: searchFocus,
    );
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
                                SizedBox(width: 220, child: field),
                                const SizedBox(width: AppSpacing.xs),
                              ],
                              IconButton(
                                key: const ValueKey<String>(
                                  'library-account-button',
                                ),
                                tooltip: 'Account',
                                onPressed: onAccount,
                                icon: const Icon(AppIcons.account),
                              ),
                              // On compact widths, where the bar is full,
                              // the view toggle is in this menu too.
                              PopupMenuButton<Object>(
                                popUpAnimationStyle: AppMotion.pacedPopupStyle(
                                  MotionMemory.instance.peek(('popup', 'sort')),
                                ),
                                onOpened: () => MotionMemory.instance.remember((
                                  'popup',
                                  'sort',
                                )),
                                tooltip: 'Sort',
                                icon: const Icon(AppIcons.sort),
                                onSelected: (Object choice) {
                                  if (choice is LibrarySort) {
                                    onSort(choice);
                                  } else if (choice == #calibrate) {
                                    onCalibrateHandwriting();
                                  } else if (choice == #plans) {
                                    onPlans();
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
                                    const PopupMenuDivider(),
                                    _menuItem<Object>(
                                      context,
                                      value: #plans,
                                      label: 'Plans & AI Credits',
                                      icon: AppIcons.plans,
                                    ),
                                    _menuItem<Object>(
                                      context,
                                      value: #calibrate,
                                      label: 'AI handwriting…',
                                      icon: AppIcons.pen,
                                    ),
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
  const _SearchField({required this.controller, required this.focusNode});

  final TextEditingController controller;
  final FocusNode focusNode;

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
            focusNode: focusNode,
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
        _DropTarget(
          key: ValueKey<String>('breadcrumb-${id ?? 'library'}'),
          canAccept: (_Dragged item) => canDrop(item, id),
          onAccept: (_Dragged item) => onDrop(item, id),
          radius: AppRadii.medium,
          child: last
              ? SizedBox(
                  height: AppSizes.minTouchTarget,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs,
                    ),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Semantics(
                        header: true,
                        child: Text(
                          name,
                          style: text.titleLarge,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                )
              : TextButton(
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
    return GentleSwitcher(
      value: path.map((Folder folder) => folder.id).join('/'),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            clipBehavior: Clip.none,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: Row(children: crumbs),
            ),
          );
        },
      ),
    );
  }
}

/// The primary action, floating at the bottom: the accent color and the
/// floating shadow, like the editor's palette. Its menu imports a PDF as a
/// note, asks for a template, or starts a note straight away on the last
/// one; the quickest choice sits nearest the button.
class _NewNoteButton extends StatelessWidget {
  const _NewNoteButton({
    required this.onQuickNote,
    required this.onNewNote,
    required this.onImportPdf,
  });

  final VoidCallback onQuickNote;
  final VoidCallback onNewNote;
  final VoidCallback onImportPdf;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    const BorderRadius radius = AppBorderRadius.large;
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
        animated: !MediaQuery.disableAnimationsOf(context),
        // Under the opposite direction above, directional start resolves to
        // the button's trailing edge and aligns the menu's trailing edge to it.
        style: const MenuStyle(alignment: AlignmentDirectional.topStart),
        alignmentOffset: const Offset(0, AppSpacing.sm),
        menuChildren: <Widget>[
          reads(
            MenuItemButton(
              leadingIcon: const Icon(AppIcons.pdf),
              onPressed: onImportPdf,
              child: const Text('Import PDF'),
            ),
          ),
          reads(
            MenuItemButton(
              leadingIcon: const Icon(AppIcons.template),
              onPressed: onNewNote,
              child: const Text('Template…'),
            ),
          ),
          reads(
            MenuItemButton(
              leadingIcon: const Icon(AppIcons.newNote),
              onPressed: onQuickNote,
              child: const Text('Quick start'),
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
                      shape: const RoundedRectangleBorder(borderRadius: radius),
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
    super.key,
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
              duration: AppMotion.resolve(context, AppMotion.fadeIn),
              foregroundDecoration: BoxDecoration(
                color: over ? colors.accent.withValues(alpha: 0.10) : null,
                borderRadius: AppBorderRadius.circular(radius),
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

  /// The icon rides just above the stylus, where it stays visible. Flutter
  /// normally hit-tests drop targets at the stylus; [dropHotspotOffset]
  /// moves that test to the icon's center instead.
  static const double _iconLift = AppSpacing.md;
  static const Offset dropHotspotOffset = Offset(0, -_iconLift);
  static const Offset _anchor = Offset(
    AppSpacing.md + AppSizes.icon / 2,
    AppSpacing.sm + AppSizes.icon / 2 + _iconLift,
  );

  static Offset anchorAbovePointer(
    Draggable<Object> draggable,
    BuildContext context,
    Offset position,
  ) => _anchor;

  final Widget icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    const BorderRadius radius = AppBorderRadius.large;
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
    // Scrolls when a keyboard leaves too little room, as on a small phone
    // while a dialog over the library is being typed in.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (searching || trash)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: AppGlass.muted(colors),
                  shape: BoxShape.circle,
                ),
                child: SizedBox.square(
                  dimension: 72,
                  child: Icon(
                    searching ? AppIcons.noResults : AppIcons.trash,
                    size: 32,
                    color: colors.textSecondary,
                  ),
                ),
              )
            else
              SizedBox(
                width: 84,
                height: 104,
                child: DogEar(
                  flapColor: colors.surfaceMuted,
                  backgroundColor: colors.surfaceMuted,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 28, 14, 14),
                    child: Column(
                      children: <Widget>[
                        for (final double width in <double>[
                          1,
                          0.74,
                          0.88,
                        ]) ...<Widget>[
                          FractionallySizedBox(
                            widthFactor: width,
                            child: Container(
                              height: 7,
                              decoration: BoxDecoration(
                                color: colors.textSecondary.withValues(
                                  alpha: 0.28,
                                ),
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                        ],
                      ],
                    ),
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
  /// The height of a row in the list at the standard text size. Rows grow
  /// with larger text, so the date under the title is never cut off.
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
    final double rowHeight = math.max(
      _rowHeight,
      MediaQuery.textScalerOf(context).scale(_rowHeight),
    );
    final Widget menu = PopupMenuButton<_ItemAction>(
      popUpAnimationStyle: AppMotion.pacedPopupStyle(
        MotionMemory.instance.peek(('popup', 'item-actions')),
      ),
      onOpened: () => MotionMemory.instance.remember(('popup', 'item-actions')),
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
            height: rowHeight,
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
    final BorderRadius radius = grid
        ? AppBorderRadius.large
        : AppBorderRadius.medium;
    final Duration settle = AppMotion.resolve(
      context,
      AppMotion.snappy.duration,
    );
    // The badge pops in from 0.6 and its check draws on, in selection mode.
    final Widget check = AnimatedScale(
      scale: widget.selected ? 1 : 0.6,
      duration: settle,
      curve: AppMotion.popCurve,
      child: AnimatedContainer(
        duration: settle,
        curve: AppMotion.fadeInCurve,
        width: 22,
        height: 22,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.selected ? colors.accent : colors.surface,
          border: Border.all(
            color: widget.selected ? colors.accent : colors.textSecondary,
            width: 1.5,
          ),
          boxShadow: AppShadows.paper(colors),
        ),
        child: StrokeDrawCheck(
          selected: widget.selected,
          color: colors.onAccent,
          strokeWidth: 1.8,
        ),
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
        duration: AppMotion.resolve(context, AppMotion.snappy.duration),
        curve: AppMotion.fadeInCurve,
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
                    height: grid ? AppSizes.minTouchTarget : rowHeight,
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
                        height: rowHeight,
                        child: Center(child: menu),
                      ),
              ),
            if (!grid) SizedBox(height: rowHeight, width: double.infinity),
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
      // Keep the preview clear of the stylus and use its icon, rather than
      // the stylus itself, as the point that enters a drop target.
      dragAnchorStrategy: _DragFeedback.anchorAbovePointer,
      feedbackOffset: _DragFeedback.dropHotspotOffset,
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
    super.key,
    required this.note,
    required this.cache,
    this.alignment = Alignment.center,
  });

  final NoteEntry note;
  final ThumbnailCache cache;

  /// Where the page sits in the space it is given.
  final AlignmentGeometry alignment;

  /// The colors the pictures are drawn in under [context]'s theme.
  static ThumbnailStyle styleOf(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return ThumbnailStyle(
      brightness: Theme.of(context).brightness,
      paper: colors.writingSurface,
      rule: colors.pageRule,
      marginRule: colors.pageMarginRule,
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final ThumbnailStyle style = styleOf(context);
    final BorderRadius radius = BorderRadius.circular(AppRadii.small + 2);
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
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
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: colors.shadow.withValues(alpha: isDark ? 0.35 : 0.08),
                  blurRadius: 3,
                  spreadRadius: 0.5,
                ),
                BoxShadow(
                  color: colors.shadow.withValues(alpha: isDark ? 0.25 : 0.06),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: LoadingReveal(
                effect: RevealEffect.fade,
                timing: LoadTimings.thumbnail,
                memoryKey: ('thumbnail', note.id),
                child: image == null
                    ? null
                    : SizedBox.expand(
                        child: RawImage(
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
    required this.subscription,
    required this.onPlans,
  });

  static const double width = 280;

  final SubscriptionController subscription;
  final VoidCallback onPlans;

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
            _SidebarAiQuotaCard(subscription: subscription, onPlans: onPlans),
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

/// The AI Quota card pinned in the sidebar: displays current plan,
/// remaining token quota, and allows navigating to plans and credits.
class _SidebarAiQuotaCard extends StatelessWidget {
  const _SidebarAiQuotaCard({
    required this.subscription,
    required this.onPlans,
  });

  final SubscriptionController subscription;
  final VoidCallback onPlans;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: subscription,
      builder: (BuildContext context, Widget? _) {
        final AppColors colors = AppColors.of(context);
        final TextTheme text = Theme.of(context).textTheme;
        final SubscriptionPlan? plan = subscription.activePlan;
        final bool hasTokens =
            (plan != null || subscription.hasFreeCredit) &&
            subscription.remainingCreditsMicroUsd > 0;
        final String planTitle =
            plan?.title ??
            (subscription.hasFreeCredit ? 'Free Tier' : 'AI Plans');
        final String percent = formatTokenPercent(
          subscription.remainingCreditsMicroUsd,
          subscription.includedCreditsMicroUsd,
        );

        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xs,
            vertical: AppSpacing.xxs,
          ),
          child: Material(
            color: colors.surfaceMuted,
            borderRadius: AppBorderRadius.medium,
            child: Tooltip(
              message: 'Plans & Credits',
              child: InkWell(
                key: const ValueKey<String>('library-plans-button'),
                borderRadius: AppBorderRadius.medium,
                onTap: onPlans,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Icon(AppIcons.plans, size: 16, color: colors.accent),
                          const SizedBox(width: AppSpacing.xs),
                          Expanded(
                            child: Text(
                              planTitle,
                              style: text.labelMedium?.copyWith(
                                color: colors.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            hasTokens ? percent : 'Upgrade',
                            style: text.labelSmall?.copyWith(
                              color: colors.accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      TokenMeterBar(
                        key: const ValueKey<String>('library-token-bar'),
                        fraction: subscription.tokenFraction,
                        height: 5,
                      ),
                    ],
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
    const BorderRadius radius = AppBorderRadius.medium;
    final bool? expanded = widget.expanded;
    final bool hasMenu = widget.actions.isNotEmpty && widget.onAction != null;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: Material(
        color: widget.selected
            ? colors.selected
            : colors.selected.withValues(alpha: 0),
        animationDuration: AppMotion.resolve(
          context,
          AppMotion.snappy.duration,
        ),
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
                  duration: AppMotion.resolve(context, AppMotion.fadeIn),
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
                          child: AnimatedDefaultTextStyle(
                            duration: AppMotion.resolve(
                              context,
                              AppMotion.snappy.duration,
                            ),
                            curve: AppMotion.fadeInCurve,
                            style: text.bodyMedium!.copyWith(
                              color: widget.selected
                                  ? colors.accent
                                  : colors.textPrimary,
                              fontWeight: widget.selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                            child: Text(
                              widget.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
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
                popUpAnimationStyle: AppMotion.pacedPopupStyle(
                  MotionMemory.instance.peek(('popup', 'folder-actions')),
                ),
                onOpened: () =>
                    MotionMemory.instance.remember(('popup', 'folder-actions')),
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
