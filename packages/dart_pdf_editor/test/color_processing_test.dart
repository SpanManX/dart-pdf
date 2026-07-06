import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _pdf(List<String> pageContents) {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${[
      for (var i = 0; i < pageContents.length; i++) '${3 + i * 2} 0 R'
    ].join(' ')}] /Count ${pageContents.length} >>',
    for (var i = 0; i < pageContents.length; i++) ...[
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] '
          '/Resources << >> /Contents ${4 + i * 2} 0 R >>',
      '<< /Length ${latin1.encode(pageContents[i]).length} >>\n'
          'stream\n${pageContents[i]}\nendstream',
    ],
  ];
  final buffer = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(buffer.length);
    buffer.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xrefOffset = buffer.length;
  buffer
    ..write('xref\n0 ${objects.length + 1}\n')
    ..write('0000000000 65535 f \n');
  for (final offset in offsets) {
    buffer.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  buffer
    ..write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n')
    ..write('startxref\n$xrefOffset\n%%EOF\n');
  return Uint8List.fromList(latin1.encode(buffer.toString()));
}

String _content(PdfEditingController controller, int page) =>
    latin1.decode(controller.document.page(page).contentBytes());

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('replaceSelectedPageColors changes only the selected pages', () {
    final controller = PdfEditingController(_pdf([
      '1 0 0 rg 0 0 10 10 re f',
      '1 0 0 rg 0 0 10 10 re f',
    ]));
    addTearDown(controller.dispose);

    controller.selectPage(1);
    final count = controller.replaceSelectedPageColors(
      find: const Color(0xFFFF0000),
      replace: const Color(0xFF0000FF),
    );

    expect(count, 1);
    expect(_content(controller, 0), contains('1 0 0 rg'));
    expect(_content(controller, 1), contains('0 0 1 rg'));

    controller.undo();
    expect(_content(controller, 1), contains('1 0 0 rg'));
  });

  test('replaceDocumentColors processes the whole document by default', () {
    final controller = PdfEditingController(_pdf([
      '1 0 0 rg 0 0 10 10 re f',
      '1 0 0 rg 0 0 10 10 re f',
    ]));
    addTearDown(controller.dispose);

    final count = controller.replaceDocumentColors(
      find: const Color(0xFFFF0000),
      replace: const Color(0xFF0000FF),
    );

    expect(count, 2);
    expect(_content(controller, 0), contains('0 0 1 rg'));
    expect(_content(controller, 1), contains('0 0 1 rg'));
  });

  testWidgets('PdfEditorView exposes the color processing dialog',
      (tester) async {
    final controller = PdfEditingController(_pdf([
      '0 g 0 0 10 10 re f',
    ]))
      ..color = const Color(0xFF0000FF);
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PdfEditorView(
          controller: controller,
          showSaveButton: false,
        ),
      ),
    ));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('pdf-shell-color-processing')),
        kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('pdf-color-process-apply')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('pdf-color-process-apply')),
        kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();

    expect(_content(controller, 0), contains('0 0 1 rg'));

    // Drain the result SnackBar's timer.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
