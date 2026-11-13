import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('sqlite opens in memory and reports its version', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final row = db.select('select sqlite_version() as v').first;
    expect(row['v'], isNotEmpty);
    // ignore: avoid_print
    print('sqlite ${row['v']}');
  });
}
