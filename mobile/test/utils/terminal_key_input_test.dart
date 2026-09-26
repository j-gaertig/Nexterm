import 'package:flutter_test/flutter_test.dart';
import 'package:nexterm/utils/terminal_key_input.dart';

void main() {
  group('TerminalKeyInput.applyText', () {
    test('maps Ctrl+C, Ctrl+Z, and Ctrl+D to terminal control bytes', () {
      expect(TerminalKeyInput.applyText('c', ctrl: true, alt: false), '\x03');
      expect(TerminalKeyInput.applyText('z', ctrl: true, alt: false), '\x1a');
      expect(TerminalKeyInput.applyText('d', ctrl: true, alt: false), '\x04');
    });

    test('maps Ctrl with punctuation and number keys', () {
      expect(TerminalKeyInput.applyText(' ', ctrl: true, alt: false), '\x00');
      expect(TerminalKeyInput.applyText('[', ctrl: true, alt: false), '\x1b');
      expect(TerminalKeyInput.applyText('?', ctrl: true, alt: false), '\x7f');
    });

    test('prefixes Alt and combines Alt with Ctrl for one input', () {
      expect(TerminalKeyInput.applyText('x', ctrl: false, alt: true), '\x1bx');
      expect(TerminalKeyInput.applyText('c', ctrl: true, alt: true), '\x1b\x03');
      expect(TerminalKeyInput.applyText('!', ctrl: false, alt: true), '\x1b!');
    });

    test('leaves unmodified text unchanged and consumes only the first rune', () {
      expect(TerminalKeyInput.applyText('abc', ctrl: false, alt: false), 'abc');
      expect(TerminalKeyInput.applyText('cat', ctrl: true, alt: false), '\x03at');
    });
  });

  group('TerminalKeyInput.applyKey', () {
    test('keeps regular toolbar keys unchanged without modifiers', () {
      expect(TerminalKeyInput.applyKey('ESC', ctrl: false, alt: false), '\x1b');
      expect(TerminalKeyInput.applyKey('TAB', ctrl: false, alt: false), '\t');
      expect(TerminalKeyInput.applyKey('UP', ctrl: false, alt: false), '\x1b[A');
    });

    test('encodes modified cursor, navigation, and function keys', () {
      expect(TerminalKeyInput.applyKey('UP', ctrl: true, alt: false), '\x1b[1;5A');
      expect(TerminalKeyInput.applyKey('LEFT', ctrl: true, alt: true), '\x1b[1;7D');
      expect(TerminalKeyInput.applyKey('PGUP', ctrl: false, alt: true), '\x1b[5;3~');
      expect(TerminalKeyInput.applyKey('F1', ctrl: true, alt: false), '\x1b[1;5P');
    });
  });
}
