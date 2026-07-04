import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:pdf_test_fixtures/pdf_test_fixtures.dart';
import 'package:shared_preferences/shared_preferences.dart';

String appearanceText(PdfEditingController editing) {
  final annotation = editing.document.page(0).annotations.single;
  return latin1.decode(
      editing.document.cos.decodeStreamData(annotation.normalAppearance!));
}

void main() {
  group('PdfCustomStamp', () {
    test('round-trips through JSON; junk decodes to null', () {
      const stamp = PdfCustomStamp(text: 'APPROVED', color: 0xC03030);
      expect(PdfCustomStamp.decode(stamp.encode()), stamp);
      expect(PdfCustomStamp.decode('not json'), isNull);
      expect(PdfCustomStamp.decode('{"text": "X"}'), isNull);
    });

    test('round-trips editable templates through JSON', () {
      final template = PdfStampTemplate.text('APPROVED', 0xC03030);
      final stamp =
          PdfCustomStamp(text: 'APPROVED', color: 0xC03030, template: template);
      final decoded = PdfCustomStamp.decode(stamp.encode());
      expect(decoded, stamp);
      expect(decoded!.template, template);
      expect(decoded.template!.components.length, 2);
    });

    test('resolves template placeholders without mutating the saved template',
        () {
      expect(
          pdfResolveStampTemplateText(
              'Issued {{ Date }} by {{username}} for {{missing}}',
              {'date': '2026-07-04', 'username': 'Ben'}),
          'Issued 2026-07-04 by Ben for {{missing}}');

      final template = PdfStampTemplate(
        width: 240,
        height: 96,
        components: [
          PdfStampTemplateComponent.text(
            x: 12,
            y: 30,
            width: 216,
            height: 36,
            text: '{{project}}',
            color: 0x1A3E8C,
          ),
        ],
      );
      final resolved = template.resolveText({'project': 'AMT-SP'});
      expect(resolved.components.single.text, 'AMT-SP');
      expect(template.components.single.text, '{{project}}');
    });

    test('persists through PdfEditingPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final template = PdfStampTemplate.text('PAID', 0xEF6C00);
      final paid =
          PdfCustomStamp(text: 'PAID', color: 0xEF6C00, template: template);
      final a = PdfEditingPreferences();
      await a.ready;
      a.customStamps = [
        const PdfCustomStamp(text: 'APPROVED', color: 0xC03030),
        paid,
      ];
      await pumpEventQueue();

      final b = PdfEditingPreferences();
      await b.ready;
      expect(b.customStamps, [
        const PdfCustomStamp(text: 'APPROVED', color: 0xC03030),
        paid,
      ]);
      expect(b.customStamps.last.template, template);

      a.customStamps = const [];
      await pumpEventQueue();
      final c = PdfEditingPreferences();
      await c.ready;
      expect(c.customStamps, isEmpty);
    });
  });

  group('custom stamps on the controller', () {
    const approved = PdfCustomStamp(text: 'APPROVED', color: 0x2E7D32);
    const draft = PdfCustomStamp(text: 'DRAFT', color: 0x1A3E8C);

    test('save, remove, and active-stamp bookkeeping', () {
      final editing = PdfEditingController(buildMultiPagePdf(1));
      editing
        ..saveCustomStamp(approved)
        ..saveCustomStamp(draft);
      expect(editing.customStamps, [approved, draft]);

      editing.activeStamp = draft;
      editing.removeCustomStamp(draft);
      expect(editing.customStamps, [approved]);
      // deleting the active stamp falls back to the classic flow
      expect(editing.activeStamp, isNull);
    });

    test('placeStamp centers an auto-sized Stamp annotation', () {
      final editing = PdfEditingController(buildMultiPagePdf(1))
        ..activeStamp = approved;
      expect(editing.placeStamp(0, 300, 400), isTrue);

      final stamp = editing.document.page(0).annotations.single;
      expect(stamp.subtype, 'Stamp');
      expect(stamp.contents, 'APPROVED');
      expect(stamp.color, 0x2E7D32);
      expect(stamp.rect.height, moreOrLessEquals(40));
      expect((stamp.rect.left + stamp.rect.right) / 2, moreOrLessEquals(300));
      expect((stamp.rect.bottom + stamp.rect.top) / 2, moreOrLessEquals(400));
      // wide enough for the caption, not absurdly so
      expect(stamp.rect.width, greaterThan(80));
      expect(stamp.rect.width, lessThan(250));
    });

    test('placeStamp compiles editable templates into one Stamp annotation',
        () {
      final template = PdfStampTemplate.text('REVIEWED', 0x1A3E8C);
      final editing = PdfEditingController(buildMultiPagePdf(1))
        ..activeStamp = PdfCustomStamp(
            text: 'REVIEWED', color: 0x1A3E8C, template: template);
      expect(editing.placeStamp(0, 300, 400), isTrue);

      final stamp = editing.document.page(0).annotations.single;
      expect(stamp.subtype, 'Stamp');
      expect(stamp.contents, 'REVIEWED');
      expect(stamp.rect.height, moreOrLessEquals(40));
      expect(stamp.rect.width, moreOrLessEquals(100));
      final content = appearanceText(editing);
      expect(content, contains('(REVIEWED) Tj'));
    });

    test('placeStamp resolves built-in and custom template fields', () {
      final template = PdfStampTemplate(
        width: 240,
        height: 96,
        components: [
          PdfStampTemplateComponent.text(
            x: 8,
            y: 30,
            width: 224,
            height: 36,
            text: '{{date}} {{time}} {{username}} {{project}}',
            color: 0x1A3E8C,
            fontSize: 22,
          ),
        ],
      );
      final editing = PdfEditingController(buildMultiPagePdf(1))
        ..author = 'Comment Author'
        ..stampTemplateClock = (() => DateTime(2026, 7, 4, 9, 5))
        ..stampTemplateValues = {
          'username': 'Ben',
          'project': 'AMT-SP',
        }
        ..activeStamp = PdfCustomStamp(
          text: 'Issued {{date}} for {{project}}',
          color: 0x1A3E8C,
          template: template,
        );

      expect(editing.placeStamp(0, 300, 400), isTrue);

      final stamp = editing.document.page(0).annotations.single;
      expect(stamp.contents, 'Issued 2026-07-04 for AMT-SP');
      expect(appearanceText(editing),
          contains('(2026-07-04 09:05 Ben AMT-SP) Tj'));
    });

    test('clamps so the whole stamp stays on the page', () {
      final editing = PdfEditingController(buildMultiPagePdf(1))
        ..activeStamp = approved;
      final box = editing.document.page(0).cropBox;
      expect(editing.placeStamp(0, box.right, box.top), isTrue);

      final stamp = editing.document.page(0).annotations.single;
      expect(stamp.rect.right, lessThanOrEqualTo(box.right + 0.01));
      expect(stamp.rect.top, lessThanOrEqualTo(box.top + 0.01));
    });

    test('without an active stamp nothing happens', () {
      final editing = PdfEditingController(buildMultiPagePdf(1));
      expect(editing.placeStamp(0, 300, 400), isFalse);
      expect(editing.document.page(0).annotations, isEmpty);
      expect(editing.isModified, isFalse);
    });

    test('placeTextStamp drops a default-sized stamp without an active stamp',
        () {
      final editing = PdfEditingController(buildMultiPagePdf(1))
        ..color = const Color(0xFF1565C0);
      expect(editing.placeTextStamp(0, 300, 400, 'REVIEWED'), isTrue);

      final stamp = editing.document.page(0).annotations.single;
      expect(stamp.subtype, 'Stamp');
      expect(stamp.contents, 'REVIEWED');
      // no colour given, so it follows the selected toolbar colour
      expect(stamp.color, 0x1565C0);
      expect(stamp.rect.height, moreOrLessEquals(40));
      expect((stamp.rect.left + stamp.rect.right) / 2, moreOrLessEquals(300));
      expect((stamp.rect.bottom + stamp.rect.top) / 2, moreOrLessEquals(400));
    });

    test('placeTextStamp on a rotated page uses visual orientation', () {
      final editing = PdfEditingController(buildMultiPagePdf(1))
        ..color = const Color(0xFF1565C0);
      addTearDown(editing.dispose);
      expect(editing.rotatePages([0], 90), isTrue);
      expect(editing.placeTextStamp(0, 300, 400, 'REVIEWED'), isTrue);

      final stamp = editing.document.page(0).annotations.single;
      expect(stamp.subtype, 'Stamp');
      expect(stamp.rect.width, moreOrLessEquals(40));
      expect(stamp.rect.height, greaterThan(80));
      final content = appearanceText(editing);
      expect(content, contains('0 1 -1 0'));
      expect(content, contains('(REVIEWED) Tj'));
    });
  });

  group('stamp tool in the viewer', () {
    testWidgets('create a stamp in the picker, then tap to place it',
        (tester) async {
      final editing = PdfEditingController(buildMultiPagePdf(1));
      final viewer = PdfViewerController();
      addTearDown(editing.dispose);
      addTearDown(viewer.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: editing,
            builder: (context, _) => PdfViewer(
              initialFit: PdfViewerFit.width,
              document: editing.document,
              controller: viewer,
              editing: editing,
            ),
          ),
          bottomNavigationBar: PdfEditingToolbar(
            controller: editing,
            viewerController: viewer,
          ),
        ),
      ));
      await tester.pump();

      final dockScrollable = find
          .descendant(
              of: find.byType(PdfEditingToolbar),
              matching: find.byType(Scrollable))
          .last;
      final stripScrollable = find
          .descendant(
              of: find.byType(PdfEditingToolbar),
              matching: find.byType(Scrollable))
          .first;
      // the Stamp tool lives in the Insert group's strip
      final insertChip = find.byKey(const ValueKey('pdf-group-insert'));
      await tester.scrollUntilVisible(insertChip, 80,
          scrollable: dockScrollable);
      await tester.tap(insertChip);
      await tester.pump();
      await tester.scrollUntilVisible(find.byTooltip('Stamp (S)'), 100,
          scrollable: stripScrollable);
      await tester.tap(find.byTooltip('Stamp (S)'));
      await tester.pumpAndSettle();
      expect(editing.tool, PdfEditTool.stamp);

      // the picker button only shows while the stamp tool is armed
      await tester.scrollUntilVisible(find.byTooltip('Custom stamps…'), 100,
          scrollable: stripScrollable);
      await tester.tap(find.byTooltip('Custom stamps…'));
      await tester.pumpAndSettle();
      expect(find.byType(PdfStampPickerDialog), findsOneWidget);

      await tester.tap(find.text('New stamp…'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('pdf-stamp-text')), 'PAID');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      // saving selects the new stamp and closes both dialogs
      expect(find.byType(PdfStampPickerDialog), findsNothing);
      expect(editing.customStamps.single.text, 'PAID');
      expect(editing.customStamps.single.template, isNotNull);
      expect(editing.activeStamp, editing.customStamps.single);

      // tap the page; the double-tap recognizer holds taps ~300ms
      await tester.tapAt(tester.getCenter(find.byType(PdfViewer)));
      await tester.pumpAndSettle(const Duration(milliseconds: 350));

      final stamp = editing.document.page(0).annotations.single;
      expect(stamp.subtype, 'Stamp');
      expect(stamp.contents, 'PAID');
      expect(appearanceText(editing), contains('(PAID) Tj'));
    });

    testWidgets('the stamp editor previews the stamp above the text field',
        (tester) async {
      PdfCustomStamp? saved;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () async {
                saved = await showPdfStampEditor(context);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final preview = find.byKey(const ValueKey('pdf-stamp-template-canvas'));
      final textField = find.byKey(const ValueKey('pdf-stamp-text'));
      expect(preview, findsOneWidget);
      expect(tester.getBottomLeft(preview).dy,
          lessThan(tester.getTopLeft(textField).dy));

      await tester.enterText(textField, 'PAID');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(saved, isNotNull);
      expect(saved!.text, 'PAID');
      expect(saved!.template, isNotNull);
      expect(
          saved!.template!.components
              .where((c) =>
                  c.type == PdfStampTemplateComponentType.text &&
                  c.text == 'PAID')
              .length,
          1);
    });

    testWidgets('stamp editor inserts template fields into text components',
        (tester) async {
      PdfCustomStamp? saved;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () async {
                saved = await showPdfStampEditor(context,
                    fields: const ['date', 'project']);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('pdf-stamp-field-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pdf-stamp-field-date')));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final text = saved!.template!.components
          .firstWhere((c) => c.type == PdfStampTemplateComponentType.text);
      expect(text.text, contains('{{date}}'));
    });

    testWidgets('stamp editor components can be moved and resized',
        (tester) async {
      PdfCustomStamp? saved;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () async {
                saved = await showPdfStampEditor(context);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final canvas = find.byKey(const ValueKey('pdf-stamp-template-canvas'));
      final rect = tester.getRect(canvas);
      final scale = rect.width / 240;
      final origin = rect.topLeft;
      final move = await tester.startGesture(
          origin + Offset(120 * scale, 48 * scale),
          kind: PointerDeviceKind.mouse);
      await move.moveBy(const Offset(18, 12));
      await move.up();
      await tester.pump();
      final resize = await tester.startGesture(
          origin + Offset(232 * scale, 75 * scale),
          kind: PointerDeviceKind.mouse);
      await resize.moveBy(const Offset(24, 12));
      await resize.up();
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final text = saved!.template!.components
          .firstWhere((c) => c.type == PdfStampTemplateComponentType.text);
      expect(text.x, greaterThan(20));
      expect(text.y, greaterThan(30));
      expect(text.width, greaterThan(200));
      expect(text.height, greaterThan(36));
    });

    testWidgets('the picker lists and deletes saved stamps', (tester) async {
      final editing = PdfEditingController(buildMultiPagePdf(1));
      addTearDown(editing.dispose);
      const paid = PdfCustomStamp(text: 'PAID', color: 0xC03030);
      editing
        ..saveCustomStamp(paid)
        ..activeStamp = paid;

      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => showPdfStampPicker(context, controller: editing),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(PdfStampPreview), findsOneWidget);

      await tester.tap(find.byTooltip('Delete stamp'));
      await tester.pumpAndSettle();
      expect(editing.customStamps, isEmpty);
      expect(find.byType(PdfStampPreview), findsNothing);
    });
  });
}
