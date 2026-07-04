import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdf_document/pdf_document.dart';

import 'editing_controller.dart';

/// A reusable rubber stamp the user authored: a caption and a color.
///
/// Custom stamps are saved on the local device through
/// [PdfEditingPreferences.customStamps], so they survive app restarts and
/// are shared across documents. The stamp tool places the
/// [PdfEditingController.activeStamp] with a tap; with none active it
/// falls back to the classic flow (drag a box, type the caption).
///
/// Serializes to JSON so [PdfEditingPreferences] can persist it.
class PdfCustomStamp {
  const PdfCustomStamp({
    required this.text,
    required this.color,
    this.template,
  });

  /// The caption drawn inside the stamp's rounded border.
  final String text;

  /// RGB border and caption color.
  final int color;

  /// Editable vector template for newer stamps. Null means this is a legacy
  /// text-only stamp and should be rendered with the classic appearance.
  final PdfStampTemplate? template;

  String encode() => jsonEncode({
        'text': text,
        'color': color,
        if (template != null) 'template': template!.toJson(),
      });

  /// Parses [encode]'s output; null for anything malformed.
  static PdfCustomStamp? decode(String json) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return PdfCustomStamp(
        text: map['text'] as String,
        color: map['color'] as int,
        template: PdfStampTemplate.fromJson(map['template']),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PdfCustomStamp &&
      other.text == text &&
      other.color == color &&
      other.template == template;

  @override
  int get hashCode => Object.hash(text, color, template);
}

/// Shows the stamp picker: choose the stamp the stamp tool places,
/// create a new one, or delete saved ones. Selections apply directly to
/// [controller].
Future<void> showPdfStampPicker(BuildContext context,
        {required PdfEditingController controller}) =>
    showDialog<void>(
      context: context,
      builder: (context) => PdfStampPickerDialog(controller: controller),
    );

/// The stamp picker dialog behind [showPdfStampPicker].
class PdfStampPickerDialog extends StatelessWidget {
  const PdfStampPickerDialog({super.key, required this.controller});

  final PdfEditingController controller;

  Future<void> _create(BuildContext context) async {
    final created = await showPdfStampEditor(context,
        fields: controller.stampTemplateFieldNames);
    if (created == null) return;
    controller.saveCustomStamp(created);
    controller.activeStamp = created;
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Stamps'),
      content: SizedBox(
        width: 340,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final stamp in controller.customStamps)
                  ListTile(
                    title: Align(
                      alignment: Alignment.centerLeft,
                      child: PdfStampPreview(
                          stamp: stamp,
                          templateValues:
                              controller.resolvedStampTemplateValues),
                    ),
                    selected: stamp == controller.activeStamp,
                    onTap: () {
                      controller.activeStamp = stamp;
                      Navigator.of(context).pop();
                    },
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Delete stamp',
                      onPressed: () => controller.removeCustomStamp(stamp),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _create(context),
          child: const Text('New stamp…'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// Shows the stamp creation dialog; resolves to the new stamp, or null
/// on cancel. Saving it is the caller's job (the picker saves through
/// the controller).
Future<PdfCustomStamp?> showPdfStampEditor(BuildContext context,
        {Iterable<String> fields =
            PdfEditingController.stampTemplateBuiltinFields}) =>
    showDialog<PdfCustomStamp>(
      context: context,
      builder: (context) => PdfStampEditorDialog(fields: fields),
    );

/// The stamp creation dialog behind [showPdfStampEditor]: caption field,
/// color choice, and a live preview matching the placed appearance.
class PdfStampEditorDialog extends StatefulWidget {
  const PdfStampEditorDialog({super.key, this.fields = const []});

  final Iterable<String> fields;

  @override
  State<PdfStampEditorDialog> createState() => _PdfStampEditorDialogState();
}

class _PdfStampEditorDialogState extends State<PdfStampEditorDialog> {
  static const _inks = [0xC03030, 0x2E7D32, 0x1A3E8C, 0xEF6C00, 0x000000];
  static const _templateWidth = 240.0;
  static const _templateHeight = 96.0;

  final _text = TextEditingController(text: 'APPROVED');
  late List<PdfStampTemplateComponent> _components;
  late final List<String> _fields;
  int? _selected = 1;
  int _color = _inks.first;

  @override
  void initState() {
    super.initState();
    _fields = _normalizeFields(widget.fields);
    _components = List.of(PdfStampTemplate.text(_text.text, _color).components);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  PdfStampTemplateComponent? get _selectedComponent =>
      _selected == null ? null : _components[_selected!];

  String get _caption {
    for (final component in _components) {
      if (component.type == PdfStampTemplateComponentType.text &&
          component.text.trim().isNotEmpty) {
        return component.text.trim();
      }
    }
    return 'Custom stamp';
  }

  int get _primaryColor =>
      _components.isEmpty ? _color : _components.first.color;

  PdfStampTemplate get _template => PdfStampTemplate(
        width: _templateWidth,
        height: _templateHeight,
        components: List.unmodifiable(_components),
      );

  void _syncTextField(PdfStampTemplateComponent component) {
    if (component.type != PdfStampTemplateComponentType.text) return;
    _text.value = TextEditingValue(
      text: component.text,
      selection: TextSelection.collapsed(offset: component.text.length),
    );
  }

  void _select(int? index) {
    setState(() {
      _selected = index;
      final component = _selectedComponent;
      if (component != null) _syncTextField(component);
    });
  }

  void _replaceSelected(PdfStampTemplateComponent component) {
    final index = _selected;
    if (index == null) return;
    setState(() => _components[index] = component);
  }

  void _insertField(String field) {
    final selected = _selectedComponent;
    if (selected?.type != PdfStampTemplateComponentType.text) return;
    final token = '{{$field}}';
    final value = _text.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final start = selection.start.clamp(0, value.text.length).toInt();
    final end = selection.end.clamp(0, value.text.length).toInt();
    final nextText = value.text.replaceRange(start, end, token);
    final offset = start + token.length;
    _text.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: offset),
    );
    _replaceSelected(selected!.copyWith(text: nextText));
  }

  void _moveSelected(Offset delta) {
    final component = _selectedComponent;
    if (component == null) return;
    final x = (component.x + delta.dx)
        .clamp(0.0, _templateWidth - component.width)
        .toDouble();
    final y = (component.y + delta.dy)
        .clamp(0.0, _templateHeight - component.height)
        .toDouble();
    _replaceSelected(component.copyWith(x: x, y: y));
  }

  void _resizeSelected(Offset delta) {
    final component = _selectedComponent;
    if (component == null) return;
    final minWidth =
        component.type == PdfStampTemplateComponentType.text ? 28.0 : 16.0;
    final minHeight =
        component.type == PdfStampTemplateComponentType.text ? 14.0 : 16.0;
    final width = (component.width + delta.dx)
        .clamp(minWidth, _templateWidth - component.x)
        .toDouble();
    final height = (component.height + delta.dy)
        .clamp(minHeight, _templateHeight - component.y)
        .toDouble();
    _replaceSelected(component.copyWith(width: width, height: height));
  }

  void _setSelectedColor(int color) {
    setState(() {
      _color = color;
      final index = _selected;
      if (index != null) {
        _components[index] = _components[index].copyWith(color: color);
      }
    });
  }

  void _addText() {
    const text = 'TEXT';
    final component = PdfStampTemplateComponent.text(
      x: 54,
      y: 36,
      width: 132,
      height: 28,
      text: text,
      color: _color,
      fontSize: 22,
    );
    setState(() {
      _components = [..._components, component];
      _selected = _components.length - 1;
      _syncTextField(component);
    });
  }

  void _addBox() {
    final component = PdfStampTemplateComponent.rectangle(
      x: 28,
      y: 22,
      width: 184,
      height: 52,
      color: _color,
      strokeWidth: 2,
      radius: 8,
    );
    setState(() {
      _components = [..._components, component];
      _selected = _components.length - 1;
    });
  }

  void _deleteSelected() {
    final index = _selected;
    if (index == null || _components.length <= 1) return;
    setState(() {
      _components = [
        for (var i = 0; i < _components.length; i++)
          if (i != index) _components[i],
      ];
      _selected = math.min(index, _components.length - 1);
      final component = _selectedComponent;
      if (component != null) _syncTextField(component);
    });
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedComponent;
    final selectedIsText = selected?.type == PdfStampTemplateComponentType.text;
    return AlertDialog(
      title: const Text('New stamp'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 340,
            child: _StampTemplateCanvas(
              key: const ValueKey('pdf-stamp-template-canvas'),
              templateSize: const Size(_templateWidth, _templateHeight),
              components: _components,
              selectedIndex: _selected,
              onSelect: _select,
              onMoveSelected: _moveSelected,
              onResizeSelected: _resizeSelected,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 300,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('pdf-stamp-text'),
                    controller: _text,
                    autofocus: true,
                    enabled: selectedIsText,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      labelText: selectedIsText
                          ? 'Selected text'
                          : 'Select text to edit',
                    ),
                    onChanged: selectedIsText
                        ? (value) =>
                            _replaceSelected(selected!.copyWith(text: value))
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<String>(
                  key: const ValueKey('pdf-stamp-field-menu'),
                  tooltip: 'Insert field',
                  enabled: selectedIsText && _fields.isNotEmpty,
                  icon: const Icon(Icons.data_object),
                  onSelected: _insertField,
                  itemBuilder: (context) => [
                    for (final field in _fields)
                      PopupMenuItem<String>(
                        key: ValueKey('pdf-stamp-field-$field'),
                        value: field,
                        child: Text(_fieldLabel(field)),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            for (final ink in _inks)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InkWell(
                  onTap: () => _setSelectedColor(ink),
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Color(0xFF000000 | ink),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _color == ink
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outline,
                        width: _color == ink ? 3 : 1,
                      ),
                    ),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('pdf-stamp-add-text'),
                onPressed: _addText,
                icon: const Icon(Icons.title),
                label: const Text('Text'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('pdf-stamp-add-box'),
                onPressed: _addBox,
                icon: const Icon(Icons.crop_square),
                label: const Text('Box'),
              ),
              IconButton(
                key: const ValueKey('pdf-stamp-delete-component'),
                onPressed: _components.length > 1 ? _deleteSelected : null,
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete selected component',
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _components.isEmpty
              ? null
              : () => Navigator.of(context).pop(PdfCustomStamp(
                    text: _caption,
                    color: _primaryColor,
                    template: _template,
                  )),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Renders a stamp the way it will look on the page: bold caption inside
/// a rounded border, both in the stamp's color.
class PdfStampPreview extends StatelessWidget {
  const PdfStampPreview({
    super.key,
    required this.stamp,
    this.templateValues = const {},
  });

  final PdfCustomStamp stamp;
  final Map<String, String> templateValues;

  @override
  Widget build(BuildContext context) {
    final template = (stamp.template ??
            PdfStampTemplate.text(
                pdfResolveStampTemplateText(stamp.text, templateValues),
                stamp.color))
        .resolveText(templateValues);
    final width = math.min(220.0, math.max(80.0, template.width));
    return SizedBox(
      width: width,
      height: width * template.height / template.width,
      child: CustomPaint(
        painter: _StampTemplatePainter(
          templateSize: Size(template.width, template.height),
          components: template.components,
          selectedIndex: null,
          scheme: Theme.of(context).colorScheme,
          showChrome: false,
        ),
      ),
    );
  }
}

class _StampTemplateCanvas extends StatefulWidget {
  const _StampTemplateCanvas({
    super.key,
    required this.templateSize,
    required this.components,
    required this.selectedIndex,
    required this.onSelect,
    required this.onMoveSelected,
    required this.onResizeSelected,
  });

  final Size templateSize;
  final List<PdfStampTemplateComponent> components;
  final int? selectedIndex;
  final ValueChanged<int?> onSelect;
  final ValueChanged<Offset> onMoveSelected;
  final ValueChanged<Offset> onResizeSelected;

  @override
  State<_StampTemplateCanvas> createState() => _StampTemplateCanvasState();
}

enum _StampDragMode { move, resize }

class _StampTemplateCanvasState extends State<_StampTemplateCanvas> {
  _StampDragMode? _dragMode;
  Offset? _lastTemplatePoint;

  double _scale(Size size) => size.width / widget.templateSize.width;

  Offset _toTemplate(Offset local, Size size) {
    final scale = _scale(size);
    return Offset(local.dx / scale, local.dy / scale);
  }

  Rect _componentRect(PdfStampTemplateComponent c) =>
      Rect.fromLTWH(c.x, c.y, c.width, c.height);

  Rect _handleRect(PdfStampTemplateComponent c, double scale) {
    final size = 12 / scale;
    return Rect.fromCenter(
      center: _componentRect(c).bottomRight,
      width: size,
      height: size,
    );
  }

  int? _hitComponent(Offset templatePoint) {
    for (var i = widget.components.length - 1; i >= 0; i--) {
      if (_componentRect(widget.components[i])
          .inflate(4)
          .contains(templatePoint)) {
        return i;
      }
    }
    return null;
  }

  void _start(Offset localPosition, Size size) {
    final point = _toTemplate(localPosition, size);
    _lastTemplatePoint = point;
    final selected = widget.selectedIndex;
    if (selected != null) {
      final selectedComponent = widget.components[selected];
      if (_handleRect(selectedComponent, _scale(size)).contains(point)) {
        _dragMode = _StampDragMode.resize;
        return;
      }
    }
    final hit = _hitComponent(point);
    widget.onSelect(hit);
    _dragMode = hit == null ? null : _StampDragMode.move;
  }

  void _update(Offset localPosition, Size size) {
    final point = _toTemplate(localPosition, size);
    final last = _lastTemplatePoint;
    _lastTemplatePoint = point;
    if (last == null) return;
    final delta = point - last;
    switch (_dragMode) {
      case _StampDragMode.move:
        widget.onMoveSelected(delta);
      case _StampDragMode.resize:
        widget.onResizeSelected(delta);
      case null:
        break;
    }
  }

  void _end() {
    _dragMode = null;
    _lastTemplatePoint = null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const width = 340.0;
    final size = Size(
        width, width * widget.templateSize.height / widget.templateSize.width);
    return SizedBox(
      width: size.width,
      height: size.height,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) => _start(event.localPosition, size),
        onPointerMove: (event) => _update(event.localPosition, size),
        onPointerUp: (_) => _end(),
        onPointerCancel: (_) => _end(),
        child: CustomPaint(
          painter: _StampTemplatePainter(
            templateSize: widget.templateSize,
            components: widget.components,
            selectedIndex: widget.selectedIndex,
            scheme: scheme,
          ),
        ),
      ),
    );
  }
}

class _StampTemplatePainter extends CustomPainter {
  const _StampTemplatePainter({
    required this.templateSize,
    required this.components,
    required this.selectedIndex,
    required this.scheme,
    this.showChrome = true,
  });

  final Size templateSize;
  final List<PdfStampTemplateComponent> components;
  final int? selectedIndex;
  final ColorScheme scheme;
  final bool showChrome;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / templateSize.width;
    canvas.save();
    canvas.scale(scale);
    final templateBounds = Offset.zero & templateSize;
    canvas.drawRRect(
      RRect.fromRectAndRadius(templateBounds, const Radius.circular(10)),
      Paint()..color = scheme.surfaceContainerHighest.withValues(alpha: 0.45),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          templateBounds.deflate(0.5), const Radius.circular(10)),
      Paint()
        ..color = scheme.outlineVariant
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 / scale,
    );
    for (final component in components) {
      _paintComponent(canvas, component);
    }
    if (showChrome &&
        selectedIndex != null &&
        selectedIndex! < components.length) {
      final rect = _rectOf(components[selectedIndex!]);
      final stroke = Paint()
        ..color = scheme.primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 / scale;
      canvas.drawRect(rect.inflate(2 / scale), stroke);
      final handle = Rect.fromCenter(
        center: rect.bottomRight,
        width: 10 / scale,
        height: 10 / scale,
      );
      canvas.drawRect(handle, Paint()..color = scheme.surface);
      canvas.drawRect(handle, stroke);
    }
    canvas.restore();
  }

  Rect _rectOf(PdfStampTemplateComponent c) =>
      Rect.fromLTWH(c.x, c.y, c.width, c.height);

  void _paintComponent(Canvas canvas, PdfStampTemplateComponent c) {
    final rect = _rectOf(c);
    switch (c.type) {
      case PdfStampTemplateComponentType.rectangle:
        final rrect = RRect.fromRectAndRadius(rect, Radius.circular(c.radius));
        if (c.fillColor != null) {
          canvas.drawRRect(
              rrect, Paint()..color = Color(0xFF000000 | c.fillColor!));
        }
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = Color(0xFF000000 | c.color)
            ..style = PaintingStyle.stroke
            ..strokeWidth = c.strokeWidth,
        );
      case PdfStampTemplateComponentType.ellipse:
        if (c.fillColor != null) {
          canvas.drawOval(
              rect, Paint()..color = Color(0xFF000000 | c.fillColor!));
        }
        canvas.drawOval(
          rect,
          Paint()
            ..color = Color(0xFF000000 | c.color)
            ..style = PaintingStyle.stroke
            ..strokeWidth = c.strokeWidth,
        );
      case PdfStampTemplateComponentType.text:
        final text = c.text.isEmpty ? ' ' : c.text;
        var fontSize = c.fontSize ?? c.height * 0.72;
        TextPainter painterFor(double size) => TextPainter(
              text: TextSpan(
                text: text,
                style: TextStyle(
                  color: Color(0xFF000000 | c.color),
                  fontWeight: FontWeight.bold,
                  fontSize: size,
                  letterSpacing: 1,
                ),
              ),
              textDirection: TextDirection.ltr,
              maxLines: 1,
            )..layout(maxWidth: double.infinity);
        var painter = painterFor(fontSize);
        if (painter.width > rect.width && painter.width > 0) {
          fontSize *= rect.width / painter.width;
          painter = painterFor(fontSize);
        }
        painter.paint(
          canvas,
          Offset(rect.left + (rect.width - painter.width) / 2,
              rect.top + (rect.height - painter.height) / 2),
        );
    }
  }

  @override
  bool shouldRepaint(_StampTemplatePainter oldDelegate) =>
      oldDelegate.templateSize != templateSize ||
      oldDelegate.selectedIndex != selectedIndex ||
      oldDelegate.scheme != scheme ||
      oldDelegate.showChrome != showChrome ||
      !_componentListsEqual(oldDelegate.components, components);
}

bool _componentListsEqual(
    List<PdfStampTemplateComponent> a, List<PdfStampTemplateComponent> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<String> _normalizeFields(Iterable<String> fields) {
  final seen = <String>{};
  final normalized = <String>[];
  for (final field in fields) {
    final value = field.trim().toLowerCase();
    if (value.isEmpty || !seen.add(value)) continue;
    normalized.add(value);
  }
  return List.unmodifiable(normalized);
}

String _fieldLabel(String field) => switch (field) {
      'date' => 'Date',
      'time' => 'Time',
      'datetime' => 'Date & time',
      'username' => 'Username',
      _ => field
          .split(RegExp(r'[_\s]+'))
          .where((part) => part.isNotEmpty)
          .map((part) => part[0].toUpperCase() + part.substring(1))
          .join(' '),
    };
