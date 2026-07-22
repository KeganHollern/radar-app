import 'dart:async';

import 'package:flutter/material.dart';

import '../models/radar_models.dart';

class RadarScanStatusText extends StatefulWidget {
  const RadarScanStatusText({
    super.key,
    required this.renderedSnapshot,
    required this.isLoading,
    required this.unavailable,
    this.style,
    this.now,
  });

  final RadarSnapshot? renderedSnapshot;
  final bool isLoading;
  final bool unavailable;
  final TextStyle? style;
  final DateTime Function()? now;

  @override
  State<RadarScanStatusText> createState() => _RadarScanStatusTextState();
}

class _RadarScanStatusTextState extends State<RadarScanStatusText> {
  static const _ageRefreshInterval = Duration(seconds: 10);

  Timer? _ageTimer;

  @override
  void initState() {
    super.initState();
    _syncAgeTimer();
  }

  @override
  void didUpdateWidget(RadarScanStatusText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.renderedSnapshot == null) !=
        (widget.renderedSnapshot == null)) {
      _syncAgeTimer();
    }
  }

  void _syncAgeTimer() {
    if (widget.renderedSnapshot == null) {
      _ageTimer?.cancel();
      _ageTimer = null;
      return;
    }
    _ageTimer ??= Timer.periodic(_ageRefreshInterval, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final presentation = radarScanStatusPresentation(
      renderedSnapshot: widget.renderedSnapshot,
      isLoading: widget.isLoading,
      unavailable: widget.unavailable,
      now: widget.now?.call() ?? DateTime.now(),
    );
    return Semantics(
      label: presentation.semanticLabel,
      child: ExcludeSemantics(
        child: Text(
          presentation.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: widget.style,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _ageTimer?.cancel();
    super.dispose();
  }
}

final class RadarScanStatusPresentation {
  const RadarScanStatusPresentation({
    required this.text,
    required this.semanticLabel,
  });

  final String text;
  final String semanticLabel;
}

RadarScanStatusPresentation radarScanStatusPresentation({
  required RadarSnapshot? renderedSnapshot,
  required bool isLoading,
  required bool unavailable,
  required DateTime now,
}) {
  if (renderedSnapshot == null) {
    if (isLoading) {
      return const RadarScanStatusPresentation(
        text: 'Connecting…',
        semanticLabel: 'Connecting to live radar',
      );
    }
    return const RadarScanStatusPresentation(
      text: 'Waiting for live scan',
      semanticLabel: 'Waiting for a live radar scan',
    );
  }

  final observedAt = renderedSnapshot.observedAt.toLocal();
  final clockTime = _formatClockTime(observedAt);
  final age = _formatAge(now.difference(observedAt));
  if (unavailable) {
    return RadarScanStatusPresentation(
      text: 'Last scan $clockTime · ${age.compact}',
      semanticLabel: 'Last rendered radar scan at $clockTime, ${age.semantic}',
    );
  }
  if (renderedSnapshot.stale) {
    return RadarScanStatusPresentation(
      text: 'Stale scan $clockTime · ${age.compact}',
      semanticLabel: 'Stale radar scan at $clockTime, ${age.semantic}',
    );
  }
  return RadarScanStatusPresentation(
    text: 'Scan $clockTime · ${age.compact}',
    semanticLabel: 'Radar scan at $clockTime, ${age.semantic}',
  );
}

String _formatClockTime(DateTime time) {
  final hour = time.hour == 0
      ? 12
      : (time.hour > 12 ? time.hour - 12 : time.hour);
  final minute = time.minute.toString().padLeft(2, '0');
  final period = time.hour >= 12 ? 'PM' : 'AM';
  return '$hour:$minute $period';
}

({String compact, String semantic}) _formatAge(Duration age) {
  if (age.isNegative || age.inSeconds < 10) {
    return (compact: 'just now', semantic: 'just now');
  }
  if (age.inMinutes < 1) {
    final seconds = age.inSeconds;
    return (
      compact: '${seconds}s ago',
      semantic: '$seconds ${seconds == 1 ? 'second' : 'seconds'} ago',
    );
  }
  if (age.inHours < 1) {
    final minutes = age.inMinutes;
    return (
      compact: '${minutes}m ago',
      semantic: '$minutes ${minutes == 1 ? 'minute' : 'minutes'} ago',
    );
  }
  final hours = age.inHours;
  return (
    compact: '${hours}h ago',
    semantic: '$hours ${hours == 1 ? 'hour' : 'hours'} ago',
  );
}
