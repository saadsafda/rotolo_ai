import 'package:intl/intl.dart';

/// Money in integer minor units (cents). Never converted through floating point.
class Money {
  const Money(this.minor, {this.currency = 'USD'});

  final int minor;
  final String currency;

  static final _group = NumberFormat('#,##0', 'en_US');

  String format() {
    final negative = minor < 0;
    final abs = minor.abs();
    final major = abs ~/ 100;
    final cents = (abs % 100).toString().padLeft(2, '0');
    final symbol = currency == 'USD' ? r'$' : '$currency ';
    return '${negative ? '-' : ''}$symbol${_group.format(major)}.$cents';
  }

  @override
  String toString() => format();

  @override
  bool operator ==(Object other) =>
      other is Money && other.minor == minor && other.currency == currency;

  @override
  int get hashCode => Object.hash(minor, currency);
}

/// Formats a nullable minor amount; `null` is shown as unavailable, never as $0.00.
String formatMinor(int? minor, {String currency = 'USD', String missing = 'Not returned'}) =>
    minor == null ? missing : Money(minor, currency: currency).format();

final _amountPattern = RegExp(r'^\$?\s*((?:\d{1,3}(?:,\d{3})+)|\d+)(?:\.(\d{1,2}))?$');

/// Parses user input such as "1,250.5" or "$300" into minor units.
/// Returns null for anything ambiguous (negative, >2 decimals, letters, empty).
int? parseAmountToMinor(String input) {
  final m = _amountPattern.firstMatch(input.trim());
  if (m == null) return null;
  final major = int.parse(m.group(1)!.replaceAll(',', ''));
  final fraction = (m.group(2) ?? '').padRight(2, '0');
  final value = major * 100 + int.parse(fraction);
  return value;
}
