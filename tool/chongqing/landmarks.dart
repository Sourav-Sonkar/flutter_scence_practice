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

/// Places visitors know Chongqing by, in chip order: the display name and
/// the exact OpenStreetMap `name` of the feature that marks it (a building,
/// area, park or the cableway line). Each district picks up the ones whose
/// feature centre falls inside it.
const List<(String, String)> famousPlaces = [
  ('Hongyadong', '洪崖洞'),
  ('Jiefangbei', '抗战胜利纪功碑暨人民解放纪念碑'),
  ('Raffles City', '重庆来福士广场'),
  ('Chaotianmen', '朝天门广场'),
  ('Yangtze River Cableway', '长江索道'),
  ('Eighteen Stairs', '重庆十八梯传统风貌区'),
  ('Chongqing Grand Theatre', '重庆大剧院'),
  ('Longmenhao Old Street', '龙门浩老街'),
  ('Nanshan One Tree', '一棵树观景台'),
  ('Nanbin Park', '南滨公园'),
];
