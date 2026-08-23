/// Signing in.
///
/// The screen is careful about one thing above all: not implying that signing
/// in is what creates or holds the wallet. It does not. The wallet is made on
/// this device and stays there, and the copy says so, because a user who
/// thinks Google is holding their money will make decisions that cost them.
library;

import 'package:flutter/material.dart';

import '../auth/auth_service.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({
    super.key,
    required this.auth,
    required this.onSignedIn,
  });

  final AuthService auth;
  final VoidCallback onSignedIn;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

enum _Step { choose, email, code }

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();

  _Step _step = _Step.choose;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _email.addListener(() => setState(() {}));
    _code.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on AuthFailure catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _oauth(AuthMethod method) => _run(() async {
        await widget.auth.signInWith(method);
        // The provider takes over from here and comes back through the app's
        // own scheme. The session arrives on the auth stream, not from this
        // call, so there is nothing to await.
      });

  Future<void> _sendCode() => _run(() async {
        await widget.auth.sendEmailCode(_email.text);
        if (mounted) setState(() => _step = _Step.code);
      });

  Future<void> _verify() => _run(() async {
        await widget.auth.verifyEmailCode(
          email: _email.text,
          code: _code.text,
        );
        if (mounted) widget.onSignedIn();
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: _step == _Step.choose
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() {
                  _step = _step == _Step.code ? _Step.email : _Step.choose;
                  _error = null;
                }),
              ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(TipTheme.spaceLg),
          child: switch (_step) {
            _Step.choose => _choose(),
            _Step.email => _emailStep(),
            _Step.code => _codeStep(),
          },
        ),
      ),
    );
  }

  Widget _choose() {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: TipTheme.spaceLg),
        Text('Sign in', style: text.displayLarge),
        const SizedBox(height: TipTheme.spaceSm),
        Text(
          'So your wallet can follow you to another phone, and so people can '
          'tip you by name instead of by address.',
          style: text.bodyMedium,
        ),
        const SizedBox(height: TipTheme.spaceXl),

        _Provider(
          icon: Icons.g_mobiledata_rounded,
          label: 'Continue with Google',
          onTap: _busy ? null : () => _oauth(AuthMethod.google),
        ),
        const SizedBox(height: TipTheme.spaceSm),
        _Provider(
          icon: Icons.close_rounded,
          label: 'Continue with X',
          onTap: _busy ? null : () => _oauth(AuthMethod.x),
        ),
        const SizedBox(height: TipTheme.spaceSm),
        _Provider(
          icon: Icons.alternate_email_rounded,
          label: 'Continue with email',
          onTap: _busy ? null : () => setState(() => _step = _Step.email),
        ),

        if (_error != null) ...[
          const SizedBox(height: TipTheme.spaceMd),
          _Problem(message: _error!),
        ],

        const SizedBox(height: TipTheme.spaceXl),
        const _KeysStayHere(),
      ],
    );
  }

  Widget _emailStep() {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Your email', style: text.displayLarge),
        const SizedBox(height: TipTheme.spaceSm),
        Text('We will send a six digit code.', style: text.bodyMedium),
        const SizedBox(height: TipTheme.spaceXl),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(hintText: 'you@example.com'),
        ),
        if (_error != null) ...[
          const SizedBox(height: TipTheme.spaceMd),
          _Problem(message: _error!),
        ],
        const SizedBox(height: TipTheme.spaceXl),
        FilledButton(
          onPressed: _email.text.isEmpty || _busy ? null : _sendCode,
          child: _busy ? const _Spinner() : const Text('Send the code'),
        ),
      ],
    );
  }

  Widget _codeStep() {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Check your email', style: text.displayLarge),
        const SizedBox(height: TipTheme.spaceSm),
        Text('We sent a code to ${_email.text}.', style: text.bodyMedium),
        const SizedBox(height: TipTheme.spaceXl),
        TextField(
          controller: _code,
          keyboardType: TextInputType.number,
          autocorrect: false,
          enableSuggestions: false,
          style: text.headlineMedium,
          textAlign: TextAlign.center,
          decoration: const InputDecoration(hintText: '000000'),
        ),
        if (_error != null) ...[
          const SizedBox(height: TipTheme.spaceMd),
          _Problem(message: _error!),
        ],
        const SizedBox(height: TipTheme.spaceXl),
        FilledButton(
          onPressed: _code.text.length < 6 || _busy ? null : _verify,
          child: _busy ? const _Spinner() : const Text('Sign in'),
        ),
        const SizedBox(height: TipTheme.spaceSm),
        TextButton(
          onPressed: _busy ? null : _sendCode,
          child: const Text('Send another code'),
        ),
      ],
    );
  }
}

/// The one thing this screen must never let a user misunderstand.
class _KeysStayHere extends StatelessWidget {
  const _KeysStayHere();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(TipTheme.spaceMd),
      decoration: BoxDecoration(
        color: TipPalette.accentWash,
        borderRadius: BorderRadius.circular(TipTheme.radiusLarge),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.key_outlined, size: 18, color: TipPalette.accentDeep),
          const SizedBox(width: TipTheme.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Signing in does not hold your money',
                  style: text.titleSmall
                      ?.copyWith(color: TipPalette.accentDeep),
                ),
                const SizedBox(height: 4),
                Text(
                  'Your keys are made on this phone and stay on it. Nobody '
                  'signing in as you can move your funds without them.',
                  style: text.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Provider extends StatelessWidget {
  const _Provider({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 20),
      label: Align(
        alignment: Alignment.centerLeft,
        child: Text(label),
      ),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(
          horizontal: TipTheme.spaceMd,
          vertical: TipTheme.spaceMd,
        ),
      ),
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(TipTheme.spaceMd),
      decoration: BoxDecoration(
        color: TipPalette.negative.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(TipTheme.radiusSmall),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 18, color: TipPalette.negative),
          const SizedBox(width: TipTheme.spaceSm),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: TipPalette.negative),
            ),
          ),
        ],
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
        height: 18,
        width: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
      );
}
