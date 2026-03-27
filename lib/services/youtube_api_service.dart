import 'package:dio/dio.dart';

import '../models/playlist_video.dart';

class YoutubeApiService {
  YoutubeApiService();

  static const String _baseUrl = 'https://www.googleapis.com/youtube/v3';

  // TODO: Replace with your own API key.
  static const String _apiKey = 'AIzaSyDiWp98C7yAeOmww4UPauEGc1G0yAgYSIs';

  final Dio _dio = Dio(BaseOptions(baseUrl: _baseUrl));

  Future<List<PlaylistVideo>> fetchPlaylistItems(String playlistId, {String? oauthToken}) async {
    final List<PlaylistVideo> videos = [];
    String? pageToken;
    
    final options = oauthToken != null 
      ? Options(headers: {'Authorization': 'Bearer $oauthToken'})
      : null;

    do {
      final response = await _dio.get<Map<String, dynamic>>(
        '/playlistItems',
        queryParameters: {
          'part': 'snippet,contentDetails,status,id',
          'playlistId': playlistId,
          'maxResults': 50,
          if (oauthToken == null) 'key': _apiKey,
          if (pageToken != null) 'pageToken': pageToken,
        },
        options: options,
      );

      final data = response.data ?? <String, dynamic>{};
      final items = (data['items'] as List<dynamic>? ?? <dynamic>[])
          .whereType<Map<String, dynamic>>();

      for (final item in items) {
        final snippet = item['snippet'] as Map<String, dynamic>? ?? {};
        final title = (snippet['title'] ?? '').toString();
        if (title == 'Deleted video' || title == 'Private video') continue;

        final video = PlaylistVideo.fromPlaylistItem(item);
        if (video.videoId.isEmpty) continue;
        videos.add(video);
      }

      pageToken = data['nextPageToken'] as String?;
    } while (pageToken != null);

    return videos;
  }

  Future<String?> fetchPlaylistTitle(String playlistId) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/playlists',
      queryParameters: {
        'part': 'snippet',
        'id': playlistId,
        'key': _apiKey,
      },
    );

    final data = response.data ?? <String, dynamic>{};
    final items = data['items'] as List<dynamic>?;
    if (items == null || items.isEmpty) return null;

    final first = items.first as Map<String, dynamic>;
    final snippet = first['snippet'] as Map<String, dynamic>?;
    return snippet?['title']?.toString();
  }

  Future<List<Map<String, dynamic>>> fetchMyPlaylists(String oauthToken) async {
    final List<Map<String, dynamic>> playlists = [];
    String? pageToken;

    do {
      final response = await _dio.get<Map<String, dynamic>>(
        '/playlists',
        options: Options(
          headers: {
            'Authorization': 'Bearer $oauthToken',
            'Accept': 'application/json',
          },
        ),
        queryParameters: {
          'part': 'snippet,status',
          'mine': 'true',
          'maxResults': 50,
          if (pageToken != null) 'pageToken': pageToken,
        },
      );

      final data = response.data ?? <String, dynamic>{};
      final items = (data['items'] as List<dynamic>? ?? <dynamic>[])
          .whereType<Map<String, dynamic>>();

      for (final item in items) {
        final snippet = item['snippet'] as Map<String, dynamic>? ?? {};
        final title = (snippet['title'] ?? '').toString();
        final id = (item['id'] ?? '').toString();
        if (id.isNotEmpty && title.isNotEmpty) {
          playlists.add({
            'name': title,
            'value': id,
          });
        }
      }

      pageToken = data['nextPageToken'] as String?;
    } while (pageToken != null);

    return playlists;
  }

  Future<List<PlaylistVideo>> searchVideos(String query) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/search',
      queryParameters: {
        'part': 'snippet',
        'q': query,
        'type': 'video',
        'maxResults': 25,
        'key': _apiKey,
      },
    );

    final data = response.data ?? <String, dynamic>{};
    final items = (data['items'] as List<dynamic>? ?? <dynamic>[])
        .whereType<Map<String, dynamic>>();

    final List<PlaylistVideo> results = [];
    for (int i = 0; i < items.length; i++) {
      final item = items.elementAt(i);
      final snippet = item['snippet'] as Map<String, dynamic>? ?? {};
      final videoId = (item['id']?['videoId'] ?? '').toString();
      if (videoId.isEmpty) continue;

      results.add(PlaylistVideo(
        id: videoId,
        videoId: videoId,
        title: (snippet['title'] ?? '').toString(),
        thumbnailUrl: (snippet['thumbnails']?['medium']?['url'] ?? 
                       snippet['thumbnails']?['default']?['url'] ?? '').toString(),
        position: i,
      ));
    }
    return results;
  }

  Future<bool> checkVideoInPlaylist(String playlistId, String videoId, String oauthToken) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/playlistItems',
      queryParameters: {
        'part': 'id',
        'playlistId': playlistId,
        'videoId': videoId,
        'maxResults': 1,
      },
      options: Options(
        headers: {
          'Authorization': 'Bearer $oauthToken',
        },
      ),
    );

    final data = response.data ?? <String, dynamic>{};
    final items = data['items'] as List<dynamic>?;
    return items != null && items.isNotEmpty;
  }

  Future<void> addVideoToPlaylist(String playlistId, String videoId, String oauthToken) async {
    await _dio.post(
      '/playlistItems',
      queryParameters: {
        'part': 'snippet',
      },
      options: Options(
        headers: {
          'Authorization': 'Bearer $oauthToken',
          'Content-Type': 'application/json',
        },
      ),
      data: {
        'snippet': {
          'playlistId': playlistId,
          'resourceId': {
            'kind': 'youtube#video',
            'videoId': videoId,
          },
        },
      },
    );
  }
}

