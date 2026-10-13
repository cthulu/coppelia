import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/saved_server.dart';
import '../../state/app_state.dart';

/// Keeps server failures visible even while cached library content is shown.
class ServerErrorBanner extends StatelessWidget {
  const ServerErrorBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final needsSignIn = state.needsSignIn;
    if (!needsSignIn && state.libraryError == null) {
      return const SizedBox.shrink();
    }
    final serverName = state.activeServer?.name ?? 'your server';
    final message = needsSignIn
        ? 'Sign in again to $serverName.'
        : 'Could not refresh $serverName.';
    return SafeArea(
      bottom: false,
      child: MaterialBanner(
        content: Tooltip(
          message: state.libraryError ?? message,
          child: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
        leading: const Icon(Icons.error_outline, size: 20),
        padding: const EdgeInsetsDirectional.only(start: 16),
        leadingPadding: const EdgeInsetsDirectional.only(end: 8),
        actions: [
          TextButton(
            onPressed: needsSignIn
                ? () => showServerSignIn(context)
                : state.isLoadingLibrary
                    ? null
                    : state.refreshLibrary,
            child: Text(needsSignIn ? 'Sign in again' : 'Retry'),
          ),
        ],
      ),
    );
  }
}

Future<void> showServerSignIn(BuildContext context,
    {SavedServer? server}) async {
  final state = context.read<AppState>();
  final saved = server ?? state.activeServer;
  if (saved == null) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ServerSignInDialog(state: state, server: saved),
  );
}

class _ServerSignInDialog extends StatefulWidget {
  const _ServerSignInDialog({required this.state, required this.server});
  final AppState state;
  final SavedServer server;

  @override
  State<_ServerSignInDialog> createState() => _ServerSignInDialogState();
}

class _ServerSignInDialogState extends State<_ServerSignInDialog> {
  String _password = '';
  String? _error;
  bool _submitting = false;

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final signedIn = await widget.state
        .reauthenticateServer(widget.server, password: _password);
    if (!mounted) return;
    if (signedIn) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _submitting = false;
        _error = widget.state.authError ?? 'Could not sign in. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_submitting,
        child: AlertDialog(
          title: Text('Sign in to ${widget.server.name}'),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.server.userName),
                  Text(widget.server.activeAddress.url),
                  const SizedBox(height: 16),
                  TextField(
                    autofocus: true,
                    enabled: !_submitting,
                    obscureText: true,
                    onChanged: (value) => _password = value,
                    onSubmitted: (_) => _submit(),
                    decoration:
                        const InputDecoration(labelText: 'Password (optional)'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: _submitting ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: _submitting ? null : _submit,
              child: Text(_submitting ? 'Signing in…' : 'Sign in'),
            ),
          ],
        ),
      );
}
