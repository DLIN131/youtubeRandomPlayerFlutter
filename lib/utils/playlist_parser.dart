String parsePlaylistId(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return '';

  final listMatch = RegExp(r'[?&]list=([a-zA-Z0-9_-]+)').firstMatch(trimmed);
  if (listMatch != null) {
    return listMatch.group(1) ?? '';
  }

  return trimmed;
}
