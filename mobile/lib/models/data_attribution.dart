/// One visible data-provider credit and its official destination.
final class DataAttribution {
  const DataAttribution({required this.label, required this.url});

  final String label;
  final String url;

  Uri? get uri {
    final parsed = Uri.tryParse(url);
    return parsed != null && parsed.hasScheme ? parsed : null;
  }
}
