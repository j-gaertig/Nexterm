import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexterm/models/server.dart';
import 'package:nexterm/screens/renderers/terminal_renderer.dart';
import 'package:nexterm/services/session_manager.dart';
import 'package:nexterm/utils/ai_manager.dart';
import 'package:nexterm/utils/snippet_manager.dart';
import 'package:nexterm/utils/terminal_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('uses a line cursor and advances through echoed terminal text', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await TerminalSettings.load();
    final terminal = Terminal(maxLines: 100);
    final session = AppSession(
      sessionId: 'test-session',
      server: const Server(name: 'Test server', ip: '127.0.0.1'),
      type: ConnectionType.terminal,
      terminal: terminal,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 800,
          height: 600,
          child: TerminalRenderer(
            session: session,
            token: 'test-token',
            sessionManager: SessionManager(),
            snippetManager: SnippetManager(),
            terminalSettings: settings,
            aiManager: AIManager(),
          ),
        ),
      ),
    );

    final terminalView = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(terminalView.cursorType, TerminalCursorType.verticalBar);
    expect(terminalView.keyboardType, TextInputType.visiblePassword);

      terminal.write('first');
    expect(terminal.buffer.cursorX, 5);
    terminal.write(' ');
    expect(terminal.buffer.cursorX, 6);
    terminal.write('word!');
    expect(terminal.buffer.cursorX, 11);
    terminal.write('\r\n');
    expect(terminal.buffer.cursorX, 0);
    expect(terminal.buffer.cursorY, 1);

    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox.shrink());
    settings.dispose();
  });
}
