import 'package:flutter/material.dart';

import '../theme/flexoki_theme.dart';

/// A compact, accessible status action for transient map-level problems.
///
/// While [loading] is true the action remains visibly present, exposes a live
/// progress label to assistive technology, and cannot be tapped repeatedly.
class StatusBanner extends StatelessWidget {
  const StatusBanner({
    super.key,
    required this.icon,
    required this.message,
    this.onTap,
    this.loading = false,
    this.semanticLabel,
    this.loadingSemanticLabel,
  });

  final IconData icon;
  final String message;
  final VoidCallback? onTap;
  final bool loading;
  final String? semanticLabel;
  final String? loadingSemanticLabel;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !loading;
    final announcedLabel = loading
        ? loadingSemanticLabel ?? semanticLabel ?? message
        : semanticLabel ?? message;

    return Semantics(
      container: true,
      liveRegion: loading,
      button: onTap != null,
      enabled: enabled,
      label: announcedLabel,
      onTap: enabled ? onTap : null,
      child: ExcludeSemantics(
        child: Material(
          color: Flexoki.base100.withValues(alpha: 0.96),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Flexoki.base300),
          ),
          child: InkWell(
            key: const ValueKey('status-banner-action'),
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(14),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    Icon(icon, size: 19, color: Flexoki.yellow),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    if (loading)
                      const SizedBox.square(
                        key: ValueKey('status-banner-progress'),
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else if (onTap != null)
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: Flexoki.base500,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
