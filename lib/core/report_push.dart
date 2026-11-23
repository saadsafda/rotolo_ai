import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final reportPushProvider = Provider<ReportPush?>((ref) => null);

class ReportPush {
  ReportPush(this._db, this._prefs, this.platform);

  final SupabaseClient _db;
  final SharedPreferences _prefs;
  final String platform;
  FirebaseMessaging get _messaging => FirebaseMessaging.instance;
  String _preference(String userId) => 'report-push-$userId';
  String _savedToken(String userId) => 'report-push-token-$userId';

  bool optedIn(String userId) => _prefs.getBool(_preference(userId)) ?? false;

  Future<void> enable(String userId) async {
    final permission = await _messaging.requestPermission();
    if (permission.authorizationStatus != AuthorizationStatus.authorized &&
        permission.authorizationStatus != AuthorizationStatus.provisional) {
      throw StateError('Allow notifications for Rotolo in your device settings.');
    }
    await _register(userId);
    await _prefs.setBool(_preference(userId), true);
  }

  Future<void> _register(String userId, {String? updatedToken}) async {
    if (_db.auth.currentUser?.id != userId) return;
    if (platform == 'ios' && await _messaging.getAPNSToken() == null) {
      throw StateError('This iPhone is still registering for notifications. Try again shortly.');
    }
    final token = updatedToken ?? await _messaging.getToken();
    if (token == null) throw StateError('The notification service is unavailable.');
    if (_db.auth.currentUser?.id != userId) return;
    final previous = _prefs.getString(_savedToken(userId));
    await _db.rpc<void>('register_report_device', params: {
      'p_token': token, 'p_platform': platform,
      'p_quiet_hours': _prefs.getBool('rotolo-notify-quiet') ?? false,
    });
    if (previous != null && previous != token) {
      await _db.rpc<void>('unregister_device_token', params: {'p_token': previous});
    }
    await _prefs.setString(_savedToken(userId), token);
  }

  Future<void> disable(String userId) async {
    await revoke(userId);
    await _prefs.setBool(_preference(userId), false);
  }

  Future<void> revoke(String userId) async {
    final token = _prefs.getString(_savedToken(userId));
    if (token == null) return;
    await _db.rpc<void>('unregister_device_token', params: {'p_token': token});
    await _prefs.remove(_savedToken(userId));
  }

  Future<void> applyQuietHours(String userId) async {
    if (optedIn(userId)) await _register(userId);
  }

  Future<void> refresh(String userId, {String? updatedToken}) async {
    if (!optedIn(userId)) return;
    try {
      final permission = await _messaging.getNotificationSettings();
      if (permission.authorizationStatus == AuthorizationStatus.denied) {
        await disable(userId);
      } else {
        await _register(userId, updatedToken: updatedToken);
      }
    } catch (_) {
      // The app can still load reports with the notification service offline.
      debugPrint('Unable to refresh report notifications.');
    }
  }
}
