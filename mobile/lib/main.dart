import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'board_data.dart';
import 'board_screen.dart';
import 'format.dart';

/*
 * MOIS phone app (started 2026-10-30): sign in, then the director's dashboard.
 *   flutter run -d chrome --dart-define-from-file=env.json
 * --dart-define=DEMO=true shows made-up figures without signing in, to check the layout.
 */
const _url = String.fromEnvironment('SUPABASE_URL');
const _key = String.fromEnvironment('SUPABASE_ANON_KEY');
const _demo = bool.fromEnvironment('DEMO');
const _khaki = Color(0xFFB7A57A);
const _allowed = {'owner', 'director'}; // who the app is for so far

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!_demo) await Supabase.initialize(url: _url, publishableKey: _key);
  runApp(const MoisApp());
}

ThemeData _theme(Brightness b) => ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: _khaki, brightness: b, primary: _khaki, error: b == Brightness.dark ? const Color(0xFFE0A030) : const Color(0xFFB26A00)),
      scaffoldBackgroundColor: b == Brightness.dark ? const Color(0xFF1A1A19) : const Color(0xFFF7F6F3),
    );

class MoisApp extends StatelessWidget {
  const MoisApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'MOIS',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        home: _demo ? const _DemoHome() : const _AuthGate(),
      );
}

class _DemoHome extends StatelessWidget {
  const _DemoHome();
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Dashboard — sample figures')),
        body: BoardScreen(board: demoBoard(), onRefresh: () async {}, place: 'All branches', today: isoDay(DateTime.now())),
      );
}

class _AuthGate extends StatelessWidget {
  const _AuthGate();
  @override
  Widget build(BuildContext context) => StreamBuilder<AuthState>(
        stream: Supabase.instance.client.auth.onAuthStateChange,
        builder: (context, _) => Supabase.instance.client.auth.currentSession == null ? const _LoginScreen() : const _Home(),
      );
}

class _LoginScreen extends StatefulWidget {
  const _LoginScreen();
  @override
  State<_LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<_LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String _error = '';

  Future<void> _signIn() async {
    setState(() { _busy = true; _error = ''; });
    try {
      await Supabase.instance.client.auth.signInWithPassword(email: _email.text.trim(), password: _password.text);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't reach MOIS. Check your connection.");
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  void dispose() { _email.dispose(); _password.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: AutofillGroup(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Text('MOIS', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text('Sign in to your account', style: TextStyle(color: Theme.of(context).hintColor)),
                    const SizedBox(height: 24),
                    TextField(controller: _email, keyboardType: TextInputType.emailAddress, autofillHints: const [AutofillHints.email], decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder())),
                    const SizedBox(height: 12),
                    TextField(controller: _password, obscureText: true, autofillHints: const [AutofillHints.password], onSubmitted: (_) => _signIn(), decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder())),
                    if (_error.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error, style: TextStyle(color: Theme.of(context).colorScheme.error))),
                    const SizedBox(height: 18),
                    FilledButton(onPressed: _busy ? null : _signIn, style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)), child: Text(_busy ? 'Signing in…' : 'Sign in')),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
}

class _Home extends StatefulWidget {
  const _Home();
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  final _loader = BoardLoader(Supabase.instance.client);
  List<BranchChoice> _branches = [];
  String? _branchId;
  Board? _board;
  String _error = '';
  bool? _allowedRole;

  String get _today => isoDay(DateTime.now());

  @override
  void initState() { super.initState(); _start(); }

  Future<void> _start() async {
    try {
      final uid = Supabase.instance.client.auth.currentUser!.id;
      final roles = await Supabase.instance.client.from('user_roles').select('role:roles(name)').eq('user_id', uid);
      final ok = roles.any((r) => _allowed.contains(r['role']?['name']));
      if (!mounted) return;
      setState(() => _allowedRole = ok);
      if (!ok) return;
      _branches = await _loader.branches();
      await _load();
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load the dashboard.");
    }
  }

  Future<void> _load() async {
    setState(() => _error = '');
    try {
      final b = await _loader.load(branchId: _branchId, branches: _branches, today: _today);
      if (mounted) setState(() => _board = b);
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load the dashboard.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final place = _branchId == null ? 'All branches' : _branches.firstWhere((b) => b.id == _branchId).name;
    return Scaffold(
      appBar: AppBar(
        title: _branches.length > 1
            ? DropdownButtonHideUnderline(
                child: DropdownButton<String?>(
                  value: _branchId,
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('All branches')),
                    for (final b in _branches) DropdownMenuItem(value: b.id, child: Text(b.name)),
                  ],
                  onChanged: (v) { setState(() { _branchId = v; _board = null; }); _load(); },
                ),
              )
            : Text(place),
        actions: [IconButton(tooltip: 'Sign out', icon: const Icon(Icons.logout), onPressed: () => Supabase.instance.client.auth.signOut())],
      ),
      body: _allowedRole == false
          ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('The phone app is for directors for now. Use MOIS on the web.', textAlign: TextAlign.center)))
          : _error.isNotEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Text(_error), const SizedBox(height: 12), OutlinedButton(onPressed: _start, child: const Text('Try again'))]))
              : _board == null
                  ? const Center(child: CircularProgressIndicator())
                  : BoardScreen(board: _board!, onRefresh: _load, place: place, today: _today),
    );
  }
}
