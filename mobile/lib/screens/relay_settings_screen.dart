// ABOUTME: Settings screen for managing Nostr relay connections
// ABOUTME: Allows users to add, remove, and configure relay servers

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:openvine/providers/app_providers.dart';
import 'package:openvine/services/nostr_service.dart';
import 'package:openvine/theme/app_theme.dart';

class RelaySettingsScreen extends ConsumerStatefulWidget {
  const RelaySettingsScreen({super.key});

  @override
  ConsumerState<RelaySettingsScreen> createState() => _RelaySettingsScreenState();
}

class _RelaySettingsScreenState extends ConsumerState<RelaySettingsScreen> {
  final TextEditingController _relayController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isAddingRelay = false;

  @override
  void dispose() {
    _relayController.dispose();
    
    super.dispose();
  }

  void _showAddRelayDialog(dynamic nostrService) {
    showDialog(
      context: context,
      builder: (context) {
        final isDarkMode = Theme.of(context).brightness == Brightness.dark;

        return AlertDialog(
          backgroundColor: isDarkMode ? Colors.grey[900] : Colors.white,
          title: Text(
            'Add Relay',
            style: TextStyle(
              color: isDarkMode ? Colors.white : Colors.black,
            ),
          ),
          content: Form(
            key: _formKey,
            child: TextFormField(
              controller: _relayController,
              style: TextStyle(
                color: isDarkMode ? Colors.white : Colors.black,
              ),
              decoration: InputDecoration(
                hintText: 'wss://relay.example.com',
                hintStyle: TextStyle(
                  color: isDarkMode ? Colors.grey[400] : Colors.grey[600],
                ),
                prefixIcon: Icon(
                  Icons.link,
                  color: isDarkMode ? Colors.grey[400] : Colors.grey[600],
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                    color: OpenVineTheme.primaryPurple,
                    width: 2,
                  ),
                ),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter a relay URL';
                }
                if (!value.startsWith('wss://') && !value.startsWith('ws://')) {
                  return 'Relay URL must start with wss:// or ws://';
                }
                try {
                  Uri.parse(value);
                } catch (e) {
                  return 'Invalid URL format';
                }
                return null;
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                _relayController.clear();
                Navigator.of(context).pop();
              },
              child: Text(
                'Cancel',
                style: TextStyle(
                  color: isDarkMode ? Colors.grey[400] : Colors.grey[600],
                ),
              ),
            ),
            TextButton(
              onPressed: _isAddingRelay
                  ? null
                  : () async {
                      if (_formKey.currentState!.validate()) {
                        setState(() {
                          _isAddingRelay = true;
                        });

                        try {
                          await nostrService
                              .addRelay(_relayController.text.trim());
                          if (context.mounted) {
                            Navigator.of(context).pop();
                            _relayController.clear();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Relay added successfully'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Failed to add relay: $e'),
                                duration: const Duration(seconds: 3),
                              ),
                            );
                          }
                        } finally {
                          if (mounted) {
                            setState(() {
                              _isAddingRelay = false;
                            });
                          }
                        }
                      }
                    },
              child: Text(
                'Add',
                style: TextStyle(
                  color: _isAddingRelay
                      ? Colors.grey
                      : OpenVineTheme.primaryPurple,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final iNostrService = ref.read(nostrServiceProvider);

    // Check if service has relay management methods (both v1 and v2 have them)
    final nostrService = iNostrService;
    // For now, both NostrService and NostrServiceV2 have the relay management methods
    // In the future, we should add these methods to the interface

    return Scaffold(
      backgroundColor: isDarkMode ? Colors.black : Colors.white,
      appBar: AppBar(
        backgroundColor: isDarkMode ? Colors.black : Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back,
            color: isDarkMode ? Colors.white : Colors.black,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Relay Settings',
          style: TextStyle(
            color: isDarkMode ? Colors.white : Colors.black,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              Icons.refresh,
              color: isDarkMode ? Colors.white : Colors.black,
            ),
            onPressed: () async {
              await nostrService.reconnectAll();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Reconnecting to all relays...'),
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Connection Status Section
                _buildSectionHeader('Connection Status', isDarkMode),
                const SizedBox(height: 8),
                _buildConnectionStatusCard(nostrService, isDarkMode),

                const SizedBox(height: 24),

                // Active Relays Section
                _buildSectionHeader('Active Relays', isDarkMode),
                const SizedBox(height: 8),
                ...nostrService.relays.map((relay) {
                  final status = nostrService.relayStatuses[relay] ??
                      RelayStatus.disconnected;
                  return _buildRelayCard(
                    relay: relay,
                    status: status,
                    onRemove: () async {
                      // Show confirmation dialog
                      final shouldRemove = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          backgroundColor:
                              isDarkMode ? Colors.grey[900] : Colors.white,
                          title: Text(
                            'Remove Relay',
                            style: TextStyle(
                              color: isDarkMode ? Colors.white : Colors.black,
                            ),
                          ),
                          content: Text(
                            'Are you sure you want to remove $relay?',
                            style: TextStyle(
                              color: isDarkMode
                                  ? Colors.grey[300]
                                  : Colors.grey[700],
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(false),
                              child: Text(
                                'Cancel',
                                style: TextStyle(
                                  color: isDarkMode
                                      ? Colors.grey[400]
                                      : Colors.grey[600],
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(true),
                              child: const Text(
                                'Remove',
                                style: TextStyle(color: Colors.red),
                              ),
                            ),
                          ],
                        ),
                      );

                      if (shouldRemove == true) {
                        await nostrService.removeRelay(relay);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Relay removed'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        }
                      }
                    },
                    isDarkMode: isDarkMode,
                  );
                }),

                const SizedBox(height: 24),

                // Info Section
                _buildInfoCard(isDarkMode),
              ],
            ),
          ),

          // Add Relay Button
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDarkMode ? Colors.grey[900] : Colors.grey[50],
              border: Border(
                top: BorderSide(
                  color: isDarkMode ? Colors.grey[800]! : Colors.grey[300]!,
                ),
              ),
            ),
            child: SafeArea(
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => _showAddRelayDialog(nostrService),
                  icon: const Icon(Icons.add),
                  label: const Text('Add Relay'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: OpenVineTheme.primaryPurple,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, bool isDarkMode) => Text(
        title,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: isDarkMode ? Colors.white : Colors.black,
        ),
      );

  Widget _buildConnectionStatusCard(dynamic nostrService, bool isDarkMode) {
    final connectedCount = nostrService.relayStatuses.values
        .where((status) => status == RelayStatus.connected)
        .length;
    final totalCount = nostrService.relays.length;

    return Card(
      color: isDarkMode ? Colors.grey[900] : Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: connectedCount > 0
                    ? Colors.green.withValues(alpha: 0.1)
                    : Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                connectedCount > 0 ? Icons.wifi : Icons.wifi_off,
                color: connectedCount > 0 ? Colors.green : Colors.red,
                size: 28,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Connected Relays',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: isDarkMode ? Colors.white : Colors.black,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$connectedCount of $totalCount relays connected',
                    style: TextStyle(
                      fontSize: 14,
                      color: isDarkMode ? Colors.grey[400] : Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRelayCard({
    required String relay,
    required RelayStatus status,
    required VoidCallback onRemove,
    required bool isDarkMode,
  }) {
    Color statusColor;
    String statusText;
    IconData statusIcon;

    switch (status) {
      case RelayStatus.connected:
        statusColor = Colors.green;
        statusText = 'Connected';
        statusIcon = Icons.check_circle;
      case RelayStatus.connecting:
        statusColor = Colors.orange;
        statusText = 'Connecting...';
        statusIcon = Icons.sync;
      case RelayStatus.disconnected:
        statusColor = Colors.red;
        statusText = 'Disconnected';
        statusIcon = Icons.error;
    }

    return Card(
      color: isDarkMode ? Colors.grey[900] : Colors.white,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(statusIcon, color: statusColor, size: 24),
        ),
        title: Text(
          relay,
          style: TextStyle(
            color: isDarkMode ? Colors.white : Colors.black,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          statusText,
          style: TextStyle(
            color: statusColor,
            fontSize: 12,
          ),
        ),
        trailing: IconButton(
          icon: Icon(
            Icons.delete_outline,
            color: isDarkMode ? Colors.grey[400] : Colors.grey[600],
          ),
          onPressed: onRemove,
        ),
      ),
    );
  }

  Widget _buildInfoCard(bool isDarkMode) => Card(
        color: isDarkMode ? Colors.grey[900] : Colors.grey[50],
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    color: isDarkMode ? Colors.blue[300] : Colors.blue,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'About Relays',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: isDarkMode ? Colors.white : Colors.black,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Relays are servers that store and distribute Nostr events. OpenVine uses high-performance relays for all operations:\n\n• wss://relay1.openvine.co (primary relay)\n• wss://relay2.openvine.co (secondary relay)\n\nYou can add additional relays to improve reach and redundancy.',
                style: TextStyle(
                  fontSize: 13,
                  color: isDarkMode ? Colors.grey[400] : Colors.grey[600],
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      );
}
