import 'package:flutter/material.dart';

import '../Themes/app_fonts.dart';
import '../Themes/ember.dart';

enum UpdateChoice { updateNow, later, skip }

/// "A new version is available" dialog, in the Ember palette.
///
/// [blocking] shows only "Update now" and cannot be closed by back or a
/// barrier tap. Otherwise the user also gets "Later" and "Skip this version".
/// With no [canOpenStore] (no store link known for the platform) the
/// update button is replaced by a line telling the user where to go.
class UpdateDialog extends StatelessWidget {
  const UpdateDialog({
    super.key,
    required this.latestVersion,
    required this.blocking,
    this.releaseNotes,
    this.canOpenStore = true,
    this.storeName = 'the store',
  });

  final String latestVersion;
  final String? releaseNotes;
  final bool blocking;
  final bool canOpenStore;
  final String storeName;

  @override
  Widget build(BuildContext context) {
    final body = Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final notes = releaseNotes;
    return PopScope(
      canPop: !blocking,
      child: Dialog(
        backgroundColor: Ember.surface,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Ember.radiusCard),
          side: const BorderSide(color: Ember.outline),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.system_update_alt_rounded,
                  color: Ember.accent, size: 28),
              const SizedBox(height: 14),
              Text(
                blocking ? 'Update required' : 'Update available',
                style: AppFonts.displayStyle(
                  fontSize: 24,
                  color: Ember.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Hype Muzik $latestVersion is out.'
                '${blocking ? ' Please update to keep using the app.' : ''}',
                style: body.copyWith(color: Ember.textSecondary),
              ),
              if (notes != null) ...[
                const SizedBox(height: 18),
                Text(
                  "WHAT'S NEW",
                  style: body.copyWith(
                    color: Ember.accent,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: Scrollbar(
                      child: SingleChildScrollView(
                        child: Text(
                          notes,
                          key: const Key('update-notes'),
                          style: body.copyWith(
                            color: Ember.textPrimary,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              if (canOpenStore)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const Key('update-now'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Ember.accent,
                      // Gold is light: the label must be dark.
                      foregroundColor: Ember.ground,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Ember.radiusControl),
                      ),
                      textStyle: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    onPressed: () =>
                        Navigator.of(context).pop(UpdateChoice.updateNow),
                    child: const Text('Update now'),
                  ),
                )
              else
                Text(
                  'Update from $storeName.',
                  key: const Key('update-store-hint'),
                  style: body.copyWith(
                    color: Ember.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              if (!blocking) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        key: const Key('update-later'),
                        style: TextButton.styleFrom(
                          foregroundColor: Ember.textSecondary,
                        ),
                        onPressed: () =>
                            Navigator.of(context).pop(UpdateChoice.later),
                        child: const Text('Later'),
                      ),
                    ),
                    Expanded(
                      child: TextButton(
                        key: const Key('update-skip'),
                        style: TextButton.styleFrom(
                          foregroundColor: Ember.textTertiary,
                        ),
                        onPressed: () =>
                            Navigator.of(context).pop(UpdateChoice.skip),
                        child: const Text('Skip this version'),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
