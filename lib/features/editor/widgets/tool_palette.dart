import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/theme/app_icons.dart';
import '../../../shared/feedback/app_haptics.dart';
import '../../../shared/widgets/app_controls.dart';
import '../ai/ai_assistant_controller.dart';
import '../audio/note_audio.dart';
import '../ink/eraser_settings.dart';
import '../ink/ink_palette.dart';
import '../ink/pen_settings.dart';
import '../ink/ruler.dart';
import '../ink/stroke.dart';
import 'ai_options.dart';
import 'eraser_options.dart';
import 'image_options.dart';
import 'ink_color_picker.dart';
import 'palette_button.dart';
import 'palette_popover.dart';
import 'pen_advanced_panel.dart';
import 'recording_options.dart';
import 'select_options.dart';
import 'sticky_options.dart';
import 'stroke_width_picker.dart';
import '../sticky/sticky_note.dart';

class PopoverChanged extends ChangeNotifier {
  void notify() => notifyListeners();
}

/// Handles to the palette's popovers, for code outside the palette that
/// needs to know whether one is open.
class ToolPaletteController {
  final MenuController penMenu = MenuController();
  final MenuController eraserMenu = MenuController();
  final MenuController selectMenu = MenuController();
  final MenuController stickyMenu = MenuController();
  final MenuController imageMenu = MenuController();
  final MenuController aiMenu = MenuController();
  final MenuController recordingMenu = MenuController();

  /// Whether the palette is unfolded to show its secondary tools, the
  /// ruler. The screen lays out around the palette's size,
  /// so it listens to this too.
  final ValueNotifier<bool> expanded = ValueNotifier<bool>(false);

  /// Notifies when a popover opens or closes.
  final PopoverChanged popoverChanged = PopoverChanged();

  bool get hasOpenPopover {
    return penMenu.isOpen ||
        eraserMenu.isOpen ||
        selectMenu.isOpen ||
        stickyMenu.isOpen ||
        imageMenu.isOpen ||
        aiMenu.isOpen ||
        recordingMenu.isOpen;
  }

  void closeAll() {
    penMenu.close();
    eraserMenu.close();
    selectMenu.close();
    stickyMenu.close();
    imageMenu.close();
    aiMenu.close();
    recordingMenu.close();
  }
}

/// The edge of the page the palette is docked against. It lies along the
/// edge: across the top and bottom, and down the sides.
enum PaletteEdge {
  top('top'),
  bottom('bottom'),
  left('left'),
  right('right');

  const PaletteEdge(this.label);

  final String label;

  Axis get axis =>
      this == top || this == bottom ? Axis.horizontal : Axis.vertical;
}

/// Where the palette floats: the edge it is docked against and how far
/// along that edge, from 0 (its top or left end) to 1 (its bottom or right
/// end). It starts centered across the top.
@immutable
class PalettePlacement {
  const PalettePlacement({this.edge = PaletteEdge.top, this.along = 0.5})
    : assert(along >= 0 && along <= 1);

  final PaletteEdge edge;
  final double along;

  /// The palette's top-left corner when docked in [region], [margin] from
  /// its edge.
  Offset originIn(Rect region, double margin, {bool expanded = false}) {
    final Size size = ToolPalette.sizeFor(edge.axis, expanded: expanded);
    final double freeX = math.max(0, region.width - 2 * margin - size.width);
    final double freeY = math.max(0, region.height - 2 * margin - size.height);
    final double alongX = region.left + margin + freeX * along;
    final double alongY = region.top + margin + freeY * along;
    return switch (edge) {
      PaletteEdge.top => Offset(alongX, region.top + margin),
      PaletteEdge.bottom => Offset(
        alongX,
        math.max(region.top, region.bottom - margin - size.height),
      ),
      PaletteEdge.left => Offset(region.left + margin, alongY),
      PaletteEdge.right => Offset(
        math.max(region.left, region.right - margin - size.width),
        alongY,
      ),
    };
  }

  /// The edge of [region] nearest [point].
  static PaletteEdge nearestEdge(Rect region, Offset point) {
    final Map<PaletteEdge, double> distances = <PaletteEdge, double>{
      PaletteEdge.top: point.dy - region.top,
      PaletteEdge.bottom: region.bottom - point.dy,
      PaletteEdge.left: point.dx - region.left,
      PaletteEdge.right: region.right - point.dx,
    };
    return distances.entries
        .reduce(
          (MapEntry<PaletteEdge, double> a, MapEntry<PaletteEdge, double> b) =>
              b.value < a.value ? b : a,
        )
        .key;
  }

  /// How near, in logical pixels, to the middle of its edge a palette is
  /// let go to settle exactly there.
  static const double centerSnap = 72;

  /// The placement nearest a palette let go centered on [center] in
  /// [region]: against the nearest edge, where it was along it, or at the
  /// edge's middle when let go within [centerSnap] of it.
  factory PalettePlacement.nearest(
    Rect region,
    Offset center,
    double margin, {
    bool expanded = false,
  }) {
    final PaletteEdge edge = nearestEdge(region, center);
    final Size size = ToolPalette.sizeFor(edge.axis, expanded: expanded);
    final bool across = edge.axis == Axis.horizontal;
    final double offMiddle = across
        ? center.dx - region.center.dx
        : center.dy - region.center.dy;
    if (offMiddle.abs() <= centerSnap) {
      return PalettePlacement(edge: edge);
    }
    final double free = across
        ? region.width - 2 * margin - size.width
        : region.height - 2 * margin - size.height;
    final double start = across
        ? center.dx - size.width / 2 - region.left
        : center.dy - size.height / 2 - region.top;
    final double along = free <= 0
        ? 0.5
        : ((start - margin) / free).clamp(0.0, 1.0);
    return PalettePlacement(edge: edge, along: along);
  }

  @override
  bool operator ==(Object other) {
    return other is PalettePlacement &&
        other.edge == edge &&
        other.along == along;
  }

  @override
  int get hashCode => Object.hash(edge, along);
}

/// The floating tool palette: the pen, eraser, Select, Sticky note, image
/// insertion, and AI mode, and, folded away behind an arrow at its end, the
/// ruler. Each tool,
/// pressed while selected, opens its options: the pen's ink color and
/// width (and, folded away, its advanced settings), the eraser's mode and
/// size, Select's Paste, and the assistant's notation settings.
///
/// Holding it anywhere, on its tools too, moves it: held a moment, the
/// palette lights up in the accent color; held for [liftDelay], it lifts
/// off the page with a deeper shadow and follows the finger until let go.
/// A tap on a tool is just a tap.
///
/// It lies along the [edge] it is docked against, so it turns between a
/// row and a column as it is dragged from edge to edge, and its panels
/// open toward the page.
///
/// It listens to [tool], [penSettings], and [eraserSettings] itself, so
/// changing any of them rebuilds only the palette.
class ToolPalette extends StatelessWidget {
  const ToolPalette({
    super.key,
    this.edge = PaletteEdge.top,
    required this.tool,
    required this.penSettings,
    required this.eraserSettings,
    required this.clipboardListenable,
    required this.canPaste,
    required this.onPaste,
    required this.aiActive,
    required this.onTurnOnAi,
    this.assistant,
    this.penConfig = const PenConfig(),
    this.eraserConfig = const EraserConfig(),
    this.dense = false,
    this.controller,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onMoveTo,
    this.stickySettings,
    this.onStickySettingsChanged,
    this.stickyTargetLabel,
    this.onChooseImageFromGallery,
    this.onTakePhoto,
    this.onChooseSvg,
    this.ruler,
    this.recording,
  });

  static const double _padding = AppSpacing.xxs;

  /// The tools always shown; an arrow folds the rest in and out.
  static const int _primaryCount = 6;
  static const int _secondaryCount = 2;
  static const double _buttonStep = 44;

  /// How long the secondary tools take to fold in or out.
  static Duration get unfoldDuration => AppMotion.snappy.duration;

  /// The ruler the Ruler button shows and hides. Without it there is no
  /// Ruler button.
  final RulerController? ruler;

  /// The microphone and the note's recordings. Without it there is no Record
  /// button.
  final RecordingToolData? recording;

  /// Callbacks for inserting images from gallery or camera.
  final VoidCallback? onChooseImageFromGallery;
  final VoidCallback? onTakePhoto;
  final VoidCallback? onChooseSvg;

  /// The look of the next sticky note. Without it there is no Sticky note
  /// tool.
  final ValueListenable<StickyNoteSettings>? stickySettings;

  /// Called with each choice in the sticky note options.
  final ValueChanged<StickyNoteSettings>? onStickySettingsChanged;

  /// The sticky note those choices also restyle, as announced, if any.
  final ValueGetter<String?>? stickyTargetLabel;

  /// How long the surface is held before the palette lifts to be dragged.
  static const Duration liftDelay = Duration(milliseconds: 450);

  final PaletteEdge edge;

  /// A row along the top and bottom, a column down the sides.
  Axis get axis => edge.axis;

  final ValueNotifier<EditorTool> tool;
  final ValueNotifier<PenSettings> penSettings;
  final ValueNotifier<EraserSettings> eraserSettings;

  /// Fires when [canPaste] may have changed.
  final Listenable clipboardListenable;

  /// Whether there is anything to paste.
  final ValueGetter<bool> canPaste;

  final VoidCallback onPaste;

  /// Whether AI mode is on: the assistant's notes are shown, and writing on
  /// the page with the AI tool is for the assistant.
  final ValueListenable<bool> aiActive;

  /// Turns AI mode on. While it is on, the AI button opens the assistant's
  /// options instead; the chat's close button turns it off.
  final VoidCallback onTurnOnAi;

  /// The assistant whose settings the AI button's options change; without
  /// it the button has no options.
  final AiAssistantController? assistant;

  /// Choosing a tool is always allowed.
  VoidCallback? _choose(VoidCallback choose) => choose;

  final PenConfig penConfig;
  final EraserConfig eraserConfig;
  final bool dense;
  final ToolPaletteController? controller;

  /// Called as the lifted palette is dragged, with how far it moved each
  /// time; without them the palette stays put.
  final VoidCallback? onDragStart;
  final ValueChanged<Offset>? onDragUpdate;
  final VoidCallback? onDragEnd;

  /// Docks the palette against an edge; offered to assistive technology in
  /// place of dragging.
  final ValueChanged<PaletteEdge>? onMoveTo;

  /// The palette's outer size, folded or [expanded]; fixed so the screen can
  /// lay out around it.
  static Size sizeFor(Axis axis, {bool expanded = false}) {
    const double thickness = AppSizes.minTouchTarget + 2 * _padding;
    // The primary tools and the toggle, and the secondary tools beside them
    // once unfolded.
    final int count = _primaryCount + 1 + (expanded ? _secondaryCount : 0);
    final double length =
        (count - 1) * _buttonStep + AppSizes.minTouchTarget + 2 * _padding;
    return axis == Axis.vertical
        ? Size(thickness, length)
        : Size(length, thickness);
  }

  @override
  Widget build(BuildContext context) {
    return _LiftableSurface(
      semanticLabel: 'Move tools, docked at the ${edge.label}',
      moveActions: <CustomSemanticsAction, VoidCallback>{
        if (onMoveTo != null)
          for (final PaletteEdge other in PaletteEdge.values)
            if (other != edge)
              CustomSemanticsAction(
                label: 'Move tools to the ${other.label}',
              ): () =>
                  onMoveTo!(other),
      },
      onLift: onDragStart,
      onMove: onDragUpdate,
      onDrop: onDragEnd,
      child: Padding(
        padding: const EdgeInsets.all(_padding),
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          label: 'Tools',
          child: FocusTraversalGroup(
            child: ListenableBuilder(
              listenable: Listenable.merge(<Listenable>[
                tool,
                penSettings,
                eraserSettings,
                aiActive,
                ?stickySettings,
                ?ruler,
                ?recording?.recorder,
                ?controller?.expanded,
              ]),
              builder: (BuildContext context, Widget? _) {
                final bool unfolded = controller?.expanded.value ?? false;
                return _PaletteButtonsLayout(
                  axis: axis,
                  step: _buttonStep,
                  unfolded: unfolded,
                  duration: AppMotion.resolve(context, unfoldDuration),
                  toolSlot: switch (tool.value) {
                    EditorTool.pen => 0,
                    EditorTool.eraser => 1,
                    EditorTool.select => 2,
                    EditorTool.sticky => stickySettings != null ? 3 : null,
                    EditorTool.ai => null,
                  },
                  capsuleSize: dense
                      ? AppSizes.paletteButtonVisualDense
                      : AppSizes.paletteButtonVisual,
                  primary: <Widget>[
                    _penControl(),
                    _eraserControl(),
                    _selectControl(),
                    if (stickySettings != null) _stickyControl(),
                    _imageControl(),
                    _aiControl(),
                  ],
                  secondary: <Widget>[
                    if (ruler != null) _rulerControl(),
                    if (recording != null) _recordingControl(),
                  ],
                  toggle: controller == null
                      ? null
                      : _extensionToggle(unfolded),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// Selects the pen; pressed again, opens its ink color and width.
  Widget _penControl() {
    return PalettePopover(
      paletteEdge: edge,
      controller: controller?.penMenu,
      onChanged: controller?.popoverChanged.notify,
      anchorBuilder: (BuildContext context, VoidCallback toggle) {
        final bool selected = tool.value == EditorTool.pen;
        final PenSettings pen = penSettings.value;
        return PaletteButton(
          tooltip: pen.style.label,
          hostsSelection: true,
          semanticLabel: PenOptions.describe(pen),
          selected: selected,
          dense: dense,
          onPressed: selected
              ? toggle
              : _choose(() => tool.value = EditorTool.pen),
          child: _PenIcon(
            ink: pen.activeInk,
            highlighter: pen.isHighlighter,
            opacity: penConfig.highlighterOpacity,
          ),
        );
      },
      panelBuilder: (BuildContext context, VoidCallback close) {
        return ValueListenableBuilder<PenSettings>(
          valueListenable: penSettings,
          builder: (BuildContext context, PenSettings current, Widget? _) {
            return PenOptions(
              settings: current,
              config: penConfig,
              onChanged: (PenSettings next) => penSettings.value = next,
              onOpenAdvanced: () {
                // The popover's context goes with it; the navigator stays.
                final NavigatorState navigator = Navigator.of(context);
                close();
                showPenAdvancedPanel(
                  navigator.context,
                  settings: penSettings,
                  config: penConfig,
                );
              },
            );
          },
        );
      },
    );
  }

  /// Selects the eraser; pressed again, opens its options.
  Widget _eraserControl() {
    return PalettePopover(
      paletteEdge: edge,
      controller: controller?.eraserMenu,
      onChanged: controller?.popoverChanged.notify,
      anchorBuilder: (BuildContext context, VoidCallback toggle) {
        final bool selected = tool.value == EditorTool.eraser;
        return PaletteButton(
          tooltip: 'Eraser',
          hostsSelection: true,
          semanticLabel:
              'Eraser, ${EraserOptions.describe(eraserSettings.value)}',
          selected: selected,
          dense: dense,
          onPressed: selected
              ? toggle
              : _choose(() => tool.value = EditorTool.eraser),
          child: const EraserIcon(),
        );
      },
      panelBuilder: (BuildContext context, VoidCallback close) {
        return ValueListenableBuilder<EraserSettings>(
          valueListenable: eraserSettings,
          builder: (BuildContext context, EraserSettings current, Widget? _) {
            return EraserOptions(
              settings: current,
              config: eraserConfig,
              onChanged: (EraserSettings next) => eraserSettings.value = next,
            );
          },
        );
      },
    );
  }

  /// Selects the Select tool; pressed again, opens its options.
  Widget _selectControl() {
    return PalettePopover(
      paletteEdge: edge,
      controller: controller?.selectMenu,
      onChanged: controller?.popoverChanged.notify,
      anchorBuilder: (BuildContext context, VoidCallback toggle) {
        final bool selected = tool.value == EditorTool.select;
        return PaletteButton(
          tooltip: 'Select',
          hostsSelection: true,
          selected: selected,
          dense: dense,
          onPressed: selected
              ? toggle
              : _choose(() => tool.value = EditorTool.select),
          child: const Icon(AppIcons.lasso),
        );
      },
      panelBuilder: (BuildContext context, VoidCallback close) {
        return ListenableBuilder(
          listenable: clipboardListenable,
          builder: (BuildContext context, Widget? _) {
            return SelectOptions(
              onPaste: canPaste()
                  ? () {
                      close();
                      onPaste();
                    }
                  : null,
            );
          },
        );
      },
    );
  }

  /// Selects the Sticky note tool and opens its options at once: a tap on
  /// the page then places a note with them. Pressed again, it toggles the
  /// options.
  Widget _stickyControl() {
    final ValueListenable<StickyNoteSettings> settings = stickySettings!;
    return PalettePopover(
      paletteEdge: edge,
      controller: controller?.stickyMenu,
      onChanged: controller?.popoverChanged.notify,
      anchorBuilder: (BuildContext context, VoidCallback toggle) {
        final bool selected = tool.value == EditorTool.sticky;
        return PaletteButton(
          key: const ValueKey<String>('sticky-note-tool'),
          tooltip: 'Sticky note',
          hostsSelection: true,
          semanticLabel:
              'Sticky note, ${StickyOptions.describe(settings.value)}',
          selected: selected,
          dense: dense,
          onPressed: selected
              ? toggle
              : _choose(() {
                  tool.value = EditorTool.sticky;
                  toggle();
                }),
          child: _StickyIcon(color: settings.value.color),
        );
      },
      panelBuilder: (BuildContext context, VoidCallback close) {
        return ValueListenableBuilder<StickyNoteSettings>(
          valueListenable: settings,
          builder: (BuildContext context, StickyNoteSettings current, _) {
            return StickyOptions(
              settings: current,
              targetLabel: stickyTargetLabel?.call(),
              onChanged: (StickyNoteSettings next) =>
                  onStickySettingsChanged?.call(next),
            );
          },
        );
      },
    );
  }

  /// Opens image insertion options: gallery or camera.
  Widget _imageControl() {
    final bool enabled =
        onChooseImageFromGallery != null ||
        onTakePhoto != null ||
        onChooseSvg != null;
    return PalettePopover(
      paletteEdge: edge,
      controller: controller?.imageMenu,
      onChanged: controller?.popoverChanged.notify,
      anchorBuilder: (BuildContext context, VoidCallback toggle) {
        return PaletteButton(
          key: const ValueKey<String>('insert-image-button'),
          tooltip: 'Insert image',
          semanticLabel: 'Insert image',
          dense: dense,
          onPressed: enabled ? toggle : null,
          child: const PictureIcon(),
        );
      },
      panelBuilder: (BuildContext context, VoidCallback close) {
        return ImageOptions(
          onChooseSvg: onChooseSvg == null
              ? null
              : () {
                  close();
                  onChooseSvg!();
                },
          onChooseFromGallery: onChooseImageFromGallery == null
              ? null
              : () {
                  close();
                  onChooseImageFromGallery!();
                },
          onTakePhoto: onTakePhoto == null
              ? null
              : () {
                  close();
                  onTakePhoto!();
                },
        );
      },
    );
  }

  /// Folds the secondary tools in and out. The arrow points the way the
  /// palette will grow, and back the other way once it has.
  Widget _extensionToggle(bool unfolded) {
    final bool across = axis == Axis.horizontal;
    final IconData icon = unfolded
        ? (across ? AppIcons.toolsCollapseAcross : AppIcons.toolsCollapseDown)
        : (across ? AppIcons.toolsExpandAcross : AppIcons.toolsExpandDown);
    return Builder(
      builder: (BuildContext context) {
        return PaletteButton(
          key: const ValueKey<String>('palette-extension-toggle'),
          tooltip: unfolded ? 'Collapse toolbar' : 'Expand toolbar',
          semanticLabel: unfolded ? 'Collapse toolbar' : 'Expand toolbar',
          dense: dense,
          onPressed: () {
            final bool next = !unfolded;
            controller!.expanded.value = next;
            if (!next) {
              controller!.recordingMenu.close();
            }
            SemanticsService.sendAnnouncement(
              View.of(context),
              next
                  ? 'Tools expanded, $_secondaryCount additional tools available'
                  : 'Tools collapsed',
              Directionality.of(context),
            );
          },
          child: Icon(icon),
        );
      },
    );
  }

  /// Opens the recording panel: record, and choose any recording to replay.
  Widget _recordingControl() {
    final RecordingToolData data = recording!;
    return PalettePopover(
      paletteEdge: edge,
      controller: controller?.recordingMenu,
      onChanged: controller?.popoverChanged.notify,
      anchorBuilder: (BuildContext context, VoidCallback toggle) {
        return PaletteButton(
          key: const ValueKey<String>('recording-tool'),
          tooltip: 'Recordings',
          semanticLabel: 'Recordings',
          selected: data.recorder.state != NoteAudioRecorderState.idle,
          dense: dense,
          onPressed: toggle,
          child: RecordingGlyph(recorder: data.recorder),
        );
      },
      panelBuilder: (BuildContext context, VoidCallback close) {
        return RecordingOptions(data: data, onChosen: close);
      },
    );
  }

  /// Shows and hides the ruler. It is no tool: the one in use stays chosen.
  Widget _rulerControl() {
    final RulerController guide = ruler!;
    return Builder(
      builder: (BuildContext context) {
        final bool on = guide.isVisible;
        return PaletteButton(
          key: const ValueKey<String>('ruler-toggle'),
          tooltip: on ? 'Hide ruler' : 'Show ruler',
          semanticLabel: 'Ruler',
          selected: on,
          toggled: on,
          dense: dense,
          onPressed: () {
            guide.toggle();
            SemanticsService.sendAnnouncement(
              View.of(context),
              guide.isVisible ? 'Ruler shown' : 'Ruler hidden',
              Directionality.of(context),
            );
          },
          child: const RulerIcon(),
        );
      },
    );
  }

  /// Turns AI mode on: it shows the assistant's notes and opens the chat.
  /// Pressed again, it opens the assistant's options. Closing the chat
  /// turns it off; other tools can stay on beside it.
  Widget _aiControl() {
    return PalettePopover(
      paletteEdge: edge,
      controller: controller?.aiMenu,
      onChanged: controller?.popoverChanged.notify,
      anchorBuilder: (BuildContext context, VoidCallback toggle) {
        final bool on = aiActive.value;
        return PaletteButton(
          key: const ValueKey<String>('ai-mode-toggle'),
          tooltip: on ? 'AI settings' : 'Turn on AI',
          semanticLabel: 'AI mode',
          selected: on,
          toggled: on,
          dense: dense,
          onPressed: !on
              ? onTurnOnAi
              : assistant == null
              ? null
              : toggle,
          child: const _AiGlyph(),
        );
      },
      panelBuilder: (BuildContext context, VoidCallback close) {
        return AiOptions(assistant: assistant!);
      },
    );
  }
}

/// The letters "AI", drawn in the icon's color and size.
class _AiGlyph extends StatelessWidget {
  const _AiGlyph();

  @override
  Widget build(BuildContext context) {
    final IconThemeData icon = IconTheme.of(context);
    return SizedBox.square(
      dimension: AppSizes.icon + 2,
      child: Center(
        child: Text(
          'AI',
          key: const ValueKey<String>('ai-mode-label'),
          maxLines: 1,
          textScaler: TextScaler.noScaling,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: icon.color,
            fontSize: (icon.size ?? AppSizes.icon) * 0.66,
            height: 1,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }
}

/// Lays out the palette buttons along [axis] spaced by [step] while
/// preserving each button's 48 px touch target. The [secondary] buttons
/// slide out beside the [primary] ones as [unfolded] turns true, the
/// [toggle] riding at the end of them.
class _PaletteButtonsLayout extends StatelessWidget {
  const _PaletteButtonsLayout({
    required this.axis,
    required this.step,
    required this.primary,
    required this.secondary,
    required this.unfolded,
    required this.duration,
    required this.toolSlot,
    required this.capsuleSize,
    this.toggle,
  });

  /// The slot of the chosen tool, which the selection capsule glides to; null
  /// when no button in the row is the chosen tool.
  final int? toolSlot;
  final double capsuleSize;

  final Axis axis;
  final double step;
  final List<Widget> primary;
  final List<Widget> secondary;
  final Widget? toggle;
  final bool unfolded;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: unfolded ? 1 : 0),
      duration: duration,
      curve: AppMotion.fadeInCurve,
      builder: (BuildContext context, double reveal, Widget? _) {
        // Slots along the palette: the primary tools, the secondary ones as
        // far as they are revealed, then the toggle.
        final double slots =
            primary.length +
            secondary.length * reveal +
            (toggle == null ? 0 : 1);
        final double along = (slots - 1) * step + AppSizes.minTouchTarget;
        final bool across = axis == Axis.horizontal;

        Widget place(double slot, Widget child) {
          return Positioned(
            left: across ? slot * step : 0,
            top: across ? 0 : slot * step,
            width: AppSizes.minTouchTarget,
            height: AppSizes.minTouchTarget,
            child: child,
          );
        }

        return SizedBox(
          width: across ? along : AppSizes.minTouchTarget,
          height: across ? AppSizes.minTouchTarget : along,
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              // One capsule behind the buttons, gliding to the chosen tool.
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: toolSlot == null ? 0 : 1,
                    duration: AppMotion.resolve(context, AppMotion.fadeIn),
                    curve: AppMotion.fadeInCurve,
                    child: SelectionCapsule(
                      index: toolSlot ?? 0,
                      count: primary.length,
                      axis: axis,
                      slotExtent: step,
                      size: capsuleSize,
                      origin: (AppSizes.minTouchTarget - capsuleSize) / 2,
                    ),
                  ),
                ),
              ),
              for (int i = 0; i < primary.length; i++)
                place(i.toDouble(), primary[i]),
              // Folded away, the secondary tools are neither seen nor
              // reachable, by touch or by screen reader.
              if (reveal > 0)
                for (int i = 0; i < secondary.length; i++)
                  place(
                    primary.length + i * reveal,
                    ExcludeSemantics(
                      excluding: !unfolded,
                      child: IgnorePointer(
                        ignoring: !unfolded,
                        child: Opacity(opacity: reveal, child: secondary[i]),
                      ),
                    ),
                  ),
              if (toggle != null)
                place(primary.length + secondary.length * reveal, toggle!),
            ],
          ),
        );
      },
    );
  }
}

/// The palette's card. Held anywhere, on [child]'s tools too, it lights up
/// in the accent color after a moment, so a quick tap never flashes it,
/// and after [ToolPalette.liftDelay] it lifts, scaled up a touch over a
/// deeper shadow, to be dragged.
class _LiftableSurface extends StatefulWidget {
  const _LiftableSurface({
    required this.semanticLabel,
    required this.moveActions,
    required this.onLift,
    required this.onMove,
    required this.onDrop,
    required this.child,
  });

  /// How long a press is held before the palette lights up.
  static const Duration highlightDelay = Duration(milliseconds: 100);

  final String semanticLabel;
  final Map<CustomSemanticsAction, VoidCallback> moveActions;
  final VoidCallback? onLift;
  final ValueChanged<Offset>? onMove;
  final VoidCallback? onDrop;
  final Widget child;

  @override
  State<_LiftableSurface> createState() => _LiftableSurfaceState();
}

class _LiftableSurfaceState extends State<_LiftableSurface> {
  bool _pressed = false;
  bool _lifted = false;
  Offset _moved = Offset.zero;
  Timer? _highlight;

  bool get _movable => widget.onLift != null;

  @override
  void dispose() {
    _highlight?.cancel();
    super.dispose();
  }

  void _onDown(LongPressDownDetails details) {
    _highlight?.cancel();
    _highlight = Timer(_LiftableSurface.highlightDelay, () {
      if (mounted) setState(() => _pressed = true);
    });
  }

  void _onCancel() {
    _highlight?.cancel();
    setState(() => _pressed = false);
  }

  void _onStart(LongPressStartDetails details) {
    _highlight?.cancel();
    AppHaptics.lift();
    _moved = Offset.zero;
    setState(() {
      _pressed = true;
      _lifted = true;
    });
    widget.onLift?.call();
  }

  void _onMove(LongPressMoveUpdateDetails details) {
    final Offset delta = details.offsetFromOrigin - _moved;
    _moved = details.offsetFromOrigin;
    if (delta != Offset.zero) {
      widget.onMove?.call(delta);
    }
  }

  void _onEnd(LongPressEndDetails details) {
    _highlight?.cancel();
    setState(() {
      _pressed = false;
      _lifted = false;
    });
    widget.onDrop?.call();
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final bool lit = _pressed || _lifted;
    const BorderRadius radius = AppBorderRadius.large;
    final Duration duration = AppMotion.resolve(
      context,
      AppMotion.snappy.duration,
    );
    // Around the whole card, so a hold on a tool lifts it too; a tap on a
    // tool still reaches the tool.
    return RawGestureDetector(
      key: const ValueKey<String>('palette-surface'),
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        if (_movable)
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(
                  duration: ToolPalette.liftDelay,
                  debugOwner: this,
                ),
                (LongPressGestureRecognizer recognizer) {
                  recognizer
                    ..onLongPressDown = _onDown
                    ..onLongPressCancel = _onCancel
                    ..onLongPressStart = _onStart
                    ..onLongPressMoveUpdate = _onMove
                    ..onLongPressEnd = _onEnd;
                },
              ),
      },
      child: AnimatedScale(
        scale: _lifted ? 1.06 : 1,
        duration: duration,
        curve: AppMotion.fadeInCurve,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: _lifted ? 1 : 0),
          duration: duration,
          curve: AppMotion.fadeInCurve,
          builder: (BuildContext context, double lift, Widget? child) {
            final Color glass = AppGlass.surface(colors);
            final Widget surface = ClipRRect(
              borderRadius: radius,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: lit
                      ? Color.alphaBlend(
                          colors.accent.withValues(alpha: 0.14),
                          glass,
                        )
                      : glass,
                  borderRadius: radius,
                  border: lit
                      ? Border.all(
                          color: colors.accent,
                          width: AppSizes.hairline,
                        )
                      : Border.fromBorderSide(AppGlass.border(colors)),
                ),
                child: child,
              ),
            );
            return DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                // The floating shadow, deepened as the palette lifts.
                boxShadow: <BoxShadow>[
                  for (final BoxShadow shadow in AppShadows.floating(colors))
                    shadow.copyWith(
                      color: shadow.color.withValues(
                        alpha: math.min(1, shadow.color.a * (1 + 1.4 * lift)),
                      ),
                      blurRadius: shadow.blurRadius * (1 + lift),
                      offset: shadow.offset * (1 + 1.2 * lift),
                    ),
                ],
              ),
              child: surface,
            );
          },
          child: Material(
            type: MaterialType.transparency,
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: Semantics(
                    label: widget.semanticLabel,
                    customSemanticsActions: widget.moveActions,
                    child: MouseRegion(
                      cursor: !_movable
                          ? MouseCursor.defer
                          : _lifted
                          ? SystemMouseCursors.grabbing
                          : SystemMouseCursors.grab,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
                widget.child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small square of the next sticky note's paper, ruled with lines.
class _StickyIcon extends StatelessWidget {
  const _StickyIcon({required this.color});

  final StickyPaperColor color;

  @override
  Widget build(BuildContext context) {
    final Color outline = IconTheme.of(context).color ?? color.pattern;
    return SizedBox.square(
      dimension: AppSizes.icon,
      child: DecoratedBox(
        key: const ValueKey<String>('sticky-tool-paper'),
        decoration: BoxDecoration(
          color: color.paper,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: outline, width: 1.2),
        ),
        child: CustomPaint(painter: _StickyLinesPainter(outline)),
      ),
    );
  }
}

/// Three rules across the sticky icon's paper.
class _StickyLinesPainter extends CustomPainter {
  const _StickyLinesPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint rule = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    final double inset = size.width * 0.25;
    for (int i = 1; i <= 3; i++) {
      final double y = size.height * i / 4;
      canvas.drawLine(Offset(inset, y), Offset(size.width - inset, y), rule);
    }
  }

  @override
  bool shouldRepaint(_StickyLinesPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// A pen glyph, styled to match the floating tool palette.
class PenIcon extends StatelessWidget {
  const PenIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final IconThemeData theme = IconTheme.of(context);
    return SizedBox.square(
      dimension: theme.size,
      child: CustomPaint(
        painter: _PenIconPainter(theme.color ?? const Color(0xFF000000)),
      ),
    );
  }
}

class _PenIconPainter extends CustomPainter {
  const _PenIconPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double unit = size.shortestSide / 24;
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 * unit
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    // The surface being written on, as under the eraser.
    canvas.drawLine(
      Offset(5 * unit, 20.5 * unit),
      Offset(20 * unit, 20.5 * unit),
      paint,
    );

    // A pen tilted like the eraser, its nib down at the line: one outline
    // from the rounded end of the barrel to the point, and a collar where
    // the nib begins.
    const double half = 3;
    canvas
      ..save()
      ..translate(11.5 * unit, 12 * unit)
      ..rotate(3 * math.pi / 4)
      ..drawPath(
        Path()
          ..moveTo(2.5 * unit, -half * unit)
          ..lineTo(-7 * unit, -half * unit)
          ..arcToPoint(
            Offset(-7 * unit, half * unit),
            radius: Radius.circular(half * unit),
            clockwise: false,
          )
          ..lineTo(2.5 * unit, half * unit)
          ..lineTo(8.5 * unit, 0)
          ..close(),
        paint,
      )
      ..drawLine(
        Offset(2.5 * unit, -half * unit),
        Offset(2.5 * unit, half * unit),
        paint,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_PenIconPainter oldDelegate) => oldDelegate.color != color;
}

/// A ruler glyph, styled to match the floating tool palette: a slanted bar
/// with ticks along one edge. The Cupertino icon set has none.
class RulerIcon extends StatelessWidget {
  const RulerIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final IconThemeData theme = IconTheme.of(context);
    return SizedBox.square(
      dimension: theme.size,
      child: CustomPaint(
        painter: _RulerIconPainter(theme.color ?? const Color(0xFF000000)),
      ),
    );
  }
}

class _RulerIconPainter extends CustomPainter {
  const _RulerIconPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double unit = size.shortestSide / 24;
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 * unit
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    canvas
      ..save()
      ..translate(12 * unit, 12 * unit)
      ..rotate(-math.pi / 4)
      ..drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset.zero,
            width: 21 * unit,
            height: 8 * unit,
          ),
          Radius.circular(2 * unit),
        ),
        paint,
      );
    // Ticks down from the top edge, every other one longer.
    for (int i = 0; i < 5; i++) {
      final double x = (-7.5 + i * 3.75) * unit;
      canvas.drawLine(
        Offset(x, -4 * unit),
        Offset(x, (i.isEven ? -0.5 : -2) * unit),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RulerIconPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// A picture glyph, styled to match the floating tool palette.
class PictureIcon extends StatelessWidget {
  const PictureIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final IconThemeData theme = IconTheme.of(context);
    return SizedBox.square(
      dimension: theme.size,
      child: CustomPaint(
        painter: _PictureIconPainter(theme.color ?? const Color(0xFF000000)),
      ),
    );
  }
}

class _PictureIconPainter extends CustomPainter {
  const _PictureIconPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double unit = size.shortestSide / 24;
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 * unit
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    final RRect frame = RRect.fromLTRBR(
      3 * unit,
      4.5 * unit,
      21 * unit,
      19.5 * unit,
      Radius.circular(3.5 * unit),
    );
    canvas.drawRRect(frame, paint);

    // A sun over a ridge of two hills that runs out under the frame.
    canvas
      ..save()
      ..clipRRect(frame)
      ..drawPath(
        Path()
          ..moveTo(2 * unit, 19 * unit)
          ..lineTo(8.5 * unit, 12.5 * unit)
          ..lineTo(12 * unit, 16 * unit)
          ..lineTo(14.5 * unit, 13.5 * unit)
          ..lineTo(22 * unit, 21 * unit),
        paint,
      )
      ..drawCircle(Offset(15.5 * unit, 8.75 * unit), 1.75 * unit, paint)
      ..restore();
  }

  @override
  bool shouldRepaint(_PictureIconPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// The writing tool's glyph with a sample of the current ink at its
/// corner: a dot for the pen, a translucent bar for the highlighter.
class _PenIcon extends StatelessWidget {
  const _PenIcon({
    required this.ink,
    required this.highlighter,
    required this.opacity,
  });

  static const double _dot = 9;

  final InkColor ink;
  final bool highlighter;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final Color color = ink.resolve(Theme.of(context).brightness);
    return SizedBox.square(
      dimension: AppSizes.icon + AppSpacing.xxs,
      child: Stack(
        children: <Widget>[
          Align(
            alignment: highlighter ? Alignment.topLeft : Alignment.center,
            child: highlighter
                ? const Icon(AppIcons.highlighter)
                : const PenIcon(),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              key: const ValueKey<String>('pen-ink-dot'),
              width: highlighter ? _dot * 1.6 : _dot,
              height: _dot,
              decoration: BoxDecoration(
                color: highlighter ? color.withValues(alpha: opacity) : color,
                shape: highlighter ? BoxShape.rectangle : BoxShape.circle,
                borderRadius: highlighter ? BorderRadius.circular(2) : null,
                border: Border.all(color: colors.surface, width: 1.2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The pen's options: its ink color and width, and a way into the advanced
/// settings, which open in their own panel.
class PenOptions extends StatelessWidget {
  const PenOptions({
    super.key,
    required this.settings,
    required this.onChanged,
    this.config = const PenConfig(),
    this.onOpenAdvanced,
  });

  final PenSettings settings;
  final ValueChanged<PenSettings> onChanged;
  final PenConfig config;

  /// Opens the advanced settings; with none there is no way in.
  final VoidCallback? onOpenAdvanced;

  /// The style, the ink, and the width, as screen readers announce them:
  /// "Highlighter, Yellow, 12 px".
  static String describe(PenSettings settings) {
    return '${settings.style.label}, ${settings.activeInk.label}, '
        '${StrokeWidthPicker.describe(settings.activeWidth)}';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SegmentedChoice<WritingStyle>(
          options: WritingStyle.values,
          selected: settings.style,
          labelOf: (WritingStyle style) => style.label,
          iconOnly: true,
          visualOf: (WritingStyle style, Color color) =>
              _WritingTipGlyph(style: style, color: color),
          keyOf: (WritingStyle style) =>
              ValueKey<String>('writing-style-${style.name}'),
          onSelected: (WritingStyle style) =>
              onChanged(settings.copyWith(style: style)),
        ),
        const SizedBox(height: AppSpacing.md),
        InkColorPicker(
          selected: settings.activeInk,
          colors: settings.isHighlighter
              ? InkPalette.highlighterColors
              : InkPalette.colors,
          onSelected: (InkColor ink) => onChanged(settings.withActiveInk(ink)),
        ),
        const SizedBox(height: AppSpacing.md),
        StrokeWidthPicker(
          settings: settings,
          config: config,
          onChanged: (double width) =>
              onChanged(settings.withActiveWidth(width)),
        ),
        // Taper, pressure, stabilization, and shapes belong to the pen.
        if (onOpenAdvanced != null && !settings.isHighlighter) ...<Widget>[
          const SizedBox(height: AppSpacing.xs),
          const Divider(height: 1),
          const SizedBox(height: AppSpacing.xxs),
          _AdvancedButton(onPressed: onOpenAdvanced!),
        ],
      ],
    );
  }
}

/// A close-up of the part that touches the page, so the writing styles can
/// be distinguished by their nib rather than by a label or generic tool icon.
class _WritingTipGlyph extends StatelessWidget {
  const _WritingTipGlyph({required this.style, required this.color});

  final WritingStyle style;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 24,
      child: CustomPaint(
        key: ValueKey<String>('writing-style-tip-${style.name}'),
        painter: _WritingTipPainter(style: style, color: color),
      ),
    );
  }
}

class _WritingTipPainter extends CustomPainter {
  const _WritingTipPainter({required this.style, required this.color});

  final WritingStyle style;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double unit = size.shortestSide / 24;
    canvas.scale(unit, unit);
    final Paint outline = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.35
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    switch (style) {
      case WritingStyle.pen:
        // Split fountain nib: narrow point with a breather hole and slit.
        canvas
          ..drawPath(
            Path()
              ..moveTo(7, 5)
              ..lineTo(17, 5)
              ..lineTo(15.5, 13)
              ..lineTo(12, 21)
              ..lineTo(8.5, 13)
              ..close(),
            outline,
          )
          ..drawLine(const Offset(7, 5), const Offset(17, 5), outline)
          ..drawCircle(const Offset(12, 11), 1.15, outline)
          ..drawLine(const Offset(12, 12.2), const Offset(12, 18.5), outline);
      case WritingStyle.pencil:
        // Sharpened wooden cone with a solid graphite core at its point.
        canvas
          ..drawRect(const Rect.fromLTRB(7.5, 3, 16.5, 11), outline)
          ..drawPath(
            Path()
              ..moveTo(7.5, 11)
              ..lineTo(16.5, 11)
              ..lineTo(12, 21)
              ..close(),
            outline,
          )
          ..drawPath(
            Path()
              ..moveTo(10.25, 17)
              ..lineTo(13.75, 17)
              ..lineTo(12, 21)
              ..close(),
            Paint()
              ..color = color
              ..style = PaintingStyle.fill
              ..isAntiAlias = true,
          );
      case WritingStyle.highlighter:
        // Wide felt nib ending in the highlighter's characteristic chisel.
        canvas
          ..drawRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTRB(6.5, 3, 17.5, 12),
              const Radius.circular(1.5),
            ),
            outline,
          )
          ..drawPath(
            Path()
              ..moveTo(7.5, 12)
              ..lineTo(16.5, 12)
              ..lineTo(15.25, 17.5)
              ..lineTo(7, 20)
              ..close(),
            outline,
          )
          ..drawLine(
            const Offset(7, 20),
            const Offset(15.25, 17.5),
            Paint()
              ..color = color
              ..strokeWidth = 2.6
              ..strokeCap = StrokeCap.square
              ..isAntiAlias = true,
          );
    }
  }

  @override
  bool shouldRepaint(_WritingTipPainter oldDelegate) {
    return oldDelegate.style != style || oldDelegate.color != color;
  }
}

/// Opens the advanced pen settings panel.
class _AdvancedButton extends StatelessWidget {
  const _AdvancedButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Semantics(
      button: true,
      label: 'Advanced pen settings',
      onTap: onPressed,
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey<String>('pen-advanced-toggle'),
        onTap: onPressed,
        borderRadius: AppBorderRadius.medium,
        child: SizedBox(
          height: AppSizes.minTouchTarget,
          child: Row(
            children: <Widget>[
              Icon(AppIcons.tune, size: 18, color: colors.textSecondary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Advanced',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              Icon(AppIcons.disclosure, size: 20, color: colors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}
