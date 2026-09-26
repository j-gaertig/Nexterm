import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('paints the vertical cursor at its terminal row offset', () async {
    final painter = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    const cursorOffset = ui.Offset(12, 36);

    painter.paintCursor(
      canvas,
      cursorOffset,
      cursorType: TerminalCursorType.verticalBar,
    );

    final image = await recorder.endRecording().toImage(48, 72);
    final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(_alphaAt(pixels!, width: 48, x: 12, y: 36), greaterThan(0));
    expect(_alphaAt(pixels, width: 48, x: 12, y: 0), 0);
    image.dispose();
  });
}

int _alphaAt(
  ByteData data, {
  required int width,
  required int x,
  required int y,
}) =>
    data.getUint8((y * width + x) * 4 + 3);
