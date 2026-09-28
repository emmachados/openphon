import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'l10n/app_localizations.dart';
import 'src/audio/recorder_service.dart' show migrateLibraryFromDocuments;
import 'src/data/app_prefs.dart';
import 'src/data/database.dart';
import 'src/data/storage_privacy.dart';
import 'src/rust/frb_generated.dart';
import 'src/ui/home_page.dart';

/// Rust-side dependencies are invisible to the Dart license aggregator, so
/// they are registered here and appear on the in-app licenses page with
/// everything else.
void registerRustLicenses() {
  LicenseRegistry.addLicense(() async* {
    final document =
        jsonDecode(
              await rootBundle.loadString('assets/licenses/rust_licenses.json'),
            )
            as Map<String, dynamic>;
    for (final entry in document['entries'] as List<dynamic>) {
      yield LicenseEntryWithLineBreaks(
        (entry['packages'] as List<dynamic>).cast<String>(),
        entry['text'] as String,
      );
    }
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerRustLicenses();
  runApp(const OpenphonBootstrap());
}

Future<Widget> _initializeApp() async {
  await preparePrivateStorage();
  await migrateLibraryFromDocuments();
  final prefs = AppPrefs();
  await prefs.load();
  // Finish fallible filesystem preparation before initializing the bridge,
  // which cannot be initialized twice when startup is retried.
  await RustLib.init();
  return OpenphonApp(db: AppDatabase(), prefs: prefs);
}

class OpenphonBootstrap extends StatefulWidget {
  const OpenphonBootstrap({super.key, this.initialize = _initializeApp});

  final Future<Widget> Function() initialize;

  @override
  State<OpenphonBootstrap> createState() => _OpenphonBootstrapState();
}

class _OpenphonBootstrapState extends State<OpenphonBootstrap> {
  late Future<Widget> _app;

  @override
  void initState() {
    super.initState();
    _app = widget.initialize();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Widget>(
    future: _app,
    builder: (context, snapshot) {
      if (snapshot.hasData) return snapshot.data!;
      return MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            final l10n = AppLocalizations.of(context)!;
            return Scaffold(
              body: Center(
                child: snapshot.hasError
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              l10n.startupFailed,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: () => setState(() {
                                _app = widget.initialize();
                              }),
                              child: Text(l10n.retry),
                            ),
                          ],
                        ),
                      )
                    : const CircularProgressIndicator(),
              ),
            );
          },
        ),
      );
    },
  );
}

class OpenphonApp extends StatelessWidget {
  const OpenphonApp({super.key, required this.db, required this.prefs});

  final AppDatabase db;
  final AppPrefs prefs;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => MaterialApp(
        onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2D5D7B)),
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF2D5D7B),
            brightness: Brightness.dark,
          ),
        ),
        themeMode: prefs.themeMode,
        home: HomePage(db: db, prefs: prefs),
      ),
    );
  }
}
