import 'package:flutter/material.dart';

import '../themes/ember.dart';

const Color _kAccent = Ember.accent;

/// The equalizer's preset list: pick, delete, save, and the Auto save switch.
///
/// Takes everything it shows as parameters, so it carries no controller. The
/// caller rebuilds it as the state changes.
///
/// A selected preset whose curve has been edited but not saved reads
/// `Name *`. "Save" (write the curve into the selected preset) appears only
/// then, and never while [autoSave] is on, since with Auto save on an edit is
/// already in the preset.
class EqPresetSheet extends StatefulWidget {
  const EqPresetSheet({
    super.key,
    required this.names,
    required this.builtIns,
    required this.selected,
    required this.dirty,
    required this.autoSave,
    required this.onApply,
    required this.onDelete,
    required this.onAutoSave,
    required this.onSave,
    required this.onSaveAs,
  });

  final List<String> names;
  final Set<String> builtIns;
  final String selected;
  final bool dirty;
  final bool autoSave;
  final ValueChanged<String> onApply;
  final ValueChanged<String> onDelete;
  final ValueChanged<bool> onAutoSave;
  final VoidCallback onSave;
  final VoidCallback onSaveAs;

  @override
  State<EqPresetSheet> createState() => _EqPresetSheetState();
}

class _EqPresetSheetState extends State<EqPresetSheet> {
  String _query = '';
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _confirmDelete(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $name?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) widget.onDelete(name);
  }

  @override
  Widget build(BuildContext context) {
    final names = widget.names;
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? names
        : names.where((n) => n.toLowerCase().contains(q)).toList();
    final screenH = MediaQuery.of(context).size.height;
    final showSave =
        widget.dirty && !widget.autoSave && names.contains(widget.selected);

    // A Material, not a decorated box: the Auto save tile paints on the
    // nearest Material and would be hidden behind a coloured box.
    return Material(
      color: const Color(0xFF1A1A1A),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: screenH * 0.6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
              child: Row(
                children: [
                  const Icon(Icons.tune_rounded, color: _kAccent, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'EQ Presets',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (showSave)
                    TextButton(
                      onPressed: widget.onSave,
                      style: TextButton.styleFrom(
                        foregroundColor: _kAccent,
                        textStyle: const TextStyle(fontSize: 13),
                      ),
                      child: const Text('Save'),
                    ),
                  TextButton.icon(
                    onPressed: widget.onSaveAs,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Save as'),
                    style: TextButton.styleFrom(
                      foregroundColor: _kAccent,
                      textStyle: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              value: widget.autoSave,
              onChanged: widget.onAutoSave,
              activeThumbColor: _kAccent,
              activeTrackColor: _kAccent.withValues(alpha: 0.5),
              title: const Text(
                'Auto save',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              subtitle: Text(
                widget.autoSave
                    ? 'Changes go into the selected preset'
                    : 'Changes stay unsaved until you save',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 11,
                ),
              ),
            ),
            if (names.length > 8)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _searchController,
                  onChanged: (v) => setState(() => _query = v),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Search presets...',
                    hintStyle: TextStyle(
                      color: Colors.white.withValues(alpha: 0.3),
                    ),
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      size: 20,
                      color: Colors.white.withValues(alpha: 0.3),
                    ),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.08),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).padding.bottom + 16,
                ),
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final name = filtered[index];
                  final isSelected = name == widget.selected;
                  return _PresetTile(
                    name: name,
                    label: isSelected && widget.dirty ? '$name *' : name,
                    isActive: isSelected,
                    isUser: !widget.builtIns.contains(name),
                    onTap: () => widget.onApply(name),
                    onDelete: () => _confirmDelete(name),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.name,
    required this.label,
    required this.isActive,
    required this.isUser,
    required this.onTap,
    required this.onDelete,
  });

  final String name;
  final String label;
  final bool isActive;
  final bool isUser;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  IconData get _icon {
    final lower = name.toLowerCase();
    if (lower.contains('bass')) return Icons.speaker_rounded;
    if (lower.contains('rock')) return Icons.whatshot_rounded;
    if (lower.contains('pop')) return Icons.stars_rounded;
    if (lower.contains('jazz')) return Icons.piano_rounded;
    if (lower.contains('classical')) return Icons.music_note_rounded;
    if (lower.contains('vocal') || lower.contains('voice')) {
      return Icons.mic_rounded;
    }
    if (lower.contains('dance') || lower.contains('edm')) {
      return Icons.nightlife_rounded;
    }
    if (lower.contains('flat')) return Icons.horizontal_rule_rounded;
    if (lower.contains('treble')) return Icons.graphic_eq_rounded;
    if (lower.contains('loudness')) return Icons.volume_up_rounded;
    if (isUser) return Icons.person_rounded;
    return Icons.equalizer_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.only(left: 16, right: 4, top: 4, bottom: 4),
        color: isActive ? _kAccent.withValues(alpha: 0.1) : null,
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: isActive
                    ? _kAccent.withValues(alpha: 0.2)
                    : Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                _icon,
                size: 18,
                color: isActive
                    ? _kAccent
                    : Colors.white.withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: isActive
                          ? _kAccent
                          : Colors.white.withValues(alpha: 0.85),
                      fontSize: 14,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (isUser)
                    Text(
                      'Custom preset',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.35),
                      ),
                    ),
                ],
              ),
            ),
            if (isActive)
              const Icon(Icons.check_rounded, color: _kAccent, size: 20),
            IconButton(
              tooltip: 'Delete $name',
              onPressed: onDelete,
              icon: Icon(
                Icons.delete_outline_rounded,
                size: 18,
                color: Colors.white.withValues(alpha: 0.25),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
