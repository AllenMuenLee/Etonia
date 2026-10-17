import 'package:flutter/material.dart';

import '../../../shared/widgets/processing.dart';
import '../../../app/theme/app_tokens.dart';

class DocumentIoProgressResult {
  const DocumentIoProgressResult({this.error, this.cancelled = false});
  final Object? error;
  final bool cancelled;
}

typedef DocumentIoOperation =
    Future<void> Function(
      void Function(int completed, int total) reportProgress,
    );

Future<DocumentIoProgressResult> showDocumentIoProgress(
  BuildContext context, {
  required String title,
  required DocumentIoOperation operation,
  required VoidCallback onCancel,
}) async {
  return await showDialog<DocumentIoProgressResult>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _DocumentIoProgressDialog(
          title: title,
          operation: operation,
          onCancel: onCancel,
        ),
      ) ??
      const DocumentIoProgressResult(cancelled: true);
}

class _DocumentIoProgressDialog extends StatefulWidget {
  const _DocumentIoProgressDialog({
    required this.title,
    required this.operation,
    required this.onCancel,
  });
  final String title;
  final DocumentIoOperation operation;
  final VoidCallback onCancel;

  @override
  State<_DocumentIoProgressDialog> createState() =>
      _DocumentIoProgressDialogState();
}

class _DocumentIoProgressDialogState extends State<_DocumentIoProgressDialog> {
  int _completed = 0;
  int _total = 0;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    Object? error;
    try {
      await widget.operation((int completed, int total) {
        if (mounted) {
          setState(() {
            _completed = completed;
            _total = total;
          });
        }
      });
    } on Object catch (caught) {
      error = caught;
    }
    if (mounted) {
      Navigator.of(
        context,
      ).pop(DocumentIoProgressResult(error: error, cancelled: _cancelled));
    }
  }

  void _cancel() {
    if (_cancelled) return;
    setState(() => _cancelled = true);
    widget.onCancel();
  }

  @override
  Widget build(BuildContext context) {
    final double? value = _total > 0 ? _completed / _total : null;
    final String status = _cancelled
        ? 'Cancelling…'
        : _total > 0
        ? '$_completed of $_total pages'
        : 'Preparing…';
    return AlertDialog(
      title: Text(widget.title),
      content: Semantics(
        liveRegion: true,
        label: '${widget.title}, $status',
        child: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SizedBox(height: AppSpacing.xs),
              ShimmerTrack(value: value),
              const SizedBox(height: AppSpacing.sm),
              Text(
                status,
                style: Theme.of(context).textTheme.bodySmall!.copyWith(
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _cancelled ? null : _cancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
