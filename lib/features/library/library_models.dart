import 'package:flutter/foundation.dart';

/// Names are trimmed and at most this long.
const int maxNameLength = 120;

/// [name] trimmed and cut to [maxNameLength], or null when nothing is left.
String? cleanName(String name) {
  final String trimmed = name.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  return trimmed.length <= maxNameLength
      ? trimmed
      : trimmed.substring(0, maxNameLength).trimRight();
}

/// The color a folder is marked with, so folders can be told apart at a
/// glance in the sidebar and the grid. Older stored names remain valid and
/// are mapped onto the six shared highlighters by the presentation layer.
enum FolderColor {
  accent('None'),
  red('Rose'),
  orange('Peach'),
  yellow('Lemon'),
  green('Mint'),
  teal('Sky'),
  purple('Lilac'),
  pink('Rose'),
  gray('Gray');

  const FolderColor(this.label);

  final String label;

  /// The hex color string (e.g. `#7761A5`) used to represent this folder
  /// color across the library and study desk.
  String get colorHex => switch (this) {
    FolderColor.accent => '#7761A5',
    FolderColor.red => '#D9480F',
    FolderColor.orange => '#E8590C',
    FolderColor.yellow => '#B45309',
    FolderColor.green => '#2F9E44',
    FolderColor.teal => '#0C8599',
    FolderColor.purple => '#7048E8',
    FolderColor.pink => '#C2255C',
    FolderColor.gray => '#6B7280',
  };

  static FolderColor byName(Object? name) {
    for (final FolderColor color in values) {
      if (color.name == name) {
        return color;
      }
    }
    return accent;
  }
}

/// A folder in the library. The root is not a folder; a folder at the top
/// level has no [parentId]. Folders nest to any depth.
@immutable
class Folder {
  const Folder({
    required this.id,
    required this.name,
    required this.parentId,
    required this.created,
    required this.modified,
    this.color = FolderColor.accent,
  });

  /// A folder stored before folders had colors is [FolderColor.accent].
  factory Folder.fromJson(Map<String, Object?> json) {
    return Folder(
      id: json['id']! as String,
      name: json['name']! as String,
      parentId: json['parentId'] as String?,
      created: DateTime.fromMillisecondsSinceEpoch(json['created']! as int),
      modified: DateTime.fromMillisecondsSinceEpoch(json['modified']! as int),
      color: FolderColor.byName(json['color']),
    );
  }

  final String id;
  final String name;
  final String? parentId;
  final DateTime created;
  final DateTime modified;
  final FolderColor color;

  Folder copyWith({
    String? name,
    String? Function()? parentId,
    DateTime? modified,
    FolderColor? color,
  }) {
    return Folder(
      id: id,
      name: name ?? this.name,
      parentId: parentId == null ? this.parentId : parentId(),
      created: created,
      modified: modified ?? this.modified,
      color: color ?? this.color,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'parentId': parentId,
      'created': created.millisecondsSinceEpoch,
      'modified': modified.millisecondsSinceEpoch,
      'color': color.name,
    };
  }
}

/// A note as the library lists it. Its pages and ink are stored apart, so
/// listing never loads ink.
@immutable
class NoteEntry {
  const NoteEntry({
    required this.id,
    required this.title,
    required this.folderId,
    required this.created,
    required this.modified,
    required this.pageCount,
    this.searchText = '',
    this.deleted,
    this.revision = 0,
  });

  factory NoteEntry.fromJson(Map<String, Object?> json) {
    return NoteEntry(
      id: json['id']! as String,
      title: json['title']! as String,
      folderId: json['folderId'] as String?,
      created: DateTime.fromMillisecondsSinceEpoch(json['created']! as int),
      modified: DateTime.fromMillisecondsSinceEpoch(json['modified']! as int),
      pageCount: (json['pageCount'] as int?) ?? 1,
      searchText: json['searchText'] as String? ?? '',
      revision: (json['revision'] as int?) ?? 0,
      deleted: json['deleted'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(json['deleted']! as int),
    );
  }

  final String id;
  final String title;
  final String? folderId;
  final DateTime created;
  final DateTime modified;
  final int pageCount;

  /// A compact index of text recognized from the note's handwriting.
  final String searchText;

  /// When it was moved to Recently Deleted; null while it is in the
  /// library.
  final DateTime? deleted;

  /// How many times the note's pages have been saved. Unlike [modified],
  /// a rename leaves it, and it is stored exactly: it names the note's
  /// picture in the library.
  final int revision;

  NoteEntry copyWith({
    String? title,
    String? Function()? folderId,
    DateTime? modified,
    int? pageCount,
    String? searchText,
    DateTime? Function()? deleted,
    int? revision,
  }) {
    return NoteEntry(
      id: id,
      title: title ?? this.title,
      folderId: folderId == null ? this.folderId : folderId(),
      created: created,
      modified: modified ?? this.modified,
      pageCount: pageCount ?? this.pageCount,
      searchText: searchText ?? this.searchText,
      deleted: deleted == null ? this.deleted : deleted(),
      revision: revision ?? this.revision,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'title': title,
      'folderId': folderId,
      'created': created.millisecondsSinceEpoch,
      'modified': modified.millisecondsSinceEpoch,
      'pageCount': pageCount,
      if (searchText.isNotEmpty) 'searchText': searchText,
      if (deleted != null) 'deleted': deleted!.millisecondsSinceEpoch,
      if (revision != 0) 'revision': revision,
    };
  }
}

/// What a folder holds directly.
@immutable
class FolderListing {
  const FolderListing({required this.folders, required this.notes});

  final List<Folder> folders;
  final List<NoteEntry> notes;

  bool get isEmpty => folders.isEmpty && notes.isEmpty;
}

/// Everything below a folder, counted for a delete confirmation.
@immutable
class FolderTotals {
  const FolderTotals({required this.folders, required this.notes});

  final int folders;
  final int notes;
}

/// The order folders, and separately notes, are listed in.
enum LibrarySort {
  modified('Last modified'),
  created('Date created'),
  title('Title');

  const LibrarySort(this.label);

  final String label;

  int compareFolders(Folder a, Folder b) {
    return switch (this) {
      LibrarySort.modified => b.modified.compareTo(a.modified),
      LibrarySort.created => b.created.compareTo(a.created),
      LibrarySort.title => _byName(a.name, b.name),
    };
  }

  int compareNotes(NoteEntry a, NoteEntry b) {
    return switch (this) {
      LibrarySort.modified => b.modified.compareTo(a.modified),
      LibrarySort.created => b.created.compareTo(a.created),
      LibrarySort.title => _byName(a.title, b.title),
    };
  }

  static int _byName(String a, String b) {
    final int folded = a.toLowerCase().compareTo(b.toLowerCase());
    return folded != 0 ? folded : a.compareTo(b);
  }
}
