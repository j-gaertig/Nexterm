import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_material_design_icons/flutter_material_design_icons.dart';
import 'package:web_socket_channel/io.dart';
import 'package:xterm/xterm.dart';

import '../../services/session_manager.dart';
import '../../utils/ai_manager.dart';
import '../../utils/snippet_manager.dart';
import '../../utils/terminal_key_input.dart';
import '../../utils/terminal_settings.dart';
import '../widgets/ai_assistant_sheet.dart';
import '../widgets/connection_loader.dart';

class TerminalRenderer extends StatefulWidget {
  final AppSession session;
  final String token;
  final SessionManager sessionManager;
  final SnippetManager snippetManager;
  final TerminalSettings terminalSettings;
  final AIManager aiManager;
  final VoidCallback? onDisconnected;

  const TerminalRenderer({
    super.key,
    required this.session,
    required this.token,
    required this.sessionManager,
    required this.snippetManager,
    required this.terminalSettings,
    required this.aiManager,
    this.onDisconnected,
  });

  @override
  State<TerminalRenderer> createState() => _TerminalRendererState();
}

class _TerminalRendererState extends State<TerminalRenderer> {
  Terminal get _terminal => widget.session.terminal!;
  IOWebSocketChannel? get _channel => widget.session.termChannel;
  bool _connected = false;
  bool _receivedData = false;
  String? _errorMessage;
  final FocusNode _terminalFocusNode = FocusNode();
  bool _showKeyboardToolbar = false;
  bool _ctrlPressed = false;
  bool _altPressed = false;
  bool _initialized = false;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;

  @override
  void initState() {
    super.initState();
    _terminalFocusNode.addListener(_onFocusChanged);
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    widget.session.showSnippets = _showSnippets;
    widget.session.showAI = _showAISheet;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.session.onCallbacksReady?.call();
    });
    _setupTerminal();
  }

  void _onFocusChanged() {
    if (mounted) setState(() => _showKeyboardToolbar = _terminalFocusNode.hasFocus);
  }

  bool _handleHardwareKey(KeyEvent event) {
    if (!mounted ||
        !_terminalFocusNode.hasFocus ||
        (!_ctrlPressed && !_altPressed) ||
        event is! KeyDownEvent) {
      return false;
    }

    final key = _hardwareKeyName(event);
    if (key == null) return false;
    _sendTerminalKey(key);
    return true;
  }

  String? _hardwareKeyName(KeyDownEvent event) {
    final character = event.character;
    if (character != null && character.isNotEmpty) return character;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) return 'ESC';
    if (key == LogicalKeyboardKey.tab) return 'TAB';
    if (key == LogicalKeyboardKey.arrowUp) return 'UP';
    if (key == LogicalKeyboardKey.arrowDown) return 'DOWN';
    if (key == LogicalKeyboardKey.arrowLeft) return 'LEFT';
    if (key == LogicalKeyboardKey.arrowRight) return 'RIGHT';
    if (key == LogicalKeyboardKey.home) return 'HOME';
    if (key == LogicalKeyboardKey.end) return 'END';
    if (key == LogicalKeyboardKey.pageUp) return 'PGUP';
    if (key == LogicalKeyboardKey.pageDown) return 'PGDN';
    if (key == LogicalKeyboardKey.f1) return 'F1';
    if (key == LogicalKeyboardKey.f2) return 'F2';
    if (key == LogicalKeyboardKey.f3) return 'F3';
    if (key == LogicalKeyboardKey.f4) return 'F4';
    if (key == LogicalKeyboardKey.f5) return 'F5';
    if (key == LogicalKeyboardKey.f6) return 'F6';
    if (key == LogicalKeyboardKey.f7) return 'F7';
    if (key == LogicalKeyboardKey.f8) return 'F8';
    if (key == LogicalKeyboardKey.f9) return 'F9';
    if (key == LogicalKeyboardKey.f10) return 'F10';
    if (key == LogicalKeyboardKey.f11) return 'F11';
    if (key == LogicalKeyboardKey.f12) return 'F12';
    return null;
  }

  void _setupTerminal() {
    if (_initialized) return;
    _initialized = true;

    _terminal.onOutput = (data) {
      if (!mounted || _channel == null) return;
      _sendTerminalText(data);
    };

    _terminal.onResize = (w, h, _, __) {
      if (mounted && _connected && _channel != null) {
        _channel?.sink.add('\x01$w,$h');
      }
    };

    if (widget.session.termSubscription == null) {
      widget.session.termSubscription = _channel?.stream.listen(
        (data) {
          if (!_receivedData && mounted) {
            setState(() => _receivedData = true);
          }
          if (data is String) {
            _terminal.write(data.startsWith('\x02') ? data.substring(1) : data);
          }
        },
        onError: (error) {
          if (mounted) setState(() { _errorMessage = 'Connection error: $error'; _connected = false; });
          widget.session.isConnected = false;
          _attemptReconnect();
        },
        onDone: () {
          if (mounted) setState(() => _connected = false);
          widget.session.isConnected = false;
          _attemptReconnect();
        },
      );

      if (mounted) setState(() => _connected = true);
      widget.session.isConnected = true;
      _reconnectAttempts = 0;

      Future.delayed(const Duration(milliseconds: 100), () {
        if (_channel == null) return;
        _channel?.sink.add(_terminal.viewHeight > 0 && _terminal.viewWidth > 0
            ? '\x01${_terminal.viewWidth},${_terminal.viewHeight}'
            : '\x0180,30');
      });
    } else {
      _connected = widget.session.isConnected;
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    _terminalFocusNode.removeListener(_onFocusChanged);
    _terminalFocusNode.dispose();
    super.dispose();
  }

  Future<void> _attemptReconnect() async {
    if (!mounted || _reconnectAttempts >= _maxReconnectAttempts) {
      widget.onDisconnected?.call();
      return;
    }

    _reconnectAttempts++;
    final delay = Duration(seconds: _reconnectAttempts.clamp(1, 5));
    await Future.delayed(delay);

    if (!mounted) return;

    final success = await widget.sessionManager.reconnectTerminalSession(
      token: widget.token,
      session: widget.session,
    );

    if (!mounted) return;

    if (success) {
      _initialized = false;
      widget.session.termSubscription = null;
      setState(() {
        _errorMessage = null;
        _receivedData = false;
      });
      _setupTerminal();
    } else {
      _attemptReconnect();
    }
  }

  void _sendSpecialKey(String key) {
    switch (key) {
      case 'CTRL': if (mounted) setState(() => _ctrlPressed = !_ctrlPressed); return;
      case 'ALT': if (mounted) setState(() => _altPressed = !_altPressed); return;
      default: _sendTerminalKey(key); return;
    }
  }

  void _sendFunctionKey(int n) {
    _sendTerminalKey('F$n');
  }

  void _sendTerminalText(String text) {
    final ctrl = _ctrlPressed;
    final alt = _altPressed;
    _channel?.sink.add(TerminalKeyInput.applyText(text, ctrl: ctrl, alt: alt));
    _clearModifiers();
  }

  void _sendTerminalKey(String key, {bool forceCtrl = false}) {
    final ctrl = forceCtrl || _ctrlPressed;
    final alt = _altPressed;
    final data = TerminalKeyInput.applyKey(key, ctrl: ctrl, alt: alt);
    if (data.isEmpty) return;
    _channel?.sink.add(data);
    _clearModifiers();
  }

  void _clearModifiers() {
    if (_ctrlPressed || _altPressed) {
      if (mounted) {
        setState(() {
          _ctrlPressed = false;
          _altPressed = false;
        });
      } else {
        _ctrlPressed = false;
        _altPressed = false;
      }
    }
  }

  void _showAISheet() {
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => AIAssistantSheet(
        token: widget.token,
        sessionId: widget.session.sessionId,
        serverName: widget.session.server.name,
      ),
    );
  }

  void _showSnippets() {
    if (!mounted) return;
    final sm = widget.snippetManager;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      clipBehavior: Clip.antiAliasWithSaveLayer,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7, minChildSize: 0.5, maxChildSize: 0.95, expand: false,
        builder: (ctx, scrollController) {
          if (sm.isLoading) return const Center(child: CircularProgressIndicator());
          if (sm.error != null) {
            return Center(child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(MdiIcons.alertCircleOutline, size: 48, color: Theme.of(ctx).colorScheme.error),
                const SizedBox(height: 16),
                Text('Failed to load snippets', style: Theme.of(ctx).textTheme.titleMedium),
              ]),
            ));
          }
          if (sm.snippets.isEmpty) {
            return Center(child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(MdiIcons.codeBracesBox, size: 48, color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                const SizedBox(height: 16),
                Text('No snippets available', style: Theme.of(ctx).textTheme.titleMedium),
              ]),
            ));
          }
          return Column(children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surface,
                border: Border(bottom: BorderSide(color: Theme.of(ctx).colorScheme.outlineVariant)),
              ),
              child: Row(children: [
                Icon(MdiIcons.codeBraces, color: Theme.of(ctx).colorScheme.primary),
                const SizedBox(width: 12),
                Text('Snippets', style: Theme.of(ctx).textTheme.titleLarge),
                const Spacer(),
                IconButton(icon: Icon(MdiIcons.close), onPressed: () => Navigator.pop(ctx)),
              ]),
            ),
            Expanded(child: ListView.builder(
              controller: scrollController,
              itemCount: sm.snippets.length,
              itemBuilder: (ctx, i) {
                final s = sm.snippets[i];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Theme.of(ctx).colorScheme.primaryContainer,
                    child: Icon(MdiIcons.console, color: Theme.of(ctx).colorScheme.onPrimaryContainer, size: 20),
                  ),
                  title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: s.description != null ? Text(s.description!, maxLines: 2, overflow: TextOverflow.ellipsis) : null,
                  trailing: Icon(MdiIcons.chevronRight, size: 16),
                  onTap: () { Navigator.pop(ctx); _channel?.sink.add(s.command); },
                );
              },
            )),
          ]);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.terminalSettings,
      builder: (context, child) {
        return Stack(
          children: [
            Positioned.fill(
              child: Column(
                children: [
                  if (_errorMessage != null) _errorBanner(),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => _terminalFocusNode.requestFocus(),
                      child: TerminalView(
                        _terminal,
                        theme: widget.terminalSettings.colorTheme.theme,
                        textStyle: TerminalStyle(
                          fontSize: widget.terminalSettings.fontSize,
                          fontFamily: GoogleFonts.jetBrainsMono().fontFamily ?? 'monospace',
                          height: 1.2,
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        focusNode: _terminalFocusNode,
                        autofocus: true,
                        deleteDetection: Platform.isIOS,
                      ),
                    ),
                  ),
                  if (_showKeyboardToolbar) _buildKeyboardToolbar(),
                ],
              ),
            ),
            Positioned.fill(
              child: ConnectionLoader(visible: !_receivedData && _errorMessage == null),
            ),
          ],
        );
      },
    );
  }

  Widget _errorBanner() {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity, padding: const EdgeInsets.all(8), color: colors.errorContainer,
      child: Row(children: [
        Icon(MdiIcons.alertCircleOutline, color: colors.onErrorContainer),
        const SizedBox(width: 8),
        Expanded(child: Text(_errorMessage!, style: TextStyle(color: colors.onErrorContainer))),
        IconButton(icon: Icon(MdiIcons.close), onPressed: () => setState(() => _errorMessage = null), color: colors.onErrorContainer),
      ]),
    );
  }

  Widget _buildKeyboardToolbar() {
    final ts = widget.terminalSettings;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 8, offset: const Offset(0, -2))],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              _toolbarBtn('ESC'), const SizedBox(width: 8),
              _toolbarBtn('TAB'), const SizedBox(width: 8),
              for (final group in ts.groupOrder)
                if (ts.isGroupEnabled(group)) ..._buildGroupButtons(group),
            ]),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildGroupButtons(ToolbarGroup group) {
    switch (group) {
      case ToolbarGroup.modifiers:
        return [
          _toolbarBtn('CTRL', isToggle: true, isActive: _ctrlPressed), const SizedBox(width: 8),
          _toolbarBtn('ALT', isToggle: true, isActive: _altPressed), const SizedBox(width: 16),
        ];
      case ToolbarGroup.signals:
        return [
          _toolbarBtn('^C', onPressed: () => _sendTerminalKey('c', forceCtrl: true), compact: true), const SizedBox(width: 8),
          _toolbarBtn('^Z', onPressed: () => _sendTerminalKey('z', forceCtrl: true), compact: true), const SizedBox(width: 8),
          _toolbarBtn('^D', onPressed: () => _sendTerminalKey('d', forceCtrl: true), compact: true), const SizedBox(width: 16),
        ];
      case ToolbarGroup.arrows:
        return [
          _toolbarBtn('↑', onPressed: () => _sendSpecialKey('UP'), compact: true), const SizedBox(width: 8),
          _toolbarBtn('↓', onPressed: () => _sendSpecialKey('DOWN'), compact: true), const SizedBox(width: 8),
          _toolbarBtn('←', onPressed: () => _sendSpecialKey('LEFT'), compact: true), const SizedBox(width: 8),
          _toolbarBtn('→', onPressed: () => _sendSpecialKey('RIGHT'), compact: true), const SizedBox(width: 16),
        ];
      case ToolbarGroup.navigation:
        return [
          _toolbarBtn('HOME', compact: true), const SizedBox(width: 8),
          _toolbarBtn('END', compact: true), const SizedBox(width: 8),
          _toolbarBtn('PGUP', compact: true), const SizedBox(width: 8),
          _toolbarBtn('PGDN', compact: true), const SizedBox(width: 16),
        ];
      case ToolbarGroup.functionKeys:
        return [
          for (int i = 1; i <= 12; i++) ...[
            _toolbarBtn('F$i', onPressed: () => _sendFunctionKey(i), compact: true),
            if (i < 12) const SizedBox(width: 8),
          ],
        ];
    }
  }

  Widget _toolbarBtn(String label, {VoidCallback? onPressed, bool isToggle = false, bool isActive = false, bool compact = false}) {
    final theme = Theme.of(context);
    final bgColor = isActive ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest;
    final fgColor = isActive ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;
    return Material(
      color: bgColor, borderRadius: BorderRadius.circular(12), elevation: isActive ? 2 : 0,
      child: InkWell(
        onTap: onPressed ?? () => _sendSpecialKey(label),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: BoxConstraints(minWidth: compact ? 44 : 56, minHeight: 44),
          padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16, vertical: 10),
          child: Center(child: Text(label, style: TextStyle(fontSize: compact ? 13 : 14, fontWeight: FontWeight.w600, color: fgColor))),
        ),
      ),
    );
  }
}
