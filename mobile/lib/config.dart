import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Impostazioni persistenti: URL del proxy API e token Apple Music.
class Settings extends ChangeNotifier {
  static const _kBaseUrl = 'api_base_url';
  static const _kDevToken = 'apple_dev_token';
  static const _kUserToken = 'apple_user_token';
  static const _kStorefront = 'apple_storefront';

  String baseUrl = 'http://82.223.13.114';
  String appleDeveloperToken = '';
  String appleUserToken = '';
  String appleStorefront = 'it';

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    baseUrl = p.getString(_kBaseUrl) ?? baseUrl;
    appleDeveloperToken = p.getString(_kDevToken) ?? '';
    appleUserToken = p.getString(_kUserToken) ?? '';
    appleStorefront = p.getString(_kStorefront) ?? appleStorefront;
    notifyListeners();
  }

  Future<void> setBaseUrl(String value) async {
    baseUrl = value.trim();
    final p = await SharedPreferences.getInstance();
    await p.setString(_kBaseUrl, baseUrl);
    notifyListeners();
  }

  Future<void> saveAppleConfig({
    required String developerToken,
    required String userToken,
    String? storefront,
  }) async {
    appleDeveloperToken = developerToken.trim();
    appleUserToken = userToken.trim();
    if (storefront != null && storefront.trim().isNotEmpty) {
      appleStorefront = storefront.trim().toLowerCase();
    }
    final p = await SharedPreferences.getInstance();
    await p.setString(_kDevToken, appleDeveloperToken);
    await p.setString(_kUserToken, appleUserToken);
    await p.setString(_kStorefront, appleStorefront);
    notifyListeners();
  }
}
