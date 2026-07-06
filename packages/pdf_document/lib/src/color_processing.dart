part of 'editor.dart';

/// Page-content color processing: find a device color and replace it with
/// another across content streams.
extension PdfColorProcessing on PdfEditor {
  /// Replaces matching vector/text drawing colors on page [index].
  ///
  /// [find] and [replace] are `0xRRGGBB`. [tolerance] is an 8-bit channel
  /// tolerance (`0` means exact; `255` matches every channel). Set [fill] or
  /// [stroke] false to leave that paint side untouched. Returns the number
  /// of color-setting operators rewritten.
  ///
  /// This edits page content streams: text fill, path fill/stroke, and other
  /// operators that set the current non-stroking/stroking color. It handles
  /// DeviceGray, DeviceRGB and DeviceCMYK operators plus `sc`/`SC` variants
  /// while the current color space is one of those device spaces. Image
  /// pixels, shading functions, patterns, form XObjects, and annotation
  /// appearance streams are intentionally left unchanged.
  int replaceColors(
    int index, {
    required int find,
    required int replace,
    int tolerance = 0,
    bool fill = true,
    bool stroke = true,
  }) {
    if (!fill && !stroke) return 0;
    if (index < 0 || index >= document.pageCount) {
      throw RangeError.range(index, 0, document.pageCount - 1, 'index');
    }
    final page = document.page(index);
    final operations = ContentStreamParser.parse(page.contentBytes());
    final processor = _ColorProcessor(
      editor: this,
      page: page,
      find: find & 0xFFFFFF,
      replace: replace & 0xFFFFFF,
      tolerance: tolerance.clamp(0, 255).toInt(),
      fill: fill,
      stroke: stroke,
    );
    final rewritten = processor.rewrite(operations);
    if (processor.count == 0) return 0;
    _setContent(page, ContentStreamSerializer.serialize(rewritten));
    return processor.count;
  }

  /// Runs [replaceColors] over [indices] as one editor operation and returns
  /// the total number of color-setting operators rewritten.
  int replaceColorsOnPages(
    Iterable<int> indices, {
    required int find,
    required int replace,
    int tolerance = 0,
    bool fill = true,
    bool stroke = true,
  }) {
    var count = 0;
    final seen = <int>{};
    for (final index in indices) {
      if (!seen.add(index)) continue;
      count += replaceColors(
        index,
        find: find,
        replace: replace,
        tolerance: tolerance,
        fill: fill,
        stroke: stroke,
      );
    }
    return count;
  }
}

enum _DeviceColorSpace { gray, rgb, cmyk, other }

enum _PaintSide { fill, stroke }

class _ColorGraphicsState {
  const _ColorGraphicsState({
    this.fillSpace = _DeviceColorSpace.gray,
    this.strokeSpace = _DeviceColorSpace.gray,
  });

  final _DeviceColorSpace fillSpace;
  final _DeviceColorSpace strokeSpace;

  _ColorGraphicsState copyWith({
    _DeviceColorSpace? fillSpace,
    _DeviceColorSpace? strokeSpace,
  }) =>
      _ColorGraphicsState(
        fillSpace: fillSpace ?? this.fillSpace,
        strokeSpace: strokeSpace ?? this.strokeSpace,
      );
}

class _ColorProcessor {
  _ColorProcessor({
    required this.editor,
    required this.page,
    required this.find,
    required this.replace,
    required this.tolerance,
    required this.fill,
    required this.stroke,
  });

  final PdfEditor editor;
  final PdfPage page;
  final int find;
  final int replace;
  final int tolerance;
  final bool fill;
  final bool stroke;

  int count = 0;
  _ColorGraphicsState _state = const _ColorGraphicsState();
  final List<_ColorGraphicsState> _stack = [];

  List<ContentOperation> rewrite(List<ContentOperation> operations) {
    final out = <ContentOperation>[];
    for (final op in operations) {
      out.add(_rewriteOperation(op));
    }
    return out;
  }

  ContentOperation _rewriteOperation(ContentOperation op) {
    switch (op.operator) {
      case 'q':
        _stack.add(_state);
        return op;
      case 'Q':
        if (_stack.isNotEmpty) _state = _stack.removeLast();
        return op;
      case 'cs':
        _state = _state.copyWith(fillSpace: _spaceFromOperands(op.operands));
        return op;
      case 'CS':
        _state = _state.copyWith(strokeSpace: _spaceFromOperands(op.operands));
        return op;
      case 'g':
        return _deviceColor(op, _PaintSide.fill, _DeviceColorSpace.gray);
      case 'G':
        return _deviceColor(op, _PaintSide.stroke, _DeviceColorSpace.gray);
      case 'rg':
        return _deviceColor(op, _PaintSide.fill, _DeviceColorSpace.rgb);
      case 'RG':
        return _deviceColor(op, _PaintSide.stroke, _DeviceColorSpace.rgb);
      case 'k':
        return _deviceColor(op, _PaintSide.fill, _DeviceColorSpace.cmyk);
      case 'K':
        return _deviceColor(op, _PaintSide.stroke, _DeviceColorSpace.cmyk);
      case 'sc' || 'scn':
        return _currentSpaceColor(op, _PaintSide.fill);
      case 'SC' || 'SCN':
        return _currentSpaceColor(op, _PaintSide.stroke);
      default:
        return op;
    }
  }

  ContentOperation _deviceColor(
      ContentOperation op, _PaintSide side, _DeviceColorSpace space) {
    _setSpace(side, space);
    return _maybeReplace(op, side, space);
  }

  ContentOperation _currentSpaceColor(ContentOperation op, _PaintSide side) {
    if (op.operands.any((operand) => operand is CosName)) {
      return op; // pattern names and separations are outside this pass
    }
    final space =
        side == _PaintSide.fill ? _state.fillSpace : _state.strokeSpace;
    return _maybeReplace(op, side, space);
  }

  ContentOperation _maybeReplace(
      ContentOperation op, _PaintSide side, _DeviceColorSpace space) {
    if (side == _PaintSide.fill && !fill) return op;
    if (side == _PaintSide.stroke && !stroke) return op;
    final rgb = _rgbFrom(op.operands, space);
    if (rgb == null || !_matches(rgb)) return op;
    count++;
    _setSpace(side, _DeviceColorSpace.rgb);
    return ContentOperation(
      side == _PaintSide.fill ? 'rg' : 'RG',
      _rgbOperands(replace),
    );
  }

  void _setSpace(_PaintSide side, _DeviceColorSpace space) {
    _state = side == _PaintSide.fill
        ? _state.copyWith(fillSpace: space)
        : _state.copyWith(strokeSpace: space);
  }

  bool _matches(int rgb) {
    final ar = (rgb >> 16) & 0xFF;
    final ag = (rgb >> 8) & 0xFF;
    final ab = rgb & 0xFF;
    final br = (find >> 16) & 0xFF;
    final bg = (find >> 8) & 0xFF;
    final bb = find & 0xFF;
    return (ar - br).abs() <= tolerance &&
        (ag - bg).abs() <= tolerance &&
        (ab - bb).abs() <= tolerance;
  }

  _DeviceColorSpace _spaceFromOperands(List<CosObject> operands) {
    if (operands.isEmpty) return _DeviceColorSpace.other;
    final first = operands.first;
    if (first is! CosName) return _DeviceColorSpace.other;
    return _spaceFromName(first.value);
  }

  _DeviceColorSpace _spaceFromName(String name) {
    switch (name) {
      case 'DeviceGray' || 'G':
        return _DeviceColorSpace.gray;
      case 'DeviceRGB' || 'RGB':
        return _DeviceColorSpace.rgb;
      case 'DeviceCMYK' || 'CMYK':
        return _DeviceColorSpace.cmyk;
    }

    final colorSpaces =
        editor.document.cos.resolve(page.resources['ColorSpace']);
    if (colorSpaces is! CosDictionary) return _DeviceColorSpace.other;
    return _spaceFromObject(editor.document.cos.resolve(colorSpaces[name]));
  }

  _DeviceColorSpace _spaceFromObject(CosObject? object) {
    final resolved = editor.document.cos.resolve(object);
    if (resolved is CosName) return _spaceFromName(resolved.value);
    if (resolved is CosArray && resolved.items.isNotEmpty) {
      final first = editor.document.cos.resolve(resolved.items.first);
      if (first is CosName) return _spaceFromName(first.value);
    }
    if (resolved is CosStream) {
      final n = editor.document.cos.resolve(resolved.dictionary['N']);
      if (n is CosInteger) {
        return switch (n.value) {
          1 => _DeviceColorSpace.gray,
          3 => _DeviceColorSpace.rgb,
          4 => _DeviceColorSpace.cmyk,
          _ => _DeviceColorSpace.other,
        };
      }
    }
    return _DeviceColorSpace.other;
  }

  int? _rgbFrom(List<CosObject> operands, _DeviceColorSpace space) {
    double clamp01(double value) => value.clamp(0.0, 1.0).toDouble();

    double? component(int index) {
      if (index >= operands.length) return null;
      return switch (operands[index]) {
        CosInteger(:final value) => clamp01(value.toDouble()),
        CosReal(:final value) => clamp01(value),
        _ => null,
      };
    }

    int byte(double value) => (clamp01(value) * 255).round();

    switch (space) {
      case _DeviceColorSpace.gray:
        final g = component(0);
        if (g == null) return null;
        final b = byte(g);
        return (b << 16) | (b << 8) | b;
      case _DeviceColorSpace.rgb:
        final r = component(0), g = component(1), b = component(2);
        if (r == null || g == null || b == null) return null;
        return (byte(r) << 16) | (byte(g) << 8) | byte(b);
      case _DeviceColorSpace.cmyk:
        final c = component(0), m = component(1), y = component(2);
        final k = component(3);
        if (c == null || m == null || y == null || k == null) return null;
        final r = 1 - (c + k).clamp(0.0, 1.0);
        final g = 1 - (m + k).clamp(0.0, 1.0);
        final b = 1 - (y + k).clamp(0.0, 1.0);
        return (byte(r) << 16) | (byte(g) << 8) | byte(b);
      case _DeviceColorSpace.other:
        return null;
    }
  }

  List<CosObject> _rgbOperands(int rgb) => [
        _component((rgb >> 16) & 0xFF),
        _component((rgb >> 8) & 0xFF),
        _component(rgb & 0xFF),
      ];

  CosObject _component(int value) {
    if (value <= 0) return CosInteger(0);
    if (value >= 255) return CosInteger(1);
    return CosReal(value / 255);
  }
}
