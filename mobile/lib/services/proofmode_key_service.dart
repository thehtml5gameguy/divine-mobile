// ABOUTME: ProofMode PGP key management service for device-specific cryptographic operations
// ABOUTME: Handles secure key generation, storage, and signing for proof validation

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dart_pg/dart_pg.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:openvine/services/proofmode_config.dart';
import 'package:openvine/utils/unified_logger.dart';

/// PGP key pair information
class ProofModeKeyPair {
  const ProofModeKeyPair({
    required this.publicKey,
    required this.privateKey,
    required this.fingerprint,
    required this.createdAt,
  });

  final String publicKey;
  final String privateKey;
  final String fingerprint;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'publicKey': publicKey,
        'privateKey': privateKey,
        'fingerprint': fingerprint,
        'createdAt': createdAt.toIso8601String(),
      };

  factory ProofModeKeyPair.fromJson(Map<String, dynamic> json) =>
      ProofModeKeyPair(
        publicKey: json['publicKey'] as String,
        privateKey: json['privateKey'] as String,
        fingerprint: json['fingerprint'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}

/// Proof signature result
class ProofSignature {
  const ProofSignature({
    required this.signature,
    required this.publicKeyFingerprint,
    required this.signedAt,
  });

  final String signature;
  final String publicKeyFingerprint;
  final DateTime signedAt;

  Map<String, dynamic> toJson() => {
        'signature': signature,
        'publicKeyFingerprint': publicKeyFingerprint,
        'signedAt': signedAt.toIso8601String(),
      };

  factory ProofSignature.fromJson(Map<String, dynamic> json) => ProofSignature(
        signature: json['signature'] as String,
        publicKeyFingerprint: json['publicKeyFingerprint'] as String,
        signedAt: DateTime.parse(json['signedAt'] as String),
      );
}

/// ProofMode PGP key management service
class ProofModeKeyService {
  static const String _keyPrefix = 'proofmode_key_';
  static const String _publicKeyKey = '${_keyPrefix}public';
  static const String _privateKeyKey = '${_keyPrefix}private';
  static const String _fingerprintKey = '${_keyPrefix}fingerprint';
  static const String _createdAtKey = '${_keyPrefix}created_at';

  static const FlutterSecureStorage _defaultSecureStorage =
      FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  final FlutterSecureStorage _secureStorage;
  ProofModeKeyPair? _cachedKeyPair;

  /// Create ProofModeKeyService with optional storage (for testing)
  ProofModeKeyService({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? _defaultSecureStorage;

  /// Initialize the key service and generate keys if needed
  Future<void> initialize() async {
    Log.info('Initializing ProofMode key service',
        name: 'ProofModeKeyService', category: LogCategory.auth);

    if (!await ProofModeConfig.isCryptoEnabled) {
      Log.info('ProofMode crypto disabled, skipping key initialization',
          name: 'ProofModeKeyService', category: LogCategory.auth);
      return;
    }

    try {
      // Check if keys already exist
      final existingKeyPair = await getKeyPair();
      if (existingKeyPair != null) {
        Log.info(
            'Found existing ProofMode keys, fingerprint: ${existingKeyPair.fingerprint}',
            name: 'ProofModeKeyService',
            category: LogCategory.auth);
        return;
      }

      // Generate new keys
      Log.info('No existing keys found, generating new ProofMode key pair',
          name: 'ProofModeKeyService', category: LogCategory.auth);
      await generateKeyPair();
    } catch (e) {
      Log.error('Failed to initialize ProofMode keys: $e',
          name: 'ProofModeKeyService', category: LogCategory.auth);
      rethrow;
    }
  }

  /// Generate a new PGP key pair for this device
  Future<ProofModeKeyPair> generateKeyPair() async {
    Log.info('Generating ProofMode key pair',
        name: 'ProofModeKeyService', category: LogCategory.auth);

    try {
      // For now, we'll use a simplified approach with basic crypto
      // In production, this would use proper PGP libraries like dart_pg

      // Generate a simple key pair using crypto library
      final keyData = await _generateSimpleKeyPair();

      final keyPair = ProofModeKeyPair(
        publicKey: keyData['publicKey']!,
        privateKey: keyData['privateKey']!,
        fingerprint: keyData['fingerprint']!,
        createdAt: DateTime.now(),
      );

      // Store in secure storage
      await _storeKeyPair(keyPair);
      _cachedKeyPair = keyPair;

      Log.info(
          'Generated ProofMode key pair with fingerprint: ${keyPair.fingerprint}',
          name: 'ProofModeKeyService',
          category: LogCategory.auth);

      return keyPair;
    } catch (e) {
      Log.error('Failed to generate ProofMode key pair: $e',
          name: 'ProofModeKeyService', category: LogCategory.auth);
      rethrow;
    }
  }

  /// Get the current key pair
  Future<ProofModeKeyPair?> getKeyPair() async {
    if (_cachedKeyPair != null) {
      return _cachedKeyPair;
    }

    try {
      final publicKey = await _secureStorage.read(key: _publicKeyKey);
      final privateKey = await _secureStorage.read(key: _privateKeyKey);
      final fingerprint = await _secureStorage.read(key: _fingerprintKey);
      final createdAtStr = await _secureStorage.read(key: _createdAtKey);

      if (publicKey == null ||
          privateKey == null ||
          fingerprint == null ||
          createdAtStr == null) {
        Log.debug('No complete key pair found in secure storage',
            name: 'ProofModeKeyService', category: LogCategory.auth);
        return null;
      }

      final keyPair = ProofModeKeyPair(
        publicKey: publicKey,
        privateKey: privateKey,
        fingerprint: fingerprint,
        createdAt: DateTime.parse(createdAtStr),
      );

      _cachedKeyPair = keyPair;
      return keyPair;
    } catch (e) {
      Log.error('Failed to retrieve key pair: $e',
          name: 'ProofModeKeyService', category: LogCategory.auth);
      return null;
    }
  }

  /// Get just the public key fingerprint for verification tags
  Future<String?> getPublicKeyFingerprint() async {
    final keyPair = await getKeyPair();
    return keyPair?.fingerprint;
  }

  /// Sign data with the private key
  Future<ProofSignature?> signData(String data) async {
    if (!await ProofModeConfig.isCryptoEnabled) {
      Log.debug('ProofMode crypto disabled, skipping signing',
          name: 'ProofModeKeyService', category: LogCategory.auth);
      return null;
    }

    try {
      final keyPair = await getKeyPair();
      if (keyPair == null) {
        Log.warning('No key pair available for signing',
            name: 'ProofModeKeyService', category: LogCategory.auth);
        return null;
      }

      // Generate signature (simplified approach for now)
      final signature = await _signWithPrivateKey(data, keyPair.privateKey);

      final proofSignature = ProofSignature(
        signature: signature,
        publicKeyFingerprint: keyPair.fingerprint,
        signedAt: DateTime.now(),
      );

      Log.debug('Signed data with fingerprint: ${keyPair.fingerprint}',
          name: 'ProofModeKeyService', category: LogCategory.auth);

      return proofSignature;
    } catch (e) {
      Log.error('Failed to sign data: $e',
          name: 'ProofModeKeyService', category: LogCategory.auth);
      return null;
    }
  }

  /// Verify a signature (for testing/validation)
  Future<bool> verifySignature(String data, ProofSignature signature) async {
    try {
      final keyPair = await getKeyPair();
      if (keyPair == null ||
          keyPair.fingerprint != signature.publicKeyFingerprint) {
        Log.warning('Key mismatch for signature verification',
            name: 'ProofModeKeyService', category: LogCategory.auth);
        return false;
      }

      // Verify signature (simplified approach)
      final isValid =
          _verifyWithPublicKey(data, signature.signature, keyPair.publicKey);

      Log.debug('Signature verification result: $isValid',
          name: 'ProofModeKeyService', category: LogCategory.auth);

      return isValid;
    } catch (e) {
      Log.error('Failed to verify signature: $e',
          name: 'ProofModeKeyService', category: LogCategory.auth);
      return false;
    }
  }

  /// Delete all keys (for testing/reset)
  Future<void> deleteKeys() async {
    Log.warning('Deleting ProofMode keys',
        name: 'ProofModeKeyService', category: LogCategory.auth);

    try {
      await _secureStorage.delete(key: _publicKeyKey);
      await _secureStorage.delete(key: _privateKeyKey);
      await _secureStorage.delete(key: _fingerprintKey);
      await _secureStorage.delete(key: _createdAtKey);
      _cachedKeyPair = null;

      Log.info('ProofMode keys deleted successfully',
          name: 'ProofModeKeyService', category: LogCategory.auth);
    } catch (e) {
      Log.error('Failed to delete keys: $e',
          name: 'ProofModeKeyService', category: LogCategory.auth);
      rethrow;
    }
  }

  // Private helper methods

  /// Store key pair in secure storage
  Future<void> _storeKeyPair(ProofModeKeyPair keyPair) async {
    await _secureStorage.write(key: _publicKeyKey, value: keyPair.publicKey);
    await _secureStorage.write(key: _privateKeyKey, value: keyPair.privateKey);
    await _secureStorage.write(
        key: _fingerprintKey, value: keyPair.fingerprint);
    await _secureStorage.write(
        key: _createdAtKey, value: keyPair.createdAt.toIso8601String());
  }

  /// Generate device-specific passphrase using device identifiers
  Future<String> _generateDevicePassphrase() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      String deviceId;

      if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        deviceId = iosInfo.identifierForVendor ?? 'ios-fallback';
      } else if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        deviceId = androidInfo.id;
      } else if (Platform.isMacOS) {
        final macOsInfo = await deviceInfo.macOsInfo;
        deviceId = macOsInfo.systemGUID ?? 'macos-fallback';
      } else {
        deviceId = 'generic-fallback';
      }

      // Create device-specific passphrase by hashing device ID with salt
      const salt = 'openvine_proofmode_v1';
      final passphraseData = '$salt:$deviceId';
      final hash = sha256.convert(utf8.encode(passphraseData));
      return base64Encode(hash.bytes);
    } catch (e) {
      Log.warning('Failed to generate device passphrase, using fallback: $e',
          name: 'ProofModeKeyService', category: LogCategory.auth);
      // Fallback to static passphrase if device info unavailable
      return 'openvine_proofmode_device_key_fallback';
    }
  }

  /// Generate a real PGP key pair using dart_pg
  Future<Map<String, String>> _generateSimpleKeyPair() async {
    // Generate real PGP key pair using dart_pg
    final userID = 'OpenVine ProofMode <device@openvine.co>';
    // Generate device-specific passphrase for enhanced security
    final passphrase = await _generateDevicePassphrase();

    final privateKey = OpenPGP.generateKey(
      [userID],
      passphrase,
      type: KeyType.rsa,
      rsaKeySize: RSAKeySize.normal, // 2048 bits for good performance
    );

    final publicKey = privateKey.publicKey;

    // Get fingerprint from public key (convert Uint8List to hex string)
    final fingerprintBytes = publicKey.fingerprint;
    final fingerprint = fingerprintBytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();

    return {
      'privateKey': privateKey.armor(),
      'publicKey': publicKey.armor(),
      'fingerprint': fingerprint,
    };
  }

  /// Sign data with real PGP private key
  Future<String> _signWithPrivateKey(String data, String armoredPrivateKey) async {
    // Real PGP signing using dart_pg
    final passphrase = await _generateDevicePassphrase();

    final privateKey = OpenPGP.decryptPrivateKey(armoredPrivateKey, passphrase);
    // Note: signingKeys is a POSITIONAL parameter, not named
    final signedMessage = OpenPGP.signCleartext(data, [privateKey]);

    return signedMessage.armor();
  }

  /// Verify signature with real PGP public key
  bool _verifyWithPublicKey(String data, String armoredSignedMessage, String armoredPublicKey) {
    // Real PGP verification using dart_pg
    try {
      final publicKey = OpenPGP.readPublicKey(armoredPublicKey);

      // Read the signed message to extract the text
      final signedMessage = OpenPGP.readSignedMessage(armoredSignedMessage);

      // First check: Does the embedded message text match what we expect?
      // Cast to SignedMessage to access the text property
      if (signedMessage is! SignedMessage || signedMessage.text != data) {
        return false; // Message was tampered with or wrong type
      }

      // Second check: Is the signature cryptographically valid?
      // Note: verificationKeys is a POSITIONAL parameter, not named
      final verifications = OpenPGP.verify(armoredSignedMessage, [publicKey]);

      if (verifications.isEmpty) return false;

      return verifications.first.isVerified;
    } catch (e) {
      return false;
    }
  }
}
