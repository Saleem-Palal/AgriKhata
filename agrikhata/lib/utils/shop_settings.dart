import 'package:shared_preferences/shared_preferences.dart';

/// Persisted shop branding and preferences used by Settings, sidebar, and PDFs.
class ShopSettings {
  ShopSettings._();

  static const shopNameKey = 'shop_name';
  static const shopAddressKey = 'shop_address';
  static const shopPhoneKey = 'shop_phone';
  static const darkThemeKey = 'dark_theme';
  static const showThumbprintBlockThermalKey =
      'show_thumbprint_block_thermal';

  static const defaultShopName = 'Shop Name';
  static const notConfiguredLabel = 'Not configured yet';

  /// Returns the saved shop name, or [defaultShopName] when unset/blank.
  static Future<String> getShopName() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(shopNameKey)?.trim();
    if (value == null || value.isEmpty) return defaultShopName;
    return value;
  }

  /// Persists [name]. Blank input clears the key so the default is used again.
  static Future<void> setShopName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      await prefs.remove(shopNameKey);
    } else {
      await prefs.setString(shopNameKey, trimmed);
    }
  }

  static Future<String> getShopAddress() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(shopAddressKey)?.trim() ?? '';
  }

  static Future<void> setShopAddress(String address) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = address.trim();
    if (trimmed.isEmpty) {
      await prefs.remove(shopAddressKey);
    } else {
      await prefs.setString(shopAddressKey, trimmed);
    }
  }

  static Future<String> getShopPhone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(shopPhoneKey)?.trim() ?? '';
  }

  static Future<void> setShopPhone(String phone) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = phone.trim();
    if (trimmed.isEmpty) {
      await prefs.remove(shopPhoneKey);
    } else {
      await prefs.setString(shopPhoneKey, trimmed);
    }
  }

  static Future<bool> getDarkTheme() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(darkThemeKey) ?? false;
  }

  static Future<void> setDarkTheme(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(darkThemeKey, enabled);
  }

  /// Whether thermal (80mm) receipts include the ink thumbprint/sign block.
  /// Defaults to enabled when unset.
  static Future<bool> getShowThumbprintBlockOnThermal() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(showThumbprintBlockThermalKey) ?? true;
  }

  static Future<void> setShowThumbprintBlockOnThermal(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(showThumbprintBlockThermalKey, enabled);
  }

  /// Subtitle for Settings rows: saved value, or [notConfiguredLabel].
  static String displayOrNotConfigured(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == defaultShopName) {
      return notConfiguredLabel;
    }
    return trimmed;
  }
}
