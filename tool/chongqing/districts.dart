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

/// Every district is projected around this one point, so districts built
/// separately line up exactly when loaded side by side.
const double cityOriginLat = 29.56, cityOriginLon = 106.58;

/// One river surface for the whole city (metres). The elevation data is
/// noisy over water; this is the level measured for the Yuzhong tip
/// (25th percentile of ground minus 1 m) and is used everywhere so the river
/// has no steps between districts.
const double cityRiverLevel = 160.7;

/// Target terrain grid step (metres). The real step is adjusted per district
/// so the grid ends exactly on the district's edges.
const double terrainStep = 8.0;

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
  // West along the Jialing: People's Square and the Great Hall, Liziba (where
  // Line 2 runs through a building) and the elevated Line 2 riverside line.
  // Its east edge is exactly yuzhong_tip's west edge.
  'jialing_riverside': District(
    title: 'Jialing Riverside',
    south: 29.550,
    west: 106.525,
    north: 29.570,
    east: 106.570,
  ),
  // Across the Yangtze from the tip: Shangxin Street (the cableway's south
  // station) and the Nan'an hillside. Its west edge is yuzhong_tip's east
  // edge and nanbin_road's east edge.
  'nanan_riverside': District(
    title: "Nan'an Riverside",
    south: 29.540,
    west: 106.590,
    north: 29.568,
    east: 106.606,
  ),
  // The south bank opposite Yuzhong: the Nanbin Road riverfront. Its north
  // edge is exactly yuzhong_tip's south edge.
  'nanbin_road': District(
    title: 'Nanbin Road',
    south: 29.540,
    west: 106.570,
    north: 29.552,
    east: 106.590,
  ),
  // Across the Jialing to the north: Jiangbeizui, the Grand Theatre and the
  // Jiangbei CBD. Its south edge is exactly yuzhong_tip's north edge.
  'jiangbeizui': District(
    title: 'Jiangbeizui',
    south: 29.568,
    west: 106.570,
    north: 29.580,
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
