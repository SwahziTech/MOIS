import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'core/offline.dart';
import 'core/session.dart';
import 'core/theme.dart';
import 'core/ui.dart';
import 'shell.dart';

/*
 * MOIS — the native app (2026-11-23): the web app's pages on Android and iPhone, offline.
 *   flutter run --dart-define-from-file=env.json   (env.json: SUPABASE_URL, SUPABASE_ANON_KEY)
 */
const _url = String.fromEnvironment('SUPABASE_URL');
const _key = String.fromEnvironment('SUPABASE_ANON_KEY');
const webUrl = String.fromEnvironment('WEB_URL', defaultValue: 'https://mois.swahzitech.workers.dev');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: _url, publishableKey: _key);
  await offline.start();
  runApp(const MoisApp());
}

class MoisApp extends StatelessWidget {
  const MoisApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'MOIS',
        debugShowCheckedModeBanner: false,
        theme: appTheme(Brightness.light),
        darkTheme: appTheme(Brightness.dark),
        home: const _AuthGate(),
      );
}

class _AuthGate extends StatefulWidget {
  const _AuthGate();
  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  StreamSubscription<AuthState>? _sub;
  String? _for;

  @override
  void initState() {
    super.initState();
    _sub = db.auth.onAuthStateChange.listen((s) {
      final uid = s.session?.user.id;
      if (uid == null) {
        _for = null;
        session.clear();
      } else if (uid != _for) {
        _for = uid;
        session.load();
        offline.sync();
      }
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() { _sub?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    if (db.auth.currentSession == null) return const LoginPage();
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        if (session.error.isNotEmpty) {
          return Scaffold(body: Center(child: ErrorState(session.error, onRetry: session.load)));
        }
        if (!session.ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        return const Shell();
      },
    );
  }
}

/// The MOIS mark (web components/AuthBrand.jsx): khaki square, two coffee squares
class MoisMark extends StatelessWidget {
  const MoisMark({super.key, this.size = 40});
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox(width: size, height: size, child: CustomPaint(painter: _MarkPainter()));
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final k = s.width / 40;
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & s, Radius.circular(6 * k)), Paint()..color = C.khaki);
    final p = Paint()..color = C.coffee;
    canvas.drawRect(Rect.fromLTWH(11 * k, 11 * k, 6 * k, 6 * k), p);
    canvas.drawRect(Rect.fromLTWH(22 * k, 22 * k, 6 * k, 6 * k), p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/*
 * Sign in (web pages/auth/Login.jsx): MOIS brand only — never a company's name before sign-in;
 * email or username (a username signs in with its hidden address, migration 100).
 */
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false, _show = false;
  String _error = '';

  String get _authEmail {
    final t = _email.text.trim();
    return t.contains('@') ? t : '${t.toLowerCase()}@users.mois.invalid';
  }

  Future<void> _signIn() async {
    if (_email.text.trim().isEmpty || _password.text.isEmpty) { setState(() => _error = 'Enter your email or username and password.'); return; }
    setState(() { _busy = true; _error = ''; });
    try {
      await db.auth.signInWithPassword(email: _authEmail, password: _password.text);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message.toLowerCase().contains('invalid') ? 'Wrong email/username or password.' : e.message);
    } catch (e) {
      if (mounted) setState(() => _error = isOffline(e) ? 'No connection — signing in needs the internet the first time.' : 'Something went wrong. Please try again.');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  void dispose() { _email.dispose(); _password.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    Widget label(String s) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(s, style: TextStyle(fontSize: Fs.sm, fontWeight: FontWeight.w500, color: t.textSecondary)));
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: AutofillGroup(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    const MoisMark(),
                    const SizedBox(width: 10),
                    Text('MOIS', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: t.textPrimary)),
                  ]),
                  const SizedBox(height: 28),
                  const Text('Sign in', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text('Manufacturing Operating Intelligent System', style: TextStyle(color: t.textMuted, fontSize: Fs.sm)),
                  const SizedBox(height: 24),
                  label('Email or username'),
                  TextField(controller: _email, keyboardType: TextInputType.emailAddress, autocorrect: false,
                      autofillHints: const [AutofillHints.email, AutofillHints.username],
                      decoration: const InputDecoration(hintText: 'you@example.com or username')),
                  const SizedBox(height: 14),
                  label('Password'),
                  TextField(
                    controller: _password, obscureText: !_show, autofillHints: const [AutofillHints.password], onSubmitted: (_) => _signIn(),
                    decoration: InputDecoration(
                      hintText: 'Enter your password',
                      suffixIcon: IconButton(tooltip: _show ? 'Hide password' : 'Show password', icon: Icon(_show ? LucideIcons.eyeOff : LucideIcons.eye, size: 18), onPressed: () => setState(() => _show = !_show)),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(onPressed: () => launchUrl(Uri.parse('$webUrl/forgot-password'), mode: LaunchMode.externalApplication), child: const Text('Forgot password?')),
                  ),
                  if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
                  FilledButton(onPressed: _busy ? null : _signIn, style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)), child: Text(_busy ? 'Signing in…' : 'Sign in')),
                  const SizedBox(height: 18),
                  Wrap(alignment: WrapAlignment.center, children: [
                    Text('Have an invitation? ', style: TextStyle(color: t.textMuted, fontSize: Fs.sm)),
                    InkWell(
                      onTap: () => launchUrl(Uri.parse('$webUrl/invite'), mode: LaunchMode.externalApplication),
                      child: const Text('Create your login', style: TextStyle(fontWeight: FontWeight.w600, fontSize: Fs.sm, decoration: TextDecoration.underline)),
                    ),
                  ]),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
