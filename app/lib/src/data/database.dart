import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

class Recordings extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();

  /// Path of the WAV file, relative to the app documents directory so the
  /// library survives container moves on iOS.
  TextColumn get relativePath => text()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get durationMs => integer().nullable()();
  IntColumn get sampleRate => integer()();
  IntColumn get channels => integer().withDefault(const Constant(1))();

  /// Per-recording [AnalysisSettings] as JSON; null = defaults.
  TextColumn get analysisSettingsJson => text().nullable()();
}

@DriftDatabase(tables: [Recordings])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'openphon'));

  /// In-memory or otherwise injected executor for tests.
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.addColumn(recordings, recordings.analysisSettingsJson);
      }
    },
  );

  Stream<List<Recording>> watchLibrary() => (select(
    recordings,
  )..orderBy([(r) => OrderingTerm.desc(r.createdAt)])).watch();

  Future<int> addRecording(RecordingsCompanion entry) =>
      into(recordings).insert(entry);

  Future<void> deleteRecording(int id) =>
      (delete(recordings)..where((r) => r.id.equals(id))).go();

  Future<void> renameRecording(int id, String name) =>
      (update(recordings)..where((r) => r.id.equals(id))).write(
        RecordingsCompanion(name: Value(name)),
      );

  Future<void> updateAnalysisSettings(int id, String json) =>
      (update(recordings)..where((r) => r.id.equals(id))).write(
        RecordingsCompanion(analysisSettingsJson: Value(json)),
      );
}
