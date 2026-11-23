import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/ops_repository.dart';
import '../../data/synthetic_repository.dart';
import '../../models/app_user.dart';
import '../../state/providers.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets/brand.dart';
import '../widgets/kit.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});
  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirmation = TextEditingController();
  bool _show = false;
  bool _loading = false;
  bool _forgot = false;
  bool _sent = false;
  String? _error;
  String? _pwError;
  String? _recoveryError;
  bool _passwordUpdated = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _newPassword.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_loading) return;
    if (_password.text.isEmpty) {
      setState(() {
        _pwError = 'Enter your password.';
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _pwError = null;
    });
    try {
      final user = await ref.read(repositoryProvider).signIn(_email.text, _password.text);
      _password.clear();
      ref.read(sessionProvider.notifier).signIn(user);
    } on AuthFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      // Never leave the user on a silent screen.
      if (mounted) setState(() => _error = 'Sign-in failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _sendResetEmail() async {
    if (_loading) return;
    final email = _email.text.trim();
    if (!email.contains('@')) {
      setState(() => _recoveryError = 'Enter your email address.');
      return;
    }
    setState(() { _loading = true; _recoveryError = null; });
    try {
      await ref.read(repositoryProvider).requestPasswordReset(email);
      if (mounted) setState(() => _sent = true);
    } on AuthFailure catch (error) {
      if (mounted) setState(() => _recoveryError = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _finishReset() async {
    if (_loading) return;
    final password = _newPassword.text;
    if (password.length < 12 || password != _confirmation.text) {
      setState(() => _recoveryError = password.length < 12
          ? 'Use at least 12 characters.' : 'The passwords must match.');
      return;
    }
    setState(() { _loading = true; _recoveryError = null; });
    try {
      await ref.read(repositoryProvider).finishPasswordReset(password);
      if (mounted) {
        _newPassword.clear();
        _confirmation.clear();
        setState(() { _forgot = false; _sent = false; _passwordUpdated = true; });
      }
    } on AuthFailure catch (error) {
      if (mounted) setState(() => _recoveryError = error.message);
    } catch (_) {
      if (mounted) setState(() => _recoveryError = 'Could not complete the reset. Try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _fill(AppUser u, {bool wrong = false}) => setState(() {
        _email.text = u.email;
        _password.text = wrong ? 'wrong' : SyntheticRepository.demoPassword;
        _error = null;
        _pwError = null;
      });

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final repo = ref.watch(repositoryProvider);
    final recovering = ref.watch(passwordRecoveryProvider);
    return Scaffold(
      backgroundColor: t.nv,
      body: Column(children: [
        DemoStrip(background: t.nv, foreground: Colors.white),
        Expanded(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: MediaQuery.sizeOf(context).height - MediaQuery.paddingOf(context).top - 30),
              child: IntrinsicHeight(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 12, 28, 24),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const BrandLockup(onDark: true),
                      const SizedBox(height: 16),
                      const Text('Daily reports, deals, rent and payment approvals for Rotolo properties in one place.',
                          style: TextStyle(fontSize: 15, height: 1.5, color: NavColors.signInSub)),
                    ]),
                  ),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(color: t.bg, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
                      padding: EdgeInsets.fromLTRB(24, 24, 24, 32 + MediaQuery.paddingOf(context).bottom),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        if (recovering)
                          _newPasswordForm(t)
                        else if (_forgot)
                          _forgotForm(t, repo.isSynthetic)
                        else ...[
                          if (_passwordUpdated) const Text('Password updated. Sign in with your new password.'),
                          _signInForm(t, repo.demoUsers),
                        ],
                        const Spacer(),
                        const SizedBox(height: 16),
                        Text(
                            repo.isSynthetic
                                ? 'Demo data · No real tenant or financial records'
                                : 'Accounts are invite-only. Ask the owner for access.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12, color: t.mu)),
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _label(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(s, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      );

  Widget _signInForm(AppTokens t, List<AppUser> demo) {
    return AutofillGroup(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Sign in', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        if (_error != null) ...[
          Semantics(liveRegion: true, child: NoticeBox(tone: Tone.er, icon: Icons.error_rounded, text: _error!)),
          const SizedBox(height: 16),
        ],
        _label('Email'),
        TextField(
          key: const ValueKey('signin-email'),
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.username],
          autocorrect: false,
          textInputAction: TextInputAction.next,
          onChanged: (_) => setState(() => _error = null),
          style: const TextStyle(fontSize: 15),
        ),
        const SizedBox(height: 16),
        _label('Password'),
        TextField(
          key: const ValueKey('signin-password'),
          controller: _password,
          obscureText: !_show,
          autofillHints: const [AutofillHints.password],
          onChanged: (_) => setState(() {
            _pwError = null;
            _error = null;
          }),
          onSubmitted: (_) => _signIn(),
          style: const TextStyle(fontSize: 15),
          decoration: InputDecoration(
            errorText: _pwError,
            suffixIcon: IconButton(
              tooltip: _show ? 'Hide password' : 'Show password',
              icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined, color: t.mu),
              onPressed: () => setState(() => _show = !_show),
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          key: const ValueKey('signin-submit'),
          onPressed: _signIn,
          style: FilledButton.styleFrom(textStyle: const TextStyle(fontFamily: kSans, fontSize: 16, fontWeight: FontWeight.w600)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (_loading) ...[
              SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: t.onac)),
              const SizedBox(width: 8),
            ],
            Text(_loading ? 'Signing in…' : 'Sign in'),
          ]),
        ),
        Center(
          child: TextButton(
              onPressed: () => setState(() {
                    _forgot = true;
                    _sent = false;
                    _recoveryError = null;
                    _passwordUpdated = false;
                    _error = null;
                  }),
              child: const Text('Forgot password?')),
        ),
        if (demo.isNotEmpty) ...[
          Divider(color: t.bd),
          const SizedBox(height: 10),
          Text('Demo accounts', style: TextStyle(fontSize: 12, color: t.mu)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final u in demo)
              _demoChip(t, '${u.roleLabel} · ${u.firstName}', ValueKey('signin-${u.id}'), () => _fill(u)),
            _demoChip(t, 'Wrong password', const ValueKey('signin-wrong'), () => _fill(demo.first, wrong: true)),
          ]),
        ],
      ]),
    );
  }

  Widget _demoChip(AppTokens t, String label, Key key, VoidCallback onTap) => Material(
        key: key,
        color: t.sf,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999), side: BorderSide(color: t.bd)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(widthFactor: 1, child: Text(label, style: TextStyle(fontSize: 13, color: t.tx))),
          ),
        ),
      );

  Widget _forgotForm(AppTokens t, bool demo) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Reset password', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
      const SizedBox(height: 16),
      if (_sent)
        NoticeBox(tone: Tone.ac, icon: Icons.info_outline_rounded,
          text: demo ? 'Demo mode does not send email.' :
            'If the address has an account, you’ll get a reset link. Open it on this device.'),
      if (!_sent) ...[
        TextField(controller: _email, keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'Account email')),
        if (_recoveryError != null) Text(_recoveryError!, style: TextStyle(color: t.er)),
        const SizedBox(height: 16),
        FilledButton(onPressed: _loading ? null : _sendResetEmail,
          child: Text(_loading ? 'Sending…' : 'Send reset link')),
      ],
      const SizedBox(height: 16),
      OutlinedButton(onPressed: _loading ? null : () => setState(() => _forgot = false),
        child: const Text('Back to sign in')),
    ]);
  }

  Widget _newPasswordForm(AppTokens t) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    const Text('Choose a new password', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
    const SizedBox(height: 12),
    TextField(controller: _newPassword, obscureText: true, decoration: const InputDecoration(labelText: 'New password')),
    const SizedBox(height: 12),
    TextField(controller: _confirmation, obscureText: true, decoration: const InputDecoration(labelText: 'Confirm new password')),
    if (_recoveryError != null) Text(_recoveryError!, style: TextStyle(color: t.er)),
    const SizedBox(height: 16),
    FilledButton(onPressed: _loading ? null : _finishReset, child: const Text('Update password')),
    TextButton(onPressed: _loading ? null : () async {
      try {
        await ref.read(repositoryProvider).signOut();
      } catch (_) {
        if (mounted) setState(() => _recoveryError = 'Could not end the recovery session. Try again.');
      }
    }, child: const Text('Cancel')),
  ]);
}
