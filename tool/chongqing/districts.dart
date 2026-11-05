/// Map districts that can be fetched and built. Each district is a small
/// latitude/longitude box, built into its own asset so the city can grow one
/// piece at a time.
class District {
  const District({
    required this.title,
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  });

  final String title;
  final double south, west, north, east;

  double get centerLat => (south + north) / 2;
  double get centerLon => (west + east) / 2;
}

const Map<String, District> districts = {
  // Tip of the Yuzhong peninsula: Chaotianmen, Jiefangbei and where the
  // Jialing meets the Yangtze.
  'yuzhong_tip': District(
    title: 'Yuzhong Peninsula Tip',
    south: 29.552,
    west: 106.570,
    north: 29.568,
    east: 106.590,
  ),
};

District districtOrExit(List<String> args) {
  final name = args.isEmpty ? 'yuzhong_tip' : args.first;
  final d = districts[name];
  if (d == null) {
    throw ArgumentError(
      'Unknown district "$name". Known: ${districts.keys.join(', ')}',
    );
  }
  return d;
}
