import 'package:flutter_test/flutter_test.dart';
import 'package:rotolo_ai_assistant/core/data_quality.dart';
import 'package:rotolo_ai_assistant/core/money.dart';
import 'package:rotolo_ai_assistant/core/notification_routing.dart';
import 'package:rotolo_ai_assistant/core/time_format.dart';
import 'package:rotolo_ai_assistant/models/json.dart';

void main() {
  group('Money', () {
    test('formats minor units without floating point', () {
      expect(const Money(0).format(), r'$0.00');
      expect(const Money(5).format(), r'$0.05');
      expect(const Money(123456789).format(), r'$1,234,567.89');
      expect(const Money(-22550).format(), r'-$225.50');
    });

    test('null is "Not returned", never zero', () {
      expect(formatMinor(null), 'Not returned');
      expect(formatMinor(0), r'$0.00');
    });

    test('parses amounts exactly', () {
      expect(parseAmountToMinor('500'), 50000);
      expect(parseAmountToMinor('500.5'), 50050);
      expect(parseAmountToMinor(r'$1,250.05'), 125005);
      expect(parseAmountToMinor(' 0.10 '), 10);
      // 0.1 + 0.2 style float traps are impossible: digits are parsed as integers.
      expect(parseAmountToMinor('19.99'), 1999);
    });

    test('rejects ambiguous input', () {
      for (final bad in ['', '-5', '1.234', '12,34', 'abc', '1e3', '1,2345.00', '.50']) {
        expect(parseAmountToMinor(bad), isNull, reason: bad);
      }
    });

    test('JSON money must be integer minor units', () {
      expect(asInt(75000), 75000);
      expect(asInt(750.5), isNull);
      expect(asInt('75000'), isNull);
    });
  });

  group('qualityFlags', () {
    final now = DateTime.utc(2026, 11, 18, 15);
    List<QualityFlag> f({String mode = 'live', String status = 'complete', DateTime? at, bool latest = true}) =>
        qualityFlags(
            dataMode: mode, status: status, collectedAt: at ?? now, now: now, staleAfterHours: 26, isLatest: latest);

    test('live only when nothing else applies', () {
      expect(f(), [QualityFlag.live]);
    });

    test('synthetic is always flagged and never live', () {
      expect(f(mode: 'synthetic'), [QualityFlag.synthetic]);
      expect(f(mode: 'synthetic', status: 'partial'), [QualityFlag.synthetic, QualityFlag.incomplete]);
    });

    test('unknown modes and statuses fail safe', () {
      expect(f(mode: 'LIVE'), contains(QualityFlag.synthetic));
      expect(f(mode: 'unknown'), isNot(contains(QualityFlag.live)));
      expect(f(status: 'weird'), [QualityFlag.incomplete]);
    });

    test('stale and missing timestamps', () {
      expect(f(at: now.subtract(const Duration(hours: 27))), [QualityFlag.stale]);
      expect(
          qualityFlags(
              dataMode: 'live', status: 'complete', collectedAt: null, now: now, staleAfterHours: 26, isLatest: true),
          [QualityFlag.stale]);
    });

    test('unavailable and historical', () {
      expect(f(status: 'unavailable'), [QualityFlag.unavailable]);
      expect(f(latest: false), [QualityFlag.historical]);
    });
  });

  group('notification routing', () {
    test('routes report_ready to the report', () {
      expect(routeForNotification({'type': 'report_ready', 'report_id': 'abc-123'}), '/reports/abc-123');
    });

    test('ignores unknown types and unsafe ids', () {
      expect(routeForNotification({'type': 'other', 'report_id': 'abc'}), isNull);
      expect(routeForNotification({'type': 'report_ready', 'report_id': '../money'}), isNull);
      expect(routeForNotification({'type': 'report_ready', 'report_id': 'a/b'}), isNull);
      expect(routeForNotification({'type': 'report_ready'}), isNull);
      expect(routeForNotification({'type': 'report_ready', 'report_id': 42}), isNull);
    });
  });

  group('time formatting', () {
    test('business timezone and DST', () {
      expect(formatInstant(DateTime.utc(2026, 11, 18, 14, 5), 'America/New_York'), '9:05 AM EST, Wed 18 Nov');
      expect(formatInstant(DateTime.utc(2026, 7, 1, 13, 0), 'America/New_York'), '9:00 AM EDT, Wed 1 Jul');
    });

    test('durations never invent zeros', () {
      expect(formatDuration(null), 'Not returned');
      expect(formatDuration(28980), '8h 03m');
    });
  });
}
