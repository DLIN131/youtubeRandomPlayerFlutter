class PlaylistVideo {
  const PlaylistVideo({
    required this.id,
    required this.videoId,
    required this.title,
    required this.thumbnailUrl,
    required this.position,
  });

  final String id;
  final String videoId;
  final String title;
  final String thumbnailUrl;
  final int position;

  factory PlaylistVideo.fromPlaylistItem(Map<String, dynamic> item) {
    final snippet = item['snippet'] as Map<String, dynamic>? ?? {};
    final thumbnails = snippet['thumbnails'] as Map<String, dynamic>? ?? {};
    final medium = thumbnails['medium'] as Map<String, dynamic>? ?? {};
    final resourceId = snippet['resourceId'] as Map<String, dynamic>? ?? {};

    return PlaylistVideo(
      id: (item['id'] ?? '').toString(),
      videoId: (resourceId['videoId'] ?? '').toString(),
      title: (snippet['title'] ?? '').toString(),
      thumbnailUrl: (medium['url'] ?? '').toString(),
      position: (snippet['position'] as num? ?? 0).toInt(),
    );
  }

  factory PlaylistVideo.fromJson(Map<String, dynamic> json) {
    return PlaylistVideo(
      id: (json['id'] ?? '').toString(),
      videoId: (json['videoId'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      thumbnailUrl: (json['thumbnailUrl'] ?? '').toString(),
      position: (json['position'] as num? ?? 0).toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'videoId': videoId,
      'title': title,
      'thumbnailUrl': thumbnailUrl,
      'position': position,
    };
  }
}

