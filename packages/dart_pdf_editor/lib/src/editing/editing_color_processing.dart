import 'package:flutter/material.dart';

import 'editing_color_picker.dart';
import 'editing_controller.dart';
import 'editing_preferences.dart';

/// Shows the document color-processing dialog and returns the number of
/// page-content color operators rewritten, or null when cancelled.
Future<int?> showPdfColorProcessingDialog(
  BuildContext context, {
  required PdfEditingController controller,
  required PdfEditingPreferences preferences,
}) {
  return showDialog<int>(
    context: context,
    builder: (context) => _ColorProcessingDialog(
      controller: controller,
      preferences: preferences,
    ),
  );
}

class _ColorProcessingDialog extends StatefulWidget {
  const _ColorProcessingDialog({
    required this.controller,
    required this.preferences,
  });

  final PdfEditingController controller;
  final PdfEditingPreferences preferences;

  @override
  State<_ColorProcessingDialog> createState() => _ColorProcessingDialogState();
}

class _ColorProcessingDialogState extends State<_ColorProcessingDialog> {
  Color _find = const Color(0xFF000000);
  late Color _replace;
  late bool _selectedPages;
  var _tolerance = 0;
  var _fill = true;
  var _stroke = true;

  @override
  void initState() {
    super.initState();
    _replace = widget.controller.color;
    _selectedPages = widget.controller.selectedPageCount > 0;
  }

  Future<void> _pickFind() => _pickColor(_find, (value) => _find = value);
  Future<void> _pickReplace() =>
      _pickColor(_replace, (value) => _replace = value);

  Future<void> _pickColor(Color initial, ValueChanged<Color> setColor) async {
    final color = await showPdfColorPicker(
      context,
      initial: initial,
      initialFormat: widget.preferences.colorPickerFormat,
      onFormatChanged: (format) =>
          widget.preferences.colorPickerFormat = format,
    );
    if (color == null || !mounted) return;
    setState(() => setColor(color));
  }

  void _apply() {
    final pages = _selectedPages ? widget.controller.selectedPages : null;
    final count = widget.controller.replaceDocumentColors(
      pages: pages,
      find: _find,
      replace: _replace,
      tolerance: _tolerance,
      fill: _fill,
      stroke: _stroke,
    );
    Navigator.of(context).pop(count);
  }

  @override
  Widget build(BuildContext context) {
    final selectedCount = widget.controller.selectedPageCount;
    final canApply = _fill || _stroke;
    return AlertDialog(
      title: const Text('Color processing'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ColorRow(
                key: const ValueKey('pdf-color-process-find'),
                label: 'Find',
                color: _find,
                onTap: _pickFind,
              ),
              const SizedBox(height: 8),
              _ColorRow(
                key: const ValueKey('pdf-color-process-replace'),
                label: 'Replace',
                color: _replace,
                onTap: _pickReplace,
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  const Expanded(child: Text('Tolerance')),
                  Text('$_tolerance'),
                ],
              ),
              Slider(
                key: const ValueKey('pdf-color-process-tolerance'),
                min: 0,
                max: 255,
                divisions: 255,
                value: _tolerance.toDouble(),
                label: '$_tolerance',
                onChanged: (value) =>
                    setState(() => _tolerance = value.round()),
              ),
              const SizedBox(height: 4),
              RadioGroup<bool>(
                groupValue: _selectedPages,
                onChanged: (value) {
                  if (value == null) return;
                  if (value && selectedCount == 0) return;
                  setState(() => _selectedPages = value);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile<bool>(
                      key: const ValueKey('pdf-color-process-selected-pages'),
                      value: true,
                      enabled: selectedCount > 0,
                      title: Text('Selected pages ($selectedCount)'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                    const RadioListTile<bool>(
                      key: ValueKey('pdf-color-process-whole-document'),
                      value: false,
                      title: Text('Whole document'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              CheckboxListTile(
                key: const ValueKey('pdf-color-process-fill'),
                value: _fill,
                onChanged: (value) => setState(() => _fill = value ?? false),
                title: const Text('Fill colors'),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
              CheckboxListTile(
                key: const ValueKey('pdf-color-process-stroke'),
                value: _stroke,
                onChanged: (value) => setState(() => _stroke = value ?? false),
                title: const Text('Stroke colors'),
                dense: true,
                contentPadding: EdgeInsets.zero,
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
          key: const ValueKey('pdf-color-process-apply'),
          onPressed: canApply ? _apply : null,
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

class _ColorRow extends StatelessWidget {
  const _ColorRow({
    super.key,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final rgb = color.toARGB32() & 0xFFFFFF;
    final hex = '#${rgb.toRadixString(16).toUpperCase().padLeft(6, '0')}';
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SizedBox(width: 68, child: Text(label)),
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: Color(0xFF000000 | rgb),
                border:
                    Border.all(color: Theme.of(context).colorScheme.outline),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 10),
            Text(hex),
            const Spacer(),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}
