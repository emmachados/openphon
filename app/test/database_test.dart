import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/data/database.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('add, rename, and watch a recording', () async {
    final id = await db.addRecording(
      RecordingsCompanion.insert(
        name: 'take one',
        relativePath: 'recordings/take1.wav',
        createdAt: DateTime(2026, 7, 18),
        sampleRate: 44100,
      ),
    );
    await db.renameRecording(id, 'vowel sweep');
    final rows = await db.watchLibrary().first;
    expect(rows, hasLength(1));
    expect(rows.single.name, 'vowel sweep');
    // Identity fields are untouched by a rename.
    expect(rows.single.relativePath, 'recordings/take1.wav');
    expect(rows.single.sampleRate, 44100);
  });
}
