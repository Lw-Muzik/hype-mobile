import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';

class CloudAuthService {
  static const _driveScope = 'https://www.googleapis.com/auth/drive.readonly';

  // Persisted flag marking that the user has explicitly connected Google Drive.
  // Gates the silent session restore so the Google account-picker popup only
  // shows when the user taps "Connect" — never spontaneously on every launch.
  static const _googleConnectedKey = 'google_connected';

  // Google — v7 platform interface API
  GoogleSignInUserData? _googleUser;
  bool _googleInitialized = false;

  // Dropbox
  final FlutterAppAuth _appAuth = const FlutterAppAuth();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  String? _dropboxAccessToken;
  String? _dropboxRefreshToken;
  DateTime? _dropboxTokenExpiry;

  /// Last error message for UI display.
  String? lastError;

  bool get isGoogleConnected => _googleUser != null;
  bool get isDropboxConnected => _dropboxAccessToken != null;

  // --- Google ---

  Future<void> _ensureGoogleInit() async {
    if (_googleInitialized) return;
    await GoogleSignInPlatform.instance.init(
      InitParameters(serverClientId: AppConfig.googleWebClientId),
    );
    _googleInitialized = true;
  }

  Future<bool> signInGoogle() async {
    lastError = null;
    try {
      await _ensureGoogleInit();

      final result = await GoogleSignInPlatform.instance.authenticate(
        const AuthenticateParameters(),
      );

      _googleUser = result.user;
      // Remember the explicit connection so future launches can restore
      // silently without re-prompting.
      await _secureStorage.write(key: _googleConnectedKey, value: 'true');
      return true;
    } catch (e) {
      final msg = e.toString();
      if (e is GoogleSignInException) {
        if (e.code == GoogleSignInExceptionCode.canceled) {
          lastError = 'Sign-in was cancelled';
        } else {
          lastError = 'Google sign-in failed: ${e.description}';
        }
      } else if (msg.contains('DEVELOPER_ERROR') || msg.contains('10:')) {
        lastError =
            'OAuth not configured. Add your SHA-1 fingerprint '
            'to Firebase Console and re-download google-services.json.';
      } else if (msg.contains('sign_in_canceled') || msg.contains('12501')) {
        lastError = 'Sign-in was cancelled';
      } else {
        lastError = 'Google sign-in failed: $msg';
      }
      dev.log('Google sign-in error: $e', name: 'CloudAuth');
      _googleUser = null;
      return false;
    }
  }

  Future<void> signOutGoogle() async {
    try {
      await _ensureGoogleInit();
      await GoogleSignInPlatform.instance.signOut(const SignOutParams());
    } catch (_) {}
    _googleUser = null;
    await _secureStorage.delete(key: _googleConnectedKey);
  }

  Future<bool> restoreGoogleSession() async {
    // Skip the restore entirely unless the user previously connected. Calling
    // lightweight authentication otherwise surfaces the Google account-picker /
    // One Tap popup on every app launch, which is what we want to avoid.
    final hasConnected =
        await _secureStorage.read(key: _googleConnectedKey) == 'true';
    if (!hasConnected) {
      _googleUser = null;
      return false;
    }
    try {
      await _ensureGoogleInit();
      final result = await GoogleSignInPlatform.instance
          .attemptLightweightAuthentication(
            const AttemptLightweightAuthenticationParameters(),
          );
      _googleUser = result?.user;
      return _googleUser != null;
    } catch (_) {
      _googleUser = null;
      return false;
    }
  }

  Future<Map<String, String>> getGoogleAuthHeaders() async {
    if (_googleUser == null) return {};
    try {
      await _ensureGoogleInit();
      final tokens = await GoogleSignInPlatform.instance
          .clientAuthorizationTokensForScopes(
            ClientAuthorizationTokensForScopesParameters(
              request: AuthorizationRequestDetails(
                scopes: const [_driveScope],
                userId: _googleUser!.id,
                email: _googleUser!.email,
                promptIfUnauthorized: false,
              ),
            ),
          );
      if (tokens == null) return {};
      return {'Authorization': 'Bearer ${tokens.accessToken}'};
    } catch (_) {
      // Token might be expired — try lightweight auth to refresh
      try {
        final result = await GoogleSignInPlatform.instance
            .attemptLightweightAuthentication(
              const AttemptLightweightAuthenticationParameters(),
            );
        _googleUser = result?.user;
        if (_googleUser == null) return {};

        final tokens = await GoogleSignInPlatform.instance
            .clientAuthorizationTokensForScopes(
              ClientAuthorizationTokensForScopesParameters(
                request: AuthorizationRequestDetails(
                  scopes: const [_driveScope],
                  userId: _googleUser!.id,
                  email: _googleUser!.email,
                  promptIfUnauthorized: false,
                ),
              ),
            );
        if (tokens == null) return {};
        return {'Authorization': 'Bearer ${tokens.accessToken}'};
      } catch (_) {
        return {};
      }
    }
  }

  // --- Dropbox ---

  Future<bool> signInDropbox() async {
    lastError = null;
    try {
      final result = await _appAuth.authorizeAndExchangeCode(
        AuthorizationTokenRequest(
          AppConfig.dropboxAppKey,
          AppConfig.dropboxRedirectUri,
          serviceConfiguration: const AuthorizationServiceConfiguration(
            authorizationEndpoint: 'https://www.dropbox.com/oauth2/authorize',
            tokenEndpoint: 'https://api.dropboxapi.com/oauth2/token',
          ),
          scopes: null,
          additionalParameters: {'token_access_type': 'offline'},
        ),
      );
      _dropboxAccessToken = result.accessToken;
      _dropboxRefreshToken = result.refreshToken;
      _dropboxTokenExpiry = result.accessTokenExpirationDateTime;
      await _persistDropboxTokens();
      return true;
    } catch (e) {
      lastError = 'Dropbox sign-in failed: $e';
      dev.log('Dropbox sign-in error: $e', name: 'CloudAuth');
      return false;
    }
  }

  Future<void> signOutDropbox() async {
    _dropboxAccessToken = null;
    _dropboxRefreshToken = null;
    _dropboxTokenExpiry = null;
    await _secureStorage.delete(key: 'dropbox_access_token');
    await _secureStorage.delete(key: 'dropbox_refresh_token');
    await _secureStorage.delete(key: 'dropbox_token_expiry');
  }

  Future<bool> restoreDropboxSession() async {
    try {
      _dropboxAccessToken = await _secureStorage.read(
        key: 'dropbox_access_token',
      );
      _dropboxRefreshToken = await _secureStorage.read(
        key: 'dropbox_refresh_token',
      );
      final expiryStr = await _secureStorage.read(key: 'dropbox_token_expiry');
      if (expiryStr != null) {
        _dropboxTokenExpiry = DateTime.tryParse(expiryStr);
      }
      if (_dropboxAccessToken != null) {
        await _refreshDropboxIfNeeded();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, String>> getDropboxAuthHeaders() async {
    await _refreshDropboxIfNeeded();
    if (_dropboxAccessToken == null) return {};
    return {'Authorization': 'Bearer $_dropboxAccessToken'};
  }

  Future<void> _refreshDropboxIfNeeded() async {
    if (_dropboxRefreshToken == null) return;
    if (_dropboxTokenExpiry != null &&
        _dropboxTokenExpiry!.isAfter(
          DateTime.now().add(const Duration(minutes: 5)),
        )) {
      return;
    }
    try {
      final response = await http.post(
        Uri.parse('https://api.dropboxapi.com/oauth2/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': _dropboxRefreshToken!,
          'client_id': AppConfig.dropboxAppKey,
        },
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _dropboxAccessToken = data['access_token'];
        _dropboxTokenExpiry = DateTime.now().add(
          Duration(seconds: data['expires_in'] as int),
        );
        await _persistDropboxTokens();
      }
    } catch (_) {}
  }

  Future<void> _persistDropboxTokens() async {
    if (_dropboxAccessToken != null) {
      await _secureStorage.write(
        key: 'dropbox_access_token',
        value: _dropboxAccessToken!,
      );
    }
    if (_dropboxRefreshToken != null) {
      await _secureStorage.write(
        key: 'dropbox_refresh_token',
        value: _dropboxRefreshToken!,
      );
    }
    if (_dropboxTokenExpiry != null) {
      await _secureStorage.write(
        key: 'dropbox_token_expiry',
        value: _dropboxTokenExpiry!.toIso8601String(),
      );
    }
  }
}
