import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../services/api.dart';
import '../services/storage.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'sources_screen.dart'
    show showAddSubscriptionSheet, showImportConfigsSheet;

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.state});
  final AppState state;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final _server = TextEditingController(text: Storage.I.baseUrl);
  late final _user = TextEditingController(text: Storage.I.savedUsername);
  late final _pass = TextEditingController(text: Storage.I.savedPassword);
  final _formKey = GlobalKey<FormState>();

  bool _obscure = true;
  bool _remember = Storage.I.rememberMe;
  bool _checkingServer = false;
  String? _serverNote;

  /// Id of the device slot currently being handed back, so its row can say so.
  String? _releasing;

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _testServer() async {
    if (_server.text.trim().isEmpty) {
      setState(() => _serverNote = 'Enter the address your provider gave you');
      return;
    }
    setState(() {
      _checkingServer = true;
      _serverNote = null;
    });
    // Picks http vs https by probing, and follows any redirect the panel's
    // proxy sends — then writes the real address back into the field.
    final url = await PanelApi.resolveBaseUrl(_server.text);
    final api = PanelApi(baseUrl: url);
    try {
      final name = await api.ping();
      if (mounted) {
        setState(() {
          _server.text = api.baseUrl;
          _serverNote = 'Connected to “$name”';
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _serverNote = e.message);
    } finally {
      api.close();
      if (mounted) setState(() => _checkingServer = false);
    }
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    await widget.state.login(
      _server.text,
      _user.text,
      _pass.text,
      remember: _remember,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final wide = MediaQuery.sizeOf(context).width > 640;

    return Scaffold(
      body: Container(
        decoration: veilPageGlow(opacity: 0.13),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.symmetric(horizontal: wide ? 40 : 22, vertical: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const VeilMark(size: 44),
                          const SizedBox(width: 12),
                          Text(s.brand, style: VeilText.display(size: 30, weight: 700)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Sign in with the username and password\nyour provider gave you.',
                        textAlign: TextAlign.center,
                        style: VeilText.ui(
                            size: 13.5, color: VeilColors.muted, height: 1.5),
                      ),
                      const SizedBox(height: 28),

                      if (s.authError != null) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
                          decoration: BoxDecoration(
                            color: VeilColors.danger.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(VeilRadius.md),
                            border: Border.all(
                                color: VeilColors.danger.withValues(alpha: 0.35)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.error_outline_rounded,
                                      size: 16, color: VeilColors.danger),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(s.authError!,
                                        style: VeilText.ui(
                                            size: 12.5, color: VeilColors.danger)),
                                  ),
                                ],
                              ),
                              // Being told "all your slots are taken" is only
                              // useful if the other device is within reach. It
                              // usually is not, so the slots can be freed from
                              // here instead.
                              if (s.authFailure?.isDeviceLimit ?? false)
                                ..._deviceSlots(s.authFailure!.devices),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      _label('Panel address'),
                      TextFormField(
                        controller: _server,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        style: VeilText.mono(size: 13),
                        decoration: InputDecoration(
                          hintText: 'panel.example.com',
                          prefixIcon: Icon(Icons.dns_outlined,
                              size: 18, color: VeilColors.muted),
                          suffixIcon: IconButton(
                            tooltip: 'Test connection',
                            onPressed: _checkingServer ? null : _testServer,
                            icon: _checkingServer
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(strokeWidth: 2))
                                : Icon(Icons.wifi_tethering_rounded,
                                    size: 18, color: VeilColors.muted),
                          ),
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Panel address is required'
                            : null,
                      ),
                      if (_serverNote != null) ...[
                        const SizedBox(height: 6),
                        Text(_serverNote!,
                            style: VeilText.ui(size: 11.5, color: VeilColors.muted)),
                      ],
                      const SizedBox(height: 16),

                      _label('Username'),
                      TextFormField(
                        controller: _user,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
                        style: VeilText.mono(size: 13.5),
                        decoration: InputDecoration(
                          hintText: 'pvb10001',
                          prefixIcon: Icon(Icons.person_outline_rounded,
                              size: 18, color: VeilColors.muted),
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Username is required'
                            : null,
                      ),
                      const SizedBox(height: 16),

                      _label('Password'),
                      TextFormField(
                        controller: _pass,
                        obscureText: _obscure,
                        autocorrect: false,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _submit(),
                        style: VeilText.mono(size: 13.5),
                        decoration: InputDecoration(
                          hintText: '••••••••',
                          prefixIcon: Icon(Icons.lock_outline_rounded,
                              size: 18, color: VeilColors.muted),
                          suffixIcon: IconButton(
                            onPressed: () => setState(() => _obscure = !_obscure),
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 18,
                              color: VeilColors.muted,
                            ),
                          ),
                        ),
                        validator: (v) => (v == null || v.isEmpty)
                            ? 'Password is required'
                            : null,
                      ),
                      const SizedBox(height: 14),

                      Row(
                        children: [
                          VeilSwitch(
                              value: _remember,
                              onChanged: (v) => setState(() => _remember = v)),
                          const SizedBox(width: 10),
                          Text('Stay signed in',
                              style: VeilText.ui(size: 13, color: VeilColors.text2)),
                        ],
                      ),
                      const SizedBox(height: 22),

                      SizedBox(
                        height: 50,
                        child: FilledButton(
                          onPressed: s.busy ? null : _submit,
                          style: FilledButton.styleFrom(
                            backgroundColor: VeilColors.accent,
                            foregroundColor: VeilColors.onAccent,
                            disabledBackgroundColor:
                                VeilColors.accent.withValues(alpha: 0.4),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(VeilRadius.md)),
                          ),
                          child: s.busy
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2.4, color: VeilColors.onAccent),
                                )
                              : Text('Sign in',
                                  style: VeilText.ui(
                                      size: 15,
                                      weight: 600,
                                      color: VeilColors.onAccent)),
                        ),
                      ),

                      const SizedBox(height: 18),

                      // An account is one way in, not the only way: a
                      // subscription link or a pasted config is enough to
                      // connect, and someone who has one should not be stuck
                      // on a sign-in form.
                      Row(
                        children: [
                          Expanded(
                              child: Divider(color: VeilColors.borderSoft)),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 10),
                            child: Text('or',
                                style: VeilText.ui(
                                    size: 11, color: VeilColors.muted)),
                          ),
                          Expanded(
                              child: Divider(color: VeilColors.borderSoft)),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: _AltEntry(
                              icon: Icons.rss_feed_rounded,
                              label: 'Use a subscription',
                              onTap: () =>
                                  showAddSubscriptionSheet(context, s),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _AltEntry(
                              icon: Icons.content_paste_rounded,
                              label: 'Paste a config',
                              onTap: () => showImportConfigsSheet(context, s),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 22),
                      Text(
                        'Forgot your details? Ask whoever sold you the plan —\nonly they can reset your password.',
                        textAlign: TextAlign.center,
                        style: VeilText.ui(
                            size: 11.5, color: VeilColors.muted, height: 1.6),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 7),
        child: Text(t, style: VeilText.label(size: 11)),
      );

  /// One row per device holding a slot, each with a way to hand the slot back.
  List<Widget> _deviceSlots(List<ClientDevice> devices) {
    if (devices.isEmpty) return const [];
    return [
      const SizedBox(height: 10),
      Divider(height: 1, color: VeilColors.borderSoft),
      const SizedBox(height: 8),
      Text('SIGNED IN ON', style: VeilText.label(size: 9.5)),
      const SizedBox(height: 6),
      for (final d in devices)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  [
                    d.name.isEmpty ? 'Unknown device' : d.name,
                    if (d.platform.isNotEmpty) d.platform,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: VeilText.ui(size: 11.5, color: VeilColors.text2),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _releasing == d.id ? null : () => _release(d),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  foregroundColor: VeilColors.accent,
                ),
                child: Text(_releasing == d.id ? 'Signing out…' : 'Sign out',
                    style: VeilText.ui(size: 11.5, weight: 600)),
              ),
            ],
          ),
        ),
    ];
  }

  Future<void> _release(ClientDevice device) async {
    setState(() => _releasing = device.id);
    final error = await widget.state.releaseDevice(
      device.id,
      username: _user.text,
      password: _pass.text,
    );
    if (!mounted) return;
    setState(() => _releasing = null);
    if (error != null) {
      showVeilToast(context, error, error: true);
      return;
    }
    // The slot is free now; finishing the sign-in is what the user was trying
    // to do in the first place.
    await _submit();
  }
}

/// A way into the app that is not a panel account.
class _AltEntry extends StatelessWidget {
  const _AltEntry({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Clickable(child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 10),
          decoration: BoxDecoration(
            color: VeilColors.surface2,
            border: Border.all(color: VeilColors.border),
            borderRadius: BorderRadius.circular(VeilRadius.md),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: VeilColors.text2),
              const SizedBox(height: 7),
              Text(label,
                  textAlign: TextAlign.center,
                  style: VeilText.ui(
                      size: 11.5, weight: 500, color: VeilColors.text2)),
            ],
          ),
        ),
      ));
}
