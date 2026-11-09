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
import 'recording_bars.dart';
import 'recording_options.dart';
import 'select_options.dart';
import 'sticky_options.dart';
import '../sticky/sticky_note.dart';
import '../text/note_text.dart';
import 'text_options_bar.dart';
import 'tool_options_bar.dart';
import 'toolbar_customizer.dart';
import 'toolbar_layout.dart';

class PopoverChanged extends ChangeNotifier {
  void notify() => notifyListeners();
}

class _ConstantTextSettings implements ValueListenable<TextSettings> {
  const _ConstantTextSettings();

  @override
  TextSettings get value => const TextSettings();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

/// Handles to the palette's popovers, for code outside the palette that
/// needs to know whether one is open.
class ToolPaletteController {
  final MenuController stickyMenu = MenuController();
  final MenuController imageMenu = MenuController();
  final MenuController recordingMenu = MenuController();

  /// Whether the palette is unfolded to show its secondary tools. The
  /// screen lays out around the palette's size,
  /// so it listens to this too.
  final ValueNotifier<bool> expanded = ValueNotifier<bool>(false);

  /// Notifies when a popover opens or closes.
  final PopoverChanged popoverChanged = PopoverChanged();

  bool get hasOpenPopover {
    return stickyMenu.isOpen || imageMenu.isOpen || recordingMenu.isOpen;
  }

  void closeAll() {
    stickyMenu.close();
    imageMenu.close();
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
  Offset originIn(
    Rect region,
    double margin, {
    bool expanded = false,
    ToolbarLayout tools = ToolbarLayout.standard,
  }) {
    final Size size = ToolPalette.sizeFor(
      edge.axis,
      expanded: expanded,
      tools: tools,
    );
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
    ToolbarLayout tools = ToolbarLayout.standard,
  }) {
    final PaletteEdge edge = nearestEdge(region, center);
    final Size size = ToolPalette.sizeFor(
      edge.axis,
      expanded: expanded,
      tools: tools,
    );
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

/// The floating tool palette: the pen, eraser, Select, AI mode, and image
/// insertion, and, folded away behind an arrow at its end, Sticky note,
/// recordings, Text, the ruler, and the button that arranges it. That is as
/// it comes: that button puts it in the order and with the buttons the user
/// wants, as [layout] holds.
///
/// The chosen tool's options lie in a bar beside the palette, parallel to
/// it and on the page side, and stay put as the palette folds and unfolds:
/// the pen's style, inks, and width, the
/// eraser's mode and size, Select's Select PDF switch, the assistant's
/// switches, and Text's formatting. Pressing the chosen tool again hides
/// the bar, or shows it, for every tool from then on. While a recording is
/// made or replayed the bar holds its controls instead: the time and pause
/// while it is made, and the playback bar once it is made. The Sticky note
/// and image options, and the list of recordings, open as panels instead.
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
    required this.selectPdf,
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
    this.ruler,
    this.recording,
    this.textSettings,
    this.onTextSettingsChanged,
    this.optionsShown,
    this.layout,
    this.growsBefore = 0.5,
    this.optionsMaxLength = double.infinity,
  });

  static const double _padding = AppSpacing.xxs;

  /// The gap between the palette and the options bar beside it.
  static const double optionsGap = AppSpacing.xxs;
  static const double _optionsGap = optionsGap;

  static const double _buttonStep = 44;

  /// How long the secondary tools take to fold in or out.
  static Duration get unfoldDuration => AppMotion.snappy.duration;

  /// How much of its growth as it unfolds goes toward the palette's start,
  /// from 0 (it grows only toward its end) to 1 (only toward its start). The
  /// options bar stays centered on where the folded palette lies, so unfolding
  /// moves only the palette.
  final double growsBefore;

  /// The longest the options bar may be before it scrolls.
  final double optionsMaxLength;

  /// The ruler the Ruler button shows and hides. Without it there is no
  /// Ruler button.
  final RulerController? ruler;

  /// The microphone and the note's recordings. Without it there is no Record
  /// button.
  final RecordingToolData? recording;

  /// Formatting defaults and active-text formatting. Without these there is
  /// no Text tool.
  final ValueListenable<TextSettings>? textSettings;
  final ValueChanged<TextSettings>? onTextSettingsChanged;

  ValueListenable<TextSettings> get _effectiveTextSettings =>
      textSettings ?? const _ConstantTextSettings();

  /// Whether the chosen tool's options bar shows beside the palette.
  /// Pressing the chosen tool again shows or hides it, and the choice holds
  /// for every tool chosen after. Without it the bar always shows.
  final ValueNotifier<bool>? optionsShown;

  /// Whether an options bar shows beside the palette now, with [tool]
  /// chosen. The Sticky note's options open as a panel instead.
  static bool showsOptions(EditorTool tool, ValueListenable<bool>? shown) =>
      tool != EditorTool.sticky && (shown?.value ?? true);

  /// Whether the options bar shows beside the palette now: with the tool's
  /// options, or, while a recording is made or replayed ([recordingShown]),
  /// with that recording's controls, whichever tool is chosen.
  static bool hasSubToolbar(
    EditorTool tool,
    ValueListenable<bool>? shown, {
    bool recordingShown = false,
  }) => recordingShown || showsOptions(tool, shown);

  /// Which buttons the palette shows, in what order, and which fold away
  /// behind its arrow; the user changes it with [PaletteItem.customize].
  /// Without it the palette is as [ToolbarLayout.standard] has it, and has
  /// no such button.
  final ValueNotifier<ToolbarLayout>? layout;

  ToolbarLayout get _tools => layout?.value ?? ToolbarLayout.standard;

  /// Callbacks for inserting images from gallery or camera.
  final VoidCallback? onChooseImageFromGallery;
  final VoidCallback? onTakePhoto;

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

  /// Whether a lasso takes the PDF paper inside it along with the ink: the
  /// Select tool's one option.
  final ValueNotifier<bool> selectPdf;

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

  /// How much longer the palette with [tools] is unfolded than folded.
  static double unfoldGrowth(
    Axis axis, {
    ToolbarLayout tools = ToolbarLayout.standard,
  }) =>
      sizeFor(axis, expanded: true, tools: tools).longestSide -
      sizeFor(axis, tools: tools).longestSide;

  /// The palette's outer size with [tools], folded or [expanded]; fixed so
  /// the screen can lay out around it.
  static Size sizeFor(
    Axis axis, {
    bool expanded = false,
    ToolbarLayout tools = ToolbarLayout.standard,
  }) {
    const double thickness = AppSizes.minTouchTarget + 2 * _padding;
    // The tools always shown, the arrow if anything is folded behind it, and
    // the folded tools beside them once unfolded.
    final bool folds = tools.folded.isNotEmpty;
    final int count =
        tools.shown.length +
        (folds ? 1 : 0) +
        (expanded && folds ? tools.folded.length : 0);
    final double length =
        (count - 1) * _buttonStep + AppSizes.minTouchTarget + 2 * _padding;
    return axis == Axis.vertical
        ? Size(thickness, length)
        : Size(length, thickness);
  }

  @override
  Widget build(BuildContext context) {
    final Widget palette = _LiftableSurface(
      // Keyed, so it keeps its place as the options come and go before it.
      key: const ValueKey<String>('tool-palette-card'),
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
                ?layout,
              ]),
              builder: (BuildContext context, Widget? _) {
                final ToolbarLayout tools = _tools;
                final List<PaletteItem> primary = <PaletteItem>[
                  ...tools.shown.where(_available),
                ];
                final List<PaletteItem> secondary = <PaletteItem>[
                  ...tools.folded.where(_available),
                ];
                final bool unfolded =
                    secondary.isNotEmpty &&
                    (controller?.expanded.value ?? false);
                // The capsule sits behind the chosen tool when it is one
                // always shown.
                final PaletteItem? chosen = switch (tool.value) {
                  EditorTool.pen => PaletteItem.pen,
                  EditorTool.eraser => PaletteItem.eraser,
                  EditorTool.select => PaletteItem.select,
                  EditorTool.sticky => PaletteItem.sticky,
                  EditorTool.text => PaletteItem.text,
                  EditorTool.ai => null,
                };
                final int slot = chosen == null ? -1 : primary.indexOf(chosen);
                return _PaletteButtonsLayout(
                  axis: axis,
                  step: _buttonStep,
                  unfolded: unfolded,
                  duration: AppMotion.resolve(context, unfoldDuration),
                  toolSlot: slot < 0 ? null : slot,
                  capsuleSize: dense
                      ? AppSizes.paletteButtonVisualDense
                      : AppSizes.paletteButtonVisual,
                  primary: <Widget>[
                    for (final PaletteItem item in primary)
                      KeyedSubtree(
                        key: ValueKey<PaletteItem>(item),
                        child: _control(item),
                      ),
                  ],
                  secondary: <Widget>[
                    for (final PaletteItem item in secondary)
                      KeyedSubtree(
                        key: ValueKey<PaletteItem>(item),
                        child: _control(item),
                      ),
                  ],
                  toggle: controller == null || secondary.isEmpty
                      ? null
                      : _extensionToggle(unfolded, secondary.length),
                );
              },
            ),
          ),
        ),
      ),
    );
    final ValueListenable<TextSettings> settings = _effectiveTextSettings;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        tool,
        settings,
        penSettings,
        eraserSettings,
        selectPdf,
        ?optionsShown,
        ?layout,
        ?recording?.recorder,
        ?recording?.replay.activity,
      ]),
      builder: (BuildContext context, Widget? _) {
        final Widget? bar = _subToolbar(context, settings.value);
        // Parallel to the palette and centered on where it lies folded, on
        // the side toward the page.
        final bool towardPage =
            edge == PaletteEdge.top || edge == PaletteEdge.left;
        final List<Widget> children = <Widget>[
          _paletteSlot(context, palette),
          if (bar != null) ...<Widget>[
            const SizedBox.square(dimension: _optionsGap),
            ConstrainedBox(
              constraints: axis == Axis.horizontal
                  ? BoxConstraints(maxWidth: optionsMaxLength)
                  : BoxConstraints(maxHeight: optionsMaxLength),
              child: bar,
            ),
          ],
        ];
        return Flex(
          direction: axis == Axis.horizontal ? Axis.vertical : Axis.horizontal,
          mainAxisSize: MainAxisSize.min,
          // Placed on screen, as the palette is, whatever the reading order.
          textDirection: TextDirection.ltr,
          children: towardPage ? children : children.reversed.toList(),
        );
      },
    );
  }

  /// What the sub toolbar holds now, if it shows: the recording's controls
  /// while one is made or replayed, otherwise the chosen tool's options.
  Widget? _subToolbar(BuildContext context, TextSettings text) {
    final RecordingToolData? data = recording;
    if (data != null && data.recorder.state != NoteAudioRecorderState.idle) {
      return RecordingBar(
        axis: axis,
        recorder: data.recorder,
        onPause: data.onPause,
        onResume: data.onResume,
        onStop: data.onStop,
      );
    }
    if (data != null && data.replay.isActive && data.player != null) {
      return ReplayBar(
        axis: axis,
        player: data.player!,
        replay: data.replay,
        onClose: data.onCloseReplay,
      );
    }
    return showsOptions(tool.value, optionsShown)
        ? _optionsBar(context, text)
        : null;
  }

  /// Whether this palette has what [item] needs.
  bool _available(PaletteItem item) => switch (item) {
    PaletteItem.sticky => stickySettings != null,
    PaletteItem.recording => recording != null,
    PaletteItem.ruler => ruler != null,
    PaletteItem.customize => layout != null,
    _ => true,
  };

  Widget _control(PaletteItem item) => switch (item) {
    PaletteItem.pen => _penControl(),
    PaletteItem.eraser => _eraserControl(),
    PaletteItem.select => _selectControl(),
    PaletteItem.ai => _aiControl(),
    PaletteItem.image => _imageControl(),
    PaletteItem.sticky => _stickyControl(),
    PaletteItem.recording => _recordingControl(),
    PaletteItem.text => _textControl(),
    PaletteItem.ruler => _rulerControl(),
    PaletteItem.customize => _customizeControl(),
  };

  /// Whether the capsule behind the always-shown tools draws [item]'s
  /// selected fill. Folded away, it draws its own.
  bool _hostsSelection(PaletteItem item) => _tools.shown.contains(item);

  /// Opens the toolbar's arrangement: the order of its buttons, which are
  /// always shown, which fold away behind the arrow, and which are hidden.
  Widget _customizeControl() {
    return Builder(
      builder: (BuildContext context) {
        return PaletteButton(
          key: const ValueKey<String>('customize-toolbar'),
          tooltip: 'Customize toolbar',
          semanticLabel: 'Customize toolbar',
          dense: dense,
          onPressed: () {
            controller?.closeAll();
            unawaited(showToolbarCustomizer(context, layout: layout!));
          },
          child: const AppIcon(AppIcons.customizeToolbar),
        );
      },
    );
  }

  /// Room for the palette unfolded, its middle where the folded palette's
  /// middle lies. Its size never follows the palette's, so what is centered
  /// beside it stays put as the palette unfolds.
  Widget _paletteSlot(BuildContext context, Widget palette) {
    final bool across = axis == Axis.horizontal;
    return TweenAnimationBuilder<double>(
      // Keyed, so it keeps its place as the options come and go before it.
      key: const ValueKey<String>('tool-palette-slot'),
      tween: Tween<double>(end: growsBefore),
      // As the palette's own docking moves, so a drop that changes this does
      // not jump it.
      duration: AppMotion.resolve(context, AppMotion.bouncy.duration),
      curve: AppMotion.fadeInCurve,
      child: palette,
      builder: (BuildContext context, double before, Widget? child) {
        final double growth = unfoldGrowth(axis, tools: _tools);
        final double lean = 2 * before - 1;
        final double start = math.max(0, -lean) * growth;
        final double end = math.max(0, lean) * growth;
        return Padding(
          padding: across
              ? EdgeInsets.only(left: start, right: end)
              : EdgeInsets.only(top: start, bottom: end),
          child: SizedBox.fromSize(
            size: sizeFor(axis, expanded: true, tools: _tools),
            child: Align(
              alignment: across ? Alignment(lean, 0) : Alignment(0, lean),
              child: child,
            ),
          ),
        );
      },
    );
  }

  /// The chosen tool's options, lying along [axis] as the palette does.
  Widget? _optionsBar(BuildContext context, TextSettings text) {
    return switch (tool.value) {
      EditorTool.pen => PenOptions(
        axis: axis,
        settings: penSettings.value,
        config: penConfig,
        onChanged: (PenSettings next) => penSettings.value = next,
        onOpenAdvanced: () => showPenAdvancedPanel(
          context,
          settings: penSettings,
          config: penConfig,
        ),
      ),
      EditorTool.eraser => EraserOptions(
        axis: axis,
        settings: eraserSettings.value,
        config: eraserConfig,
        onChanged: (EraserSettings next) => eraserSettings.value = next,
      ),
      EditorTool.select => SelectOptions(
        axis: axis,
        selectPdf: selectPdf.value,
        onSelectPdfChanged: (bool next) => selectPdf.value = next,
      ),
      EditorTool.text => TextOptionsBar(
        axis: axis,
        settings: text,
        onChanged: onTextSettingsChanged ?? (_) {},
      ),
      EditorTool.ai =>
        assistant == null ? null : AiOptions(axis: axis, assistant: assistant!),
      EditorTool.sticky => null,
    };
  }

  /// What a press on [mine] does: chooses it, or, once it is chosen, shows
  /// or hides the options bar from then on.
  VoidCallback _chooseOrToggle(BuildContext context, EditorTool mine) {
    final ValueNotifier<bool>? shown = optionsShown;
    if (tool.value != mine || shown == null) {
      return () => tool.value = mine;
    }
    return () {
      shown.value = !shown.value;
      SemanticsService.sendAnnouncement(
        View.of(context),
        shown.value ? 'Tool options shown' : 'Tool options hidden',
        Directionality.of(context),
      );
    };
  }

  /// Selects the pen; pressed again, shows or hides its options.
  Widget _penControl() {
    return Builder(
      builder: (BuildContext context) {
        final PenSettings pen = penSettings.value;
        return PaletteButton(
          tooltip: pen.style.label,
          hostsSelection: _hostsSelection(PaletteItem.pen),
          semanticLabel: PenOptions.describe(pen),
          selected: tool.value == EditorTool.pen,
          dense: dense,
          onPressed: _chooseOrToggle(context, EditorTool.pen),
          child: _PenIcon(
            ink: pen.activeInk,
            style: pen.style,
            opacity: penConfig.highlighterOpacity,
          ),
        );
      },
    );
  }

  /// Selects the eraser; pressed again, shows or hides its options.
  Widget _eraserControl() {
    return Builder(
      builder: (BuildContext context) {
        return PaletteButton(
          tooltip: 'Eraser',
          hostsSelection: _hostsSelection(PaletteItem.eraser),
          semanticLabel:
              'Eraser, ${EraserOptions.describe(eraserSettings.value)}',
          selected: tool.value == EditorTool.eraser,
          dense: dense,
          onPressed: _chooseOrToggle(context, EditorTool.eraser),
          child: const EraserIcon(),
        );
      },
    );
  }

  /// Selects the Select tool; pressed again, shows or hides its options.
  Widget _selectControl() {
    return Builder(
      builder: (BuildContext context) {
        return PaletteButton(
          tooltip: 'Select',
          hostsSelection: _hostsSelection(PaletteItem.select),
          selected: tool.value == EditorTool.select,
          dense: dense,
          onPressed: _chooseOrToggle(context, EditorTool.select),
          child: const AppIcon(AppIcons.lasso),
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
          hostsSelection: _hostsSelection(PaletteItem.sticky),
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
        onChooseImageFromGallery != null || onTakePhoto != null;
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
  Widget _extensionToggle(bool unfolded, int folded) {
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
              controller!.closeAll();
            }
            SemanticsService.sendAnnouncement(
              View.of(context),
              next
                  ? 'Tools expanded, $folded additional tools available'
                  : 'Tools collapsed',
              Directionality.of(context),
            );
          },
          child: AppIcon(icon),
        );
      },
    );
  }

  /// Opens the recording panel: record, and choose any recording to replay.
  /// While a recording is being made, pressing it again stops and saves it.
  Widget _recordingControl() {
    final RecordingToolData data = recording!;
    return PalettePopover(
      paletteEdge: edge,
      controller: controller?.recordingMenu,
      onChanged: controller?.popoverChanged.notify,
      anchorBuilder: (BuildContext context, VoidCallback toggle) {
        return ListenableBuilder(
          listenable: data.recorder,
          builder: (BuildContext context, Widget? _) {
            final NoteAudioRecorderState state = data.recorder.state;
            final bool idle = state == NoteAudioRecorderState.idle;
            return PaletteButton(
              key: const ValueKey<String>('recording-tool'),
              tooltip: idle ? 'Recordings' : 'Stop recording',
              semanticLabel: idle ? 'Recordings' : 'Stop recording',
              selected: !idle,
              dense: dense,
              // Already stopping, there is nothing more to ask of it.
              onPressed: idle
                  ? toggle
                  : state == NoteAudioRecorderState.stopping
                  ? null
                  : data.onStop,
              child: RecordingGlyph(recorder: data.recorder),
            );
          },
        );
      },
      panelBuilder: (BuildContext context, VoidCallback close) {
        return RecordingOptions(data: data, onChosen: close);
      },
    );
  }

  /// Selects typed text placement; pressed again, shows or hides its
  /// formatting.
  Widget _textControl() {
    return Builder(
      builder: (BuildContext context) {
        return PaletteButton(
          key: const ValueKey<String>('text-tool'),
          tooltip: 'Text',
          semanticLabel: 'Text',
          selected: tool.value == EditorTool.text,
          dense: dense,
          onPressed: _chooseOrToggle(context, EditorTool.text),
          child: const _TextGlyph(),
        );
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
  /// Pressed while on, it takes up the AI tool, whose options show beside
  /// the palette; pressed again, it shows or hides them. Closing the chat
  /// turns it off; other tools can stay on beside it.
  Widget _aiControl() {
    return Builder(
      builder: (BuildContext context) {
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
              : _chooseOrToggle(context, EditorTool.ai),
          child: const _AiGlyph(),
        );
      },
    );
  }
}

/// What stands for [item] where the toolbar is arranged: the glyph its
/// button shows, at rest.
class PaletteItemGlyph extends StatelessWidget {
  const PaletteItemGlyph(this.item, {super.key});

  final PaletteItem item;

  @override
  Widget build(BuildContext context) => switch (item) {
    PaletteItem.pen => const PenIcon(),
    PaletteItem.eraser => const EraserIcon(),
    PaletteItem.select => const AppIcon(AppIcons.lasso),
    PaletteItem.ai => const _AiGlyph(),
    PaletteItem.image => const PictureIcon(),
    PaletteItem.sticky => _StickyIcon(color: const StickyNoteSettings().color),
    PaletteItem.recording => const AppIcon(AppIcons.microphone),
    PaletteItem.text => const _TextGlyph(),
    PaletteItem.ruler => const RulerIcon(),
    PaletteItem.customize => const AppIcon(AppIcons.customizeToolbar),
  };
}

/// The letters "AI" drawn as line icons, the same weight and color as the
/// glyphs beside them, with a green leaf sprouting from the top of the I
/// like the one at the tail of the pencil in the Etonia mark.
class _AiGlyph extends StatelessWidget {
  const _AiGlyph();

  @override
  Widget build(BuildContext context) {
    final Color ink = iconTint(context);
    // The leaf dims with the letters when the button is disabled.
    final Color leaf = AppColors.of(context).sprout.withValues(alpha: ink.a);
    return SizedBox.square(
      dimension: kIconSize,
      child: CustomPaint(
        key: const ValueKey<String>('ai-mode-label'),
        painter: _AiGlyphPainter(ink: ink, leaf: leaf),
      ),
    );
  }
}

class _AiGlyphPainter extends CustomPainter {
  const _AiGlyphPainter({required this.ink, required this.leaf});

  final Color ink;
  final Color leaf;

  @override
  void paint(Canvas canvas, Size size) {
    final double unit = size.shortestSide / 24;
    Offset at(double x, double y) => Offset(x * unit, y * unit);
    final Paint line = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = kIconStrokeWidth
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    // The A: two straight legs meeting at a point, and a crossbar.
    canvas
      ..drawPath(
        Path()
          ..moveTo(3.5 * unit, 19 * unit)
          ..lineTo(8.5 * unit, 7 * unit)
          ..lineTo(13.5 * unit, 19 * unit),
        line,
      )
      ..drawLine(at(5.4, 14.5), at(11.6, 14.5), line)
      // The I: one straight stroke, as tall as the A.
      ..drawLine(at(18.5, 7), at(18.5, 19), line);

    // One leaf sprouting from the top of the I, as on the mark's pencil: a
    // filled, pointed leaf rising up and to the right from the stem.
    canvas.drawPath(
      Path()
        ..moveTo(18.5 * unit, 6.3 * unit)
        ..quadraticBezierTo(21.6 * unit, 5.4 * unit, 22 * unit, 1.8 * unit)
        ..quadraticBezierTo(18.6 * unit, 2.4 * unit, 18.5 * unit, 6.3 * unit)
        ..close(),
      Paint()
        ..color = leaf
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_AiGlyphPainter oldDelegate) =>
      oldDelegate.ink != ink || oldDelegate.leaf != leaf;
}

/// A typesetting-style T with a baseline, distinct from the pen nib.
class _TextGlyph extends StatelessWidget {
  const _TextGlyph();

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: kIconSize,
      child: CustomPaint(painter: _TextGlyphPainter(iconTint(context))),
    );
  }
}

class _TextGlyphPainter extends CustomPainter {
  const _TextGlyphPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double unit = size.shortestSide / 24;
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = kIconStrokeWidth
      ..strokeCap = StrokeCap.round;
    canvas
      ..drawLine(Offset(4 * unit, 5 * unit), Offset(20 * unit, 5 * unit), paint)
      ..drawLine(
        Offset(12 * unit, 5 * unit),
        Offset(12 * unit, 19 * unit),
        paint,
      )
      ..drawLine(
        Offset(8 * unit, 19 * unit),
        Offset(16 * unit, 19 * unit),
        paint,
      );
  }

  @override
  bool shouldRepaint(_TextGlyphPainter oldDelegate) =>
      oldDelegate.color != color;
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

  /// The slot of the chosen tool, where the selection capsule shows; null
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
              // A capsule behind the chosen tool. Keyed by its slot, so the
              // chosen tool's capsule fades in where it is, without sliding
              // over from the last one, and the last one's fades out as its
              // glyph turns back: a light glyph is never left on bare card.
              Positioned.fill(
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: AnimatedSwitcher(
                      duration: AppMotion.resolve(context, AppMotion.fadeIn),
                      switchInCurve: AppMotion.fadeInCurve,
                      switchOutCurve: AppMotion.fadeInCurve,
                      layoutBuilder: (Widget? current, List<Widget> previous) =>
                          Stack(
                            fit: StackFit.expand,
                            children: <Widget>[...previous, ?current],
                          ),
                      child: toolSlot == null
                          ? const SizedBox.shrink()
                          : SelectionCapsule(
                              key: ValueKey<int>(toolSlot!),
                              index: toolSlot!,
                              count: primary.length,
                              axis: axis,
                              slotExtent: step,
                              size: capsuleSize,
                              origin:
                                  (AppSizes.minTouchTarget - capsuleSize) / 2,
                            ),
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
    super.key,
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
    final Color outline = iconTint(context);
    return SizedBox.square(
      dimension: kIconSize - 4,
      child: DecoratedBox(
        key: const ValueKey<String>('sticky-tool-paper'),
        decoration: BoxDecoration(
          color: color.paper,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: outline, width: kIconStrokeWidth),
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
      ..strokeWidth = kIconStrokeWidth
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
    return SizedBox.square(
      dimension: kIconSize,
      child: CustomPaint(painter: _PenIconPainter(iconTint(context))),
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
      ..strokeWidth = kIconStrokeWidth
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
    return SizedBox.square(
      dimension: kIconSize,
      child: CustomPaint(painter: _RulerIconPainter(iconTint(context))),
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
      ..strokeWidth = kIconStrokeWidth
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
    return SizedBox.square(
      dimension: kIconSize,
      child: CustomPaint(painter: _PictureIconPainter(iconTint(context))),
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
      ..strokeWidth = kIconStrokeWidth
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
/// corner: a dot for the pen and pencil, a translucent bar for the
/// highlighter. The pencil and highlighter are drawn as in the style picker,
/// so what is chosen there is what the toolbar shows.
class _PenIcon extends StatelessWidget {
  const _PenIcon({
    required this.ink,
    required this.style,
    required this.opacity,
  });

  static const double _dot = 9;

  final InkColor ink;
  final WritingStyle style;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final Color color = ink.resolve(Theme.of(context).brightness);
    final bool highlighter = style == WritingStyle.highlighter;
    return SizedBox.square(
      dimension: kIconSize + AppSpacing.xxs,
      child: Stack(
        children: <Widget>[
          Align(
            child: style == WritingStyle.pen
                ? const PenIcon()
                : _WritingToolGlyph(style: style),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              key: const ValueKey<String>('pen-ink-dot'),
              width: highlighter ? _dot * 1.3 : _dot,
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

/// The pen's options, along a [ToolOptionsBar]: the writing style, the
/// three inks at hand, the width, and a way into the advanced settings,
/// which open in their own panel.
class PenOptions extends StatelessWidget {
  const PenOptions({
    super.key,
    required this.settings,
    required this.onChanged,
    this.config = const PenConfig(),
    this.onOpenAdvanced,
    this.axis = Axis.horizontal,
  });

  final PenSettings settings;
  final ValueChanged<PenSettings> onChanged;
  final PenConfig config;

  /// Opens the advanced settings; with none there is no way in.
  final VoidCallback? onOpenAdvanced;
  final Axis axis;

  static String describeWidth(double width) => '${width.round()} px';

  /// The style, the ink, and the width, as screen readers announce them:
  /// "Highlighter, Yellow, 12 px".
  static String describe(PenSettings settings) {
    return '${settings.style.label}, ${settings.activeInk.label}, '
        '${describeWidth(settings.activeWidth)}';
  }

  @override
  Widget build(BuildContext context) {
    final double min = config.minWidthFor(settings.style);
    final double max = config.maxWidthFor(settings.style);
    return ToolOptionsBar(
      key: const ValueKey<String>('pen-options-bar'),
      axis: axis,
      children: <Widget>[
        for (final WritingStyle style in WritingStyle.values)
          OptionsButton(
            key: ValueKey<String>('writing-style-${style.name}'),
            // Not the bare style, which is the palette's pen button.
            tooltip: '${style.label} style',
            selected: settings.style == style,
            onPressed: () => onChanged(settings.copyWith(style: style)),
            child: _WritingToolGlyph(style: style),
          ),
        OptionsDivider(axis: axis),
        InkSwatches(
          axis: axis,
          swatches: settings.activeSwatches,
          selected: settings.activeInk,
          onSelected: (int index) =>
              onChanged(settings.withActiveInk(settings.activeSwatches[index])),
          onReplaced: (int index, InkColor ink) =>
              onChanged(settings.withActiveSwatch(index, ink)),
        ),
        OptionsDivider(axis: axis),
        OptionsSlider(
          key: const ValueKey<String>('pen-width-slider'),
          axis: axis,
          value: settings.activeWidth,
          min: min,
          max: max,
          divisions: (max - min).round(),
          semanticFormatterCallback: describeWidth,
          start: const OptionsDot(diameter: 4),
          end: const OptionsDot(diameter: 12),
          onChanged: (double width) =>
              onChanged(settings.withActiveWidth(width)),
        ),
        // Taper, pressure, stabilization, and shapes belong to the pen.
        if (onOpenAdvanced != null && !settings.isHighlighter) ...<Widget>[
          OptionsDivider(axis: axis),
          OptionsButton(
            key: const ValueKey<String>('pen-advanced-toggle'),
            tooltip: 'Advanced pen settings',
            onPressed: onOpenAdvanced,
            child: const AppIcon(AppIcons.tune),
          ),
        ],
      ],
    );
  }
}

/// [_WritingTipPainter] at the toolbar's icon size, in the icon's color.
class _WritingToolGlyph extends StatelessWidget {
  const _WritingToolGlyph({required this.style});

  final WritingStyle style;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: kIconSize,
      child: CustomPaint(
        painter: _WritingTipPainter(style: style, color: iconTint(context)),
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
      ..strokeWidth = kIconStrokeWidth / unit
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
        // A marker: barrel with a grip band, a tapering shoulder, and a
        // solid chisel tip cut at a slant.
        canvas
          ..drawRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTRB(7, 3, 17, 12),
              const Radius.circular(1.5),
            ),
            outline,
          )
          ..drawLine(const Offset(7, 7.5), const Offset(17, 7.5), outline)
          ..drawPath(
            Path()
              ..moveTo(8.75, 12)
              ..lineTo(15.25, 12)
              ..lineTo(13.75, 17)
              ..lineTo(10.25, 17)
              ..close(),
            outline,
          )
          ..drawPath(
            Path()
              ..moveTo(10.25, 17)
              ..lineTo(13.75, 17)
              ..lineTo(13.75, 19)
              ..lineTo(10.25, 21)
              ..close(),
            Paint()
              ..color = color
              ..style = PaintingStyle.fill
              ..isAntiAlias = true,
          );
    }
  }

  @override
  bool shouldRepaint(_WritingTipPainter oldDelegate) {
    return oldDelegate.style != style || oldDelegate.color != color;
  }
}
