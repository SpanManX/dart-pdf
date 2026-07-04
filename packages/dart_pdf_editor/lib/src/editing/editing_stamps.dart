import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdf_document/pdf_document.dart';

import 'editing_controller.dart';
import 'text_prompt.dart';

/// A reusable rubber stamp: visual template plus optional app metadata.
///
/// Custom stamps are saved on the local device through
/// [PdfEditingPreferences.customStamps], so they survive app restarts and
/// are shared across documents. Host apps can also supply non-persisted stamps
/// through [PdfEditingController.providedCustomStamps] or the editor shell's
/// custom-stamps parameter. The stamp tool places the
/// [PdfEditingController.activeStamp] with a tap; with none active it falls
/// back to the classic flow (drag a box, type the caption).
///
/// Serializes to JSON so [PdfEditingPreferences] can persist it.
class PdfCustomStamp {
  const PdfCustomStamp({
    required this.text,
    required this.color,
    this.template,
    this.type,
    this.tags = const [],
  });

  /// The caption drawn inside the stamp's rounded border.
  final String text;

  /// RGB border and caption color.
  final int color;

  /// Editable vector template for newer stamps. Null means this is a legacy
  /// text-only stamp and should be rendered with the classic appearance.
  final PdfStampTemplate? template;

  /// App-defined stamp kind, e.g. "Approval", "Audit", or "Tested".
  final String? type;

  /// App-defined labels for filtering, grouping, or reporting stamps.
  final List<String> tags;

  bool hasTag(String tag) {
    final normalized = tag.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    return tags.any((value) => value.trim().toLowerCase() == normalized);
  }

  String encode() => jsonEncode({
        'text': text,
        'color': color,
        if (template != null) 'template': template!.toJson(),
        if (type != null && type!.trim().isNotEmpty) 'type': type,
        if (tags.isNotEmpty) 'tags': tags,
      });

  /// Parses [encode]'s output; null for anything malformed.
  static PdfCustomStamp? decode(String json) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return PdfCustomStamp(
        text: map['text'] as String,
        color: map['color'] as int,
        template: PdfStampTemplate.fromJson(map['template']),
        type: map['type'] is String ? map['type'] as String : null,
        tags: [
          if (map['tags'] is List)
            for (final tag in map['tags'] as List)
              if (tag is String && tag.trim().isNotEmpty) tag
        ],
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
      other.template == template &&
      other.type == type &&
      _stringListEquals(other.tags, tags);

  @override
  int get hashCode => Object.hash(text, color, template, type,
      Object.hashAll(tags.map((tag) => tag.trim().toLowerCase())));
}

/// Shows the stamp picker: choose the stamp the stamp tool places,
/// create a new one, or delete saved ones. Selections apply directly to
/// [controller].
Future<void> showPdfStampPicker(BuildContext context,
        {required PdfEditingController controller,
        PdfImagePicker? imagePicker}) =>
    showDialog<void>(
      context: context,
      builder: (context) => PdfStampPickerDialog(
        controller: controller,
        imagePicker: imagePicker,
      ),
    );

/// The stamp picker dialog behind [showPdfStampPicker].
class PdfStampPickerDialog extends StatelessWidget {
  const PdfStampPickerDialog({
    super.key,
    required this.controller,
    this.imagePicker,
  });

  final PdfEditingController controller;
  final PdfImagePicker? imagePicker;

  Future<void> _create(BuildContext context) async {
    final created = await showPdfStampEditor(context,
        fields: controller.stampTemplateFieldNames, imagePicker: imagePicker);
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
                    subtitle: _stampDetail(stamp) == null
                        ? null
                        : Text(_stampDetail(stamp)!),
                    trailing: controller.isSavedCustomStamp(stamp)
                        ? IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: 'Delete stamp',
                            onPressed: () =>
                                controller.removeCustomStamp(stamp),
                          )
                        : null,
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
            PdfEditingController.stampTemplateBuiltinFields,
        PdfImagePicker? imagePicker}) =>
    showDialog<PdfCustomStamp>(
      context: context,
      builder: (context) => PdfStampEditorDialog(
        fields: fields,
        imagePicker: imagePicker,
      ),
    );

/// The stamp creation dialog behind [showPdfStampEditor]: caption field,
/// color choice, and a live preview matching the placed appearance.
class PdfStampEditorDialog extends StatefulWidget {
  const PdfStampEditorDialog({
    super.key,
    this.fields = const [],
    this.imagePicker,
  });

  final Iterable<String> fields;
  final PdfImagePicker? imagePicker;

  @override
  State<PdfStampEditorDialog> createState() => _PdfStampEditorDialogState();
}

class _PdfStampEditorDialogState extends State<PdfStampEditorDialog> {
  static const _inks = [0xC03030, 0x2E7D32, 0x1A3E8C, 0xEF6C00, 0x000000];
  static const _defaultTemplateWidth = 240.0;
  static const _defaultTemplateHeight = 96.0;

  final _text = TextEditingController(text: 'APPROVED');
  late final TextEditingController _width;
  late final TextEditingController _height;
  late List<PdfStampTemplateComponent> _components;
  late final List<String> _fields;
  int? _selected = 1;
  int _color = _inks.first;
  double _templateWidth = _defaultTemplateWidth;
  double _templateHeight = _defaultTemplateHeight;

  @override
  void initState() {
    super.initState();
    _fields = _normalizeFields(widget.fields);
    _width = TextEditingController(text: _templateWidth.round().toString());
    _height = TextEditingController(text: _templateHeight.round().toString());
    _components = List.of(PdfStampTemplate.text(_text.text, _color).components);
  }

  @override
  void dispose() {
    _text.dispose();
    _width.dispose();
    _height.dispose();
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

  Size get _templateSize => Size(_templateWidth, _templateHeight);

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

  void _setTemplateSize({double? width, double? height}) {
    final nextWidth = (width ?? _templateWidth).clamp(80.0, 640.0).toDouble();
    final nextHeight =
        (height ?? _templateHeight).clamp(32.0, 360.0).toDouble();
    if (nextWidth == _templateWidth && nextHeight == _templateHeight) return;
    final sx = nextWidth / _templateWidth;
    final sy = nextHeight / _templateHeight;
    setState(() {
      _templateWidth = nextWidth;
      _templateHeight = nextHeight;
      _width.text = nextWidth.round().toString();
      _height.text = nextHeight.round().toString();
      _components = [
        for (final component in _components) _scaleComponent(component, sx, sy),
      ];
    });
  }

  PdfStampTemplateComponent _scaleComponent(
      PdfStampTemplateComponent component, double sx, double sy) {
    final scaled = component.copyWith(
      x: component.x * sx,
      y: component.y * sy,
      width: component.width * sx,
      height: component.height * sy,
    );
    final fontSize = component.fontSize;
    return fontSize == null
        ? scaled
        : scaled.copyWith(fontSize: fontSize * math.min(sx, sy));
  }

  void _commitSize() {
    final width = double.tryParse(_width.text.trim());
    final height = double.tryParse(_height.text.trim());
    _setTemplateSize(width: width, height: height);
    _width.text = _templateWidth.round().toString();
    _height.text = _templateHeight.round().toString();
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

  void _setSelectedFont(PdfStandardFont font) {
    final component = _selectedComponent;
    if (component?.type != PdfStampTemplateComponentType.text) return;
    _replaceSelected(component!.copyWith(font: font));
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

  Future<void> _addImage() async {
    final picker = widget.imagePicker;
    if (picker == null) return;
    final bytes = await picker(context);
    if (bytes == null || !mounted) return;
    final PdfEmbeddableImage image;
    try {
      image = PdfEmbeddableImage.decode(bytes);
    } catch (_) {
      return;
    }
    final aspect = image.height == 0 ? 1.0 : image.width / image.height;
    var width = math.min(96.0, _templateWidth * 0.55);
    var height = width / aspect;
    if (height > _templateHeight * 0.6) {
      height = _templateHeight * 0.6;
      width = height * aspect;
    }
    final component = PdfStampTemplateComponent.image(
      x: (_templateWidth - width) / 2,
      y: (_templateHeight - height) / 2,
      width: width,
      height: height,
      imageBytes: Uint8List.fromList(bytes),
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
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StampTemplateCanvas(
                key: const ValueKey('pdf-stamp-template-canvas'),
                templateSize: _templateSize,
                components: _components,
                selectedIndex: _selected,
                onSelect: _select,
                onMoveSelected: _moveSelected,
                onResizeSelected: _resizeSelected,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  SizedBox(
                    width: 92,
                    child: TextField(
                      key: const ValueKey('pdf-stamp-width'),
                      controller: _width,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Width'),
                      onSubmitted: (_) => _commitSize(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 92,
                    child: TextField(
                      key: const ValueKey('pdf-stamp-height'),
                      controller: _height,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Height'),
                      onSubmitted: (_) => _commitSize(),
                    ),
                  ),
                ],
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
                            ? (value) => _replaceSelected(
                                selected!.copyWith(text: value))
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
                    PopupMenuButton<PdfStandardFont>(
                      key: const ValueKey('pdf-stamp-font-menu'),
                      tooltip: 'Font',
                      enabled: selectedIsText,
                      icon: const Icon(Icons.font_download_outlined),
                      initialValue: selectedIsText ? selected!.font : null,
                      onSelected: _setSelectedFont,
                      itemBuilder: (context) => [
                        for (final font in PdfStandardFont.values)
                          PopupMenuItem<PdfStandardFont>(
                            key: ValueKey('pdf-stamp-font-${font.name}'),
                            value: font,
                            child: Text(
                              _fontLabel(font),
                              style: TextStyle(
                                fontFamily: _uiFamily(font),
                                fontWeight: font.isBold
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                fontStyle: font.isItalic
                                    ? FontStyle.italic
                                    : FontStyle.normal,
                              ),
                            ),
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
                  OutlinedButton.icon(
                    key: const ValueKey('pdf-stamp-add-image'),
                    onPressed: widget.imagePicker == null ? null : _addImage,
                    icon: const Icon(Icons.image_outlined),
                    label: const Text('Image'),
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
        ),
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
      child: _StampTemplateSurface(
        templateSize: Size(template.width, template.height),
        components: template.components,
        selectedIndex: null,
        scheme: Theme.of(context).colorScheme,
        showChrome: false,
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
        child: _StampTemplateSurface(
          templateSize: widget.templateSize,
          components: widget.components,
          selectedIndex: widget.selectedIndex,
          scheme: scheme,
        ),
      ),
    );
  }
}

class _StampTemplateSurface extends StatefulWidget {
  const _StampTemplateSurface({
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
  State<_StampTemplateSurface> createState() => _StampTemplateSurfaceState();
}

class _StampTemplateSurfaceState extends State<_StampTemplateSurface> {
  final Map<int, ui.Image> _images = {};
  final Set<int> _requested = {};

  @override
  void initState() {
    super.initState();
    _syncImages();
  }

  @override
  void didUpdateWidget(_StampTemplateSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncImages();
  }

  @override
  void dispose() {
    for (final image in _images.values) {
      image.dispose();
    }
    super.dispose();
  }

  void _syncImages() {
    final wanted = _wantedImageKeys();
    for (final key in _images.keys.toList()) {
      if (!wanted.contains(key)) _images.remove(key)?.dispose();
    }
    _requested.removeWhere((key) => !wanted.contains(key));
    for (final component in widget.components) {
      final bytes = component.imageBytes;
      if (component.type != PdfStampTemplateComponentType.image ||
          bytes == null) {
        continue;
      }
      final key = _imageKey(bytes);
      if (_images.containsKey(key) || !_requested.add(key)) continue;
      ui.decodeImageFromList(bytes, (image) {
        if (!mounted || !_wantedImageKeys().contains(key)) {
          image.dispose();
          _requested.remove(key);
          return;
        }
        final old = _images[key];
        setState(() => _images[key] = image);
        old?.dispose();
      });
    }
  }

  Set<int> _wantedImageKeys() => {
        for (final component in widget.components)
          if (component.type == PdfStampTemplateComponentType.image &&
              component.imageBytes != null)
            _imageKey(component.imageBytes!)
      };

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _StampTemplatePainter(
          templateSize: widget.templateSize,
          components: widget.components,
          selectedIndex: widget.selectedIndex,
          scheme: widget.scheme,
          showChrome: widget.showChrome,
          images: Map<int, ui.Image>.unmodifiable(_images),
        ),
      );
}

class _StampTemplatePainter extends CustomPainter {
  const _StampTemplatePainter({
    required this.templateSize,
    required this.components,
    required this.selectedIndex,
    required this.scheme,
    required this.images,
    this.showChrome = true,
  });

  final Size templateSize;
  final List<PdfStampTemplateComponent> components;
  final int? selectedIndex;
  final ColorScheme scheme;
  final Map<int, ui.Image> images;
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
                  fontFamily: _uiFamily(c.font),
                  fontWeight:
                      c.font.isBold ? FontWeight.bold : FontWeight.normal,
                  fontStyle:
                      c.font.isItalic ? FontStyle.italic : FontStyle.normal,
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
      case PdfStampTemplateComponentType.image:
        final bytes = c.imageBytes;
        final image = bytes == null ? null : images[_imageKey(bytes)];
        if (image == null) {
          canvas.drawRect(
            rect,
            Paint()
              ..color = scheme.surfaceContainerHighest
              ..style = PaintingStyle.fill,
          );
          canvas.drawRect(
            rect,
            Paint()
              ..color = scheme.outline
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1,
          );
          return;
        }
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          rect,
          Paint(),
        );
    }
  }

  @override
  bool shouldRepaint(_StampTemplatePainter oldDelegate) =>
      oldDelegate.templateSize != templateSize ||
      oldDelegate.selectedIndex != selectedIndex ||
      oldDelegate.scheme != scheme ||
      oldDelegate.showChrome != showChrome ||
      oldDelegate.images != images ||
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

bool _stringListEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _imageKey(Uint8List bytes) => Object.hash(
    bytes.length,
    bytes.isEmpty ? 0 : bytes.first,
    bytes.isEmpty ? 0 : bytes.last,
    Object.hashAll(bytes));

String? _stampDetail(PdfCustomStamp stamp) {
  final parts = [
    if (stamp.type != null && stamp.type!.trim().isNotEmpty) stamp.type!.trim(),
    if (stamp.tags.isNotEmpty) stamp.tags.join(', '),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

String _fontLabel(PdfStandardFont font) {
  final family = font.family.label;
  final style = [
    if (font.isBold) 'Bold',
    if (font.isItalic) 'Italic',
  ].join(' ');
  return style.isEmpty ? family : '$family $style';
}

String? _uiFamily(PdfStandardFont font) => switch (font.family) {
      PdfStandardFontFamily.serif => 'Times New Roman',
      PdfStandardFontFamily.mono => 'Courier',
      PdfStandardFontFamily.sans => 'Helvetica',
    };

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
