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
/// glance in the sidebar and the grid. Each has a shade for light and for
/// dark themes, as ARGB; [accent] follows the app's accent color.
enum FolderColor {
  accent('Blue', null, null),
  red('Red', 0xFFD9480F, 0xFFFF8A65),
  orange('Orange', 0xFFE8590C, 0xFFFFA94D),
  yellow('Yellow', 0xFFE0A100, 0xFFFFD43B),
  green('Green', 0xFF2F9E44, 0xFF69DB7C),
  teal('Teal', 0xFF0C8599, 0xFF66D9E8),
  purple('Purple', 0xFF7048E8, 0xFFB197FC),
  pink('Pink', 0xFFC2255C, 0xFFF783AC),
  gray('Gray', 0xFF5C6370, 0xFFADB5BD);

  const FolderColor(this.label, this.light, this.dark);

  final String label;

  /// Null for [accent].
  final int? light;
  final int? dark;

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
    this.deleted,
  });

  factory NoteEntry.fromJson(Map<String, Object?> json) {
    return NoteEntry(
      id: json['id']! as String,
      title: json['title']! as String,
      folderId: json['folderId'] as String?,
      created: DateTime.fromMillisecondsSinceEpoch(json['created']! as int),
      modified: DateTime.fromMillisecondsSinceEpoch(json['modified']! as int),
      pageCount: (json['pageCount'] as int?) ?? 1,
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

  /// When it was moved to Recently Deleted; null while it is in the
  /// library.
  final DateTime? deleted;

  NoteEntry copyWith({
    String? title,
    String? Function()? folderId,
    DateTime? modified,
    int? pageCount,
    DateTime? Function()? deleted,
  }) {
    return NoteEntry(
      id: id,
      title: title ?? this.title,
      folderId: folderId == null ? this.folderId : folderId(),
      created: created,
      modified: modified ?? this.modified,
      pageCount: pageCount ?? this.pageCount,
      deleted: deleted == null ? this.deleted : deleted(),
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
      if (deleted != null) 'deleted': deleted!.millisecondsSinceEpoch,
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
