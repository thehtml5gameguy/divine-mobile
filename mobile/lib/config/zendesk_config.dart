// ABOUTME: Configuration for Zendesk Support SDK credentials
// ABOUTME: Loads from build-time environment variables to keep secrets out of source

/// Zendesk Support SDK configuration
class ZendeskConfig {
  /// Zendesk OAuth "Unique identifier" (shown as client ID in Zendesk admin)
  /// Get from: Admin → Apps and integrations → APIs → OAuth Clients
  /// Set via: --dart-define=ZENDESK_APP_ID=xxx
  static const String appId = String.fromEnvironment(
    'ZENDESK_APP_ID',
    defaultValue: '',
  );

  /// Zendesk OAuth "Secret" (shown as secret in Zendesk admin)
  /// Get from: Admin → Apps and integrations → APIs → OAuth Clients
  /// Set via: --dart-define=ZENDESK_CLIENT_ID=xxx
  static const String clientId = String.fromEnvironment(
    'ZENDESK_CLIENT_ID',
    defaultValue: '',
  );

  /// Zendesk instance URL
  /// Set via: --dart-define=ZENDESK_URL=xxx
  static const String zendeskUrl = String.fromEnvironment(
    'ZENDESK_URL',
    defaultValue: 'https://rabblelabs.zendesk.com',
  );
}
