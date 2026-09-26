class TerminalKeyInput {
  const TerminalKeyInput._();

  static String applyText(
    String text, {
    required bool ctrl,
    required bool alt,
  }) {
    if (text.isEmpty || (!ctrl && !alt)) return text;

    final runes = text.runes.toList(growable: false);
    final first = runes.first;
    final modified = ctrl ? _controlCode(first) ?? first : first;
    final prefix = alt ? '\x1b' : '';
    return '$prefix${String.fromCharCode(modified)}${String.fromCharCodes(runes.skip(1))}';
  }

  static String applyKey(
    String key, {
    required bool ctrl,
    required bool alt,
  }) {
    if (key.length == 1) return applyText(key, ctrl: ctrl, alt: alt);

    final base = _baseKeySequence(key);
    if (base == null) return '';
    if (!ctrl && !alt) return base;

    final modifier = 1 + (alt ? 2 : 0) + (ctrl ? 4 : 0);
    final finalCharacter = base.codeUnitAt(base.length - 1);

    if (base.startsWith('\x1b[') &&
        const {0x41, 0x42, 0x43, 0x44, 0x46, 0x48}.contains(finalCharacter)) {
      return '\x1b[1;$modifier${String.fromCharCode(finalCharacter)}';
    }

    if (base.startsWith('\x1bO') &&
        const {0x50, 0x51, 0x52, 0x53}.contains(finalCharacter)) {
      return '\x1b[1;$modifier${String.fromCharCode(finalCharacter)}';
    }

    final tildeIndex = base.indexOf('~');
    if (base.startsWith('\x1b[') && tildeIndex == base.length - 1) {
      return '${base.substring(0, tildeIndex)};$modifier~';
    }

    if (key == 'TAB') return alt ? '\x1b\t' : '\t';

    return '${alt ? '\x1b' : ''}$base';
  }

  static int? _controlCode(int code) {
    if ((code >= 0x40 && code <= 0x5f) ||
        (code >= 0x61 && code <= 0x7a)) {
      return code & 0x1f;
    }

    switch (code) {
      case 0x20:
      case 0x32:
        return 0x00;
      case 0x33:
        return 0x1b;
      case 0x34:
        return 0x1c;
      case 0x35:
        return 0x1d;
      case 0x36:
        return 0x1e;
      case 0x37:
        return 0x1f;
      case 0x38:
      case 0x3f:
        return 0x7f;
      default:
        return null;
    }
  }

  static String? _baseKeySequence(String key) {
    switch (key) {
      case 'ESC': return '\x1b';
      case 'TAB': return '\t';
      case 'UP': return '\x1b[A';
      case 'DOWN': return '\x1b[B';
      case 'RIGHT': return '\x1b[C';
      case 'LEFT': return '\x1b[D';
      case 'HOME': return '\x1b[H';
      case 'END': return '\x1b[F';
      case 'PGUP': return '\x1b[5~';
      case 'PGDN': return '\x1b[6~';
      case 'F1': return '\x1bOP';
      case 'F2': return '\x1bOQ';
      case 'F3': return '\x1bOR';
      case 'F4': return '\x1bOS';
      case 'F5': return '\x1b[15~';
      case 'F6': return '\x1b[17~';
      case 'F7': return '\x1b[18~';
      case 'F8': return '\x1b[19~';
      case 'F9': return '\x1b[20~';
      case 'F10': return '\x1b[21~';
      case 'F11': return '\x1b[23~';
      case 'F12': return '\x1b[24~';
      default: return null;
    }
  }
}
