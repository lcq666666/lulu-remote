import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/activation_screen.dart';
import 'screens/home_screen.dart';
import 'services/activation_service.dart';

class LuluTheme {
  const LuluTheme._(this.isDark);

  final bool isDark;
  static const _dark = LuluTheme._(true);
  static const _light = LuluTheme._(false);

  static LuluTheme of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? _dark : _light;

  Color get background =>
      isDark ? const Color(0xFF0D1117) : const Color(0xFFF6F8FA);
  Color get sidebar => isDark ? const Color(0xFF0B0E14) : Colors.white;
  Color get card => isDark ? const Color(0xFF161B22) : Colors.white;
  Color get border =>
      isDark ? const Color(0xFF30363D) : const Color(0xFFE2E8F0);
  Color get hoverBorder =>
      isDark ? const Color(0xFF4B5563) : const Color(0xFFCBD5E1);
  Color get divider => isDark ? const Color(0xFF21262D) : border;
  Color get accent =>
      isDark ? const Color(0xFF3B82F6) : const Color(0xFF2563EB);
  Color get online => const Color(0xFF22C55E);
  Color get success => isDark ? online : const Color(0xFF15803D);
  Color get offline =>
      isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8);
  Color get warning =>
      isDark ? const Color(0xFFF59E0B) : const Color(0xFF92400E);
  Color get text => isDark ? const Color(0xFFF0F6FC) : const Color(0xFF0F172A);
  Color get muted => isDark ? const Color(0xFF8B949E) : const Color(0xFF64748B);
  Color get selected =>
      isDark ? const Color(0xFF1A2941) : const Color(0xFFEAF2FF);
  Color get selectedSegment => isDark ? const Color(0xFF2E4268) : accent;
  Color get field => isDark ? background : const Color(0xFFF8FAFC);
  Color get menu => isDark ? const Color(0xFF1C2128) : card;

  static const mono = TextStyle(
    fontFamily: 'JetBrains Mono',
    fontFamilyFallback: ['Consolas', 'monospace'],
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static final lightTheme = _light._build();
  static final darkTheme = _dark._build();

  ThemeData _build() {
    final scheme =
        (isDark ? const ColorScheme.dark() : const ColorScheme.light())
            .copyWith(
      primary: accent,
      onPrimary: Colors.white,
      surface: card,
      onSurface: text,
      onSurfaceVariant: muted,
      primaryContainer: selected,
      onPrimaryContainer: text,
      secondaryContainer: selected,
      onSecondaryContainer: text,
      outline: border,
      outlineVariant: divider,
      error: isDark ? const Color(0xFFF87171) : const Color(0xFFDC2626),
      surfaceTint: Colors.transparent,
    );
    final theme = ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        fontFamily: 'Plus Jakarta Sans',
        fontFamilyFallback: const ['Microsoft YaHei UI', 'Microsoft YaHei']);
    final radius = BorderRadius.circular(8);
    final fieldBorder = OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: isDark ? border : hoverBorder));
    final buttonShape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(7));
    return theme.copyWith(
      scaffoldBackgroundColor: background,
      textTheme: theme.textTheme.apply(bodyColor: text, displayColor: text),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: text,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        titleTextStyle:
            TextStyle(color: text, fontSize: 20, fontWeight: FontWeight.w600),
      ),
      cardTheme: CardTheme(
        color: card,
        margin: EdgeInsets.zero,
        elevation: 0,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: border)),
      ),
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
        shape: buttonShape,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      )),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
        foregroundColor: text,
        side: BorderSide(color: isDark ? border : hoverBorder),
        shape: buttonShape,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      )),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: field,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: fieldBorder,
        enabledBorder: fieldBorder,
        focusedBorder:
            fieldBorder.copyWith(borderSide: BorderSide(color: accent)),
      ),
      dividerTheme: DividerThemeData(color: divider, thickness: 1, space: 1),
      dialogTheme: DialogTheme(
        backgroundColor: card,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: border)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: menu,
        shape: RoundedRectangleBorder(
            borderRadius: radius, side: BorderSide(color: border)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: card,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? const Color(0xFF12161E) : sidebar,
        indicatorColor: selected,
        height: 64,
        elevation: 0,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: card,
        contentTextStyle: TextStyle(color: text, fontSize: 13),
        shape: RoundedRectangleBorder(
            borderRadius: radius, side: BorderSide(color: border)),
      ),
    );
  }
}

class LuluApp extends StatefulWidget {
  const LuluApp(
      {super.key,
      this.navigatorKey,
      this.activation,
      this.onActivated,
      this.onDeactivated});

  final GlobalKey<NavigatorState>? navigatorKey;
  final ActivationService? activation;
  final VoidCallback? onActivated;
  final VoidCallback? onDeactivated;

  @override
  State<LuluApp> createState() => _LuluAppState();
}

class _LuluAppState extends State<LuluApp> with WidgetsBindingObserver {
  static const _themeKey = 'lulu.theme';
  late final Future<SharedPreferences> _preferences;
  ThemeMode _mode = ThemeMode.dark;
  bool _changedByUser = false;
  ActivationState? _activationState;
  Timer? _reviewTimer;
  final _navigator = GlobalKey<NavigatorState>();
  bool _changingActivation = false;

  @override
  void initState() {
    super.initState();
    _preferences = SharedPreferences.getInstance();
    unawaited(_restoreTheme());
    if (widget.activation != null) {
      WidgetsBinding.instance.addObserver(this);
      unawaited(_loadActivation());
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onActivated?.call();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reviewTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_review());
  }

  Future<void> _loadActivation() async {
    final state = await widget.activation!.load();
    if (!mounted) return;
    if (state.active) {
      _activate(state);
    } else {
      setState(() => _activationState = state);
      widget.onDeactivated?.call();
    }
  }

  void _activate(ActivationState state) {
    setState(() => _activationState = state);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_activationState, state)) return;
      widget.onActivated?.call();
      _reviewTimer?.cancel();
      _reviewTimer = Timer.periodic(
          const Duration(minutes: 5), (_) => unawaited(_review()));
      unawaited(_review());
    });
  }

  Future<void> _review() async {
    final state = _activationState;
    if (_changingActivation || state?.active != true) return;
    if (await widget.activation!.checkRevocation() &&
        mounted &&
        identical(_activationState, state)) {
      _leaveHome(ActivationState(
          machine: state!.machine, error: ActivationError.revoked));
    }
  }

  void _leaveHome(ActivationState state) {
    _reviewTimer?.cancel();
    widget.onDeactivated?.call();
    (widget.navigatorKey ?? _navigator)
        .currentState
        ?.popUntil((route) => route.isFirst);
    setState(() => _activationState = state);
  }

  Future<void> _resetActivation() async {
    if (_changingActivation) return;
    _changingActivation = true;
    try {
      await widget.activation!.reset();
      if (mounted) {
        _leaveHome(ActivationState(machine: _activationState?.machine));
      }
    } catch (_) {
      final context = (widget.navigatorKey ?? _navigator).currentContext;
      if (context != null && context.mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('无法清除本机激活状态，请重试。')));
      }
    } finally {
      _changingActivation = false;
    }
  }

  Widget _home() {
    final service = widget.activation;
    final state = _activationState;
    if (service != null && state?.active != true) {
      if (state == null) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return ActivationScreen(
          service: service,
          state: state,
          onActivated: _activate,
          onRetry: _loadActivation);
    }
    return HomeScreen(
        themeMode: _mode,
        onThemeChanged: _setTheme,
        machineSuffix: state?.machine?.code.split('-').last,
        onResetActivation: service == null ? null : _resetActivation);
  }

  Future<void> _restoreTheme() async {
    try {
      final preferences = await _preferences;
      if (mounted &&
          !_changedByUser &&
          preferences.getString(_themeKey) == 'light') {
        setState(() => _mode = ThemeMode.light);
      }
    } catch (error) {
      debugPrint('Unable to restore the launcher theme: $error');
    }
  }

  Future<void> _setTheme(ThemeMode mode) async {
    if (_mode == mode) return;
    _changedByUser = true;
    setState(() => _mode = mode);
    try {
      final preferences = await _preferences;
      await preferences.setString(_themeKey, _mode.name);
    } catch (error) {
      debugPrint('Unable to persist the launcher theme: $error');
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '强哥远程',
        navigatorKey: widget.navigatorKey ?? _navigator,
        theme: LuluTheme.lightTheme,
        darkTheme: LuluTheme.darkTheme,
        themeMode: _mode,
        debugShowCheckedModeBanner: false,
        home: _home(),
      );
}
