// ABOUTME: Welcome screen for new users with onboarding flow for Nostr identity setup
// ABOUTME: Provides options to create new identity or import existing keys with TOS acceptance and age verification

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:openvine/providers/app_providers.dart';
import 'package:openvine/screens/key_import_screen.dart';
import 'package:openvine/screens/profile_setup_screen.dart';
import 'package:openvine/theme/vine_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:go_router/go_router.dart';

class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  bool _isOver16 = false;
  bool _agreedToTerms = false;
  bool _isAccepting = false;

  @override
  Widget build(BuildContext context) {
    final authService = ref.watch(authServiceProvider);
    final isAuthenticated = authService.isAuthenticated;

    return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 40),
                // App branding - diVine wordmark
                Image.asset(
                  'assets/icon/White on black.png',
                  height: 60,
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: 24),
                Text(
                  'Welcome to diVine',
                  style: GoogleFonts.pacifico(
                    fontSize: 32,
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Create and share short videos on the decentralized web',
                  style: TextStyle(
                    fontSize: 18,
                    color: Colors.grey,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),

                // Age verification and TOS acceptance
                _buildCheckboxSection(),

                const SizedBox(height: 32),

                // Main action buttons
                if (isAuthenticated)
                  // If already authenticated, just show Continue button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _canProceed && !_isAccepting
                          ? () => _acceptTermsAndContinue(context)
                          : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: VineTheme.vineGreen,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.grey[800],
                        disabledForegroundColor: Colors.grey[600],
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: _isAccepting
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const Text(
                              'Continue',
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w600),
                            ),
                    ),
                  )
                else ...[
                  // If not authenticated, show identity creation/import options
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _canProceed
                          ? () => _createNewIdentity(context, ref)
                          : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: VineTheme.vineGreen,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.grey[800],
                        disabledForegroundColor: Colors.grey[600],
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Create New Identity',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _canProceed
                          ? () => _importExistingIdentity(context)
                          : null,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        disabledForegroundColor: Colors.grey[600],
                        side: BorderSide(
                            color:
                                _canProceed ? Colors.white : Colors.grey[800]!),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Import Existing Identity',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 32),

                // Educational content
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.grey[900],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.info_outline,
                        color: VineTheme.vineGreen,
                        size: 24,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'What is diVine?',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'diVine is reviving the dream of 6 second looping videos, by and for humans. Do it for the vine!',
                        style: TextStyle(
                          color: Colors.grey[300],
                          fontSize: 14,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      );
  }

  Widget _buildCheckboxSection() => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: VineTheme.cardBackground,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey[800]!),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Age verification checkbox
            InkWell(
              onTap: () => setState(() => _isOver16 = !_isOver16),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Checkbox(
                      value: _isOver16,
                      onChanged: (value) =>
                          setState(() => _isOver16 = value ?? false),
                      activeColor: VineTheme.vineGreen,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'I am 16 years or older',
                      style: TextStyle(
                        color: VineTheme.whiteText,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // TOS acceptance checkbox with links
            InkWell(
              onTap: () => setState(() => _agreedToTerms = !_agreedToTerms),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Checkbox(
                      value: _agreedToTerms,
                      onChanged: (value) =>
                          setState(() => _agreedToTerms = value ?? false),
                      activeColor: VineTheme.vineGreen,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: const TextStyle(
                          color: VineTheme.whiteText,
                          fontSize: 14,
                        ),
                        children: [
                          const TextSpan(text: 'I agree to the '),
                          TextSpan(
                            text: 'Terms of Service',
                            style: const TextStyle(
                              color: VineTheme.vineGreen,
                              decoration: TextDecoration.underline,
                            ),
                            recognizer: TapGestureRecognizer()
                              ..onTap = () => _openUrl('https://divine.video/terms'),
                          ),
                          const TextSpan(text: ', '),
                          TextSpan(
                            text: 'Privacy Policy',
                            style: const TextStyle(
                              color: VineTheme.vineGreen,
                              decoration: TextDecoration.underline,
                            ),
                            recognizer: TapGestureRecognizer()
                              ..onTap =
                                  () => _openUrl('https://divine.video/privacy'),
                          ),
                          const TextSpan(text: ', and '),
                          TextSpan(
                            text: 'Safety Standards',
                            style: const TextStyle(
                              color: VineTheme.vineGreen,
                              decoration: TextDecoration.underline,
                            ),
                            recognizer: TapGestureRecognizer()
                              ..onTap =
                                  () => _openUrl('https://divine.video/safety'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  bool get _canProceed => _isOver16 && _agreedToTerms;

  Future<void> _openUrl(String urlString) async {
    final uri = Uri.parse(urlString);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _createNewIdentity(BuildContext context, WidgetRef ref) async {
    final authService = ref.read(authServiceProvider);

    // Store terms acceptance
    await _storeTermsAcceptance();

    // Generate new identity
    final result = await authService.createNewIdentity();

    if (result.success && context.mounted) {
      // Navigate to profile setup
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => const ProfileSetupScreen(isNewUser: true),
        ),
      );
    } else if (context.mounted) {
      // Show error
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.errorMessage ?? 'Failed to create identity'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _importExistingIdentity(BuildContext context) async {
    // Store terms acceptance
    await _storeTermsAcceptance();

    if (context.mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => const KeyImportScreen(),
        ),
      );
    }
  }

  Future<void> _storeTermsAcceptance() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('terms_accepted_at', DateTime.now().toIso8601String());
    await prefs.setBool('age_verified_16_plus', true);
  }

  Future<void> _acceptTermsAndContinue(BuildContext context) async {
    setState(() => _isAccepting = true);

    try {
      // Store terms acceptance
      await _storeTermsAcceptance();

      if (context.mounted) {
        // Navigate to home
        context.go('/home/0');
      }
    } finally {
      if (mounted) {
        setState(() => _isAccepting = false);
      }
    }
  }
}
