/// Heights (m) for well-known towers whose OpenStreetMap entry has no height
/// or floor count. Matched by a substring of the English or Chinese name.
/// Only add entries with a published height.
const Map<String, double> _knownHeights = {
  'World Financial Center': 339,
  '环球金融中心': 339,
  'World Trade Centre': 283,
  'World Trade Center': 283,
  '世界贸易中心': 283,
};

double? landmarkHeight(Map<String, dynamic> tags) {
  final names = [
    tags['name:en'],
    tags['name'],
    tags['name:zh'],
  ].whereType<String>();
  for (final n in names) {
    for (final e in _knownHeights.entries) {
      if (n.contains(e.key)) return e.value;
    }
  }
  return null;
}
