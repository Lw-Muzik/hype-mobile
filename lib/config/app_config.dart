/// App configuration that reads secrets from --dart-define build arguments.
///
/// Defaults are provided for development. Override at build time with:
/// ```
/// flutter run --dart-define=API_BASE_URL=https://production-api.com
/// ```
class AppConfig {
  // Firebase Android
  static const String firebaseAndroidApiKey = String.fromEnvironment(
    'FIREBASE_ANDROID_API_KEY',
    defaultValue: 'AIzaSyDHcsmb7ik8VwYtpT61ufIrsQKwD_udHgg',
  );
  static const String firebaseAppIdAndroid = String.fromEnvironment(
    'FIREBASE_APP_ID_ANDROID',
    defaultValue: '1:618382337035:android:281cf52691c9ad7a02d30e',
  );

  // Firebase iOS
  static const String firebaseIosApiKey = String.fromEnvironment(
    'FIREBASE_IOS_API_KEY',
    defaultValue: 'AIzaSyC0qCPDjsjCFW9NGptlKqBCtksBmnEq-X4',
  );
  static const String firebaseAppIdIos = String.fromEnvironment(
    'FIREBASE_APP_ID_IOS',
    defaultValue: '1:618382337035:ios:4ce8b675b479c9f902d30e',
  );
  static const String firebaseIosBundleId = String.fromEnvironment(
    'FIREBASE_IOS_BUNDLE_ID',
    defaultValue: 'x.a.zix',
  );

  // Firebase shared
  static const String firebaseMessagingSenderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
    defaultValue: '618382337035',
  );
  static const String firebaseProjectId = String.fromEnvironment(
    'FIREBASE_PROJECT_ID',
    defaultValue: 'hype-muzik',
  );
  static const String firebaseStorageBucket = String.fromEnvironment(
    'FIREBASE_STORAGE_BUCKET',
    defaultValue: 'hype-muzik.appspot.com',
  );

  /// Must equal `storage_bucket` in android/app/google-services.json: the native
  /// default app is built from that file, and FlutterFire refuses (duplicate-app)
  /// options whose bucket differs from it.
  static const String firebaseAndroidStorageBucket = String.fromEnvironment(
    'FIREBASE_ANDROID_STORAGE_BUCKET',
    defaultValue: 'hype-muzik.firebasestorage.app',
  );

  // Wiredash
  static const String wiredashProjectId = String.fromEnvironment(
    'WIREDASH_PROJECT_ID',
    defaultValue: 'hype-muzik-q8wp9st',
  );
  static const String wiredashSecret = String.fromEnvironment(
    'WIREDASH_SECRET',
    defaultValue: 'UB-v1DeJeOBqg3yxM5lOqEhoSsjrq-HM',
  );

  // API
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://158.220.124.52:3035',
  );

  // HypeMuzik backend (accounts + Hype Connect). The `/api` prefix is part of
  // the base: every route the backend serves lives under it, and the Hype
  // Connect socket is `<base>/connect/ws` with the scheme swapped to ws(s).
  //
  //   flutter run --dart-define=HM_API_BASE=https://api.example.com/api
  static const String hypeMuzikApiBase = String.fromEnvironment(
    'HM_API_BASE',
    defaultValue: 'https://api.hypemuzik.com/api',
  );

  // AcoustID (audio fingerprint recognition)
  static const String acoustIdApiKey = String.fromEnvironment(
    'ACOUSTID_API_KEY',
    defaultValue: 'r8INVHtWPX',
  );

  // ACRCloud (fallback music recognition)
  static const String acrCloudHost = String.fromEnvironment(
    'ACRCLOUD_HOST',
    defaultValue: 'identify-us-west-2.acrcloud.com',
  );
  static const String acrCloudAccessKey = String.fromEnvironment(
    'ACRCLOUD_ACCESS_KEY',
    defaultValue: '9f40e16ba89fd405c8e6a2337ce0845a',
  );
  static const String acrCloudAccessSecret = String.fromEnvironment(
    'ACRCLOUD_ACCESS_SECRET',
    defaultValue: '7NGOIDIwcEw8jb19jpGuNeyoz1ldKRN11SCl7ZBw',
  );

  // Google Sign-In (Web Client ID — required by google_sign_in_android v7+)
  static const String googleWebClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
    defaultValue: '618382337035-9nt8g6k40j6cvbfuekvt2iqliocrb52a.apps.googleusercontent.com',
  );

  // Dropbox OAuth
  static const String dropboxAppKey = String.fromEnvironment(
    'DROPBOX_APP_KEY',
    defaultValue: '1d0mou7l0x19mas',
  );
  static const String dropboxRedirectUri = String.fromEnvironment(
    'DROPBOX_REDIRECT_URI',
    defaultValue: 'x.a.zix://oauth2/dropbox',
  );
}
