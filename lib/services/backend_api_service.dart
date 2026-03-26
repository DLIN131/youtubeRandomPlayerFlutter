import 'package:dio/dio.dart';

import '../models/playlist_video.dart';

class BackendApiService {
  static const String _baseUrl = 'https://ytdl-server-byvu.onrender.com';
  
  final Dio _dio = Dio(BaseOptions(
    baseUrl: _baseUrl,
    receiveTimeout: const Duration(seconds: 20),
    connectTimeout: const Duration(seconds: 20),
  ));

  Future<List<String>> fetchPlaylistNames(String userId) async {
    try {
      final res = await _dio.get('/playlist/listname', queryParameters: {
        'userId': userId,
      });
      if (res.statusCode == 200) {
        final listnames = res.data['data']['listnames'] as List;
        return listnames.map((e) => e.toString()).toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  Future<List<PlaylistVideo>> fetchPlaylistData(String userId, String listname) async {
    try {
      final res = await _dio.get('/playlist', queryParameters: {
        'userId': userId,
        'listname': listname,
      });
      if (res.statusCode == 200) {
        final data = res.data['data']['data']['playlist'] as List;
        return data.map((e) => PlaylistVideo.fromJson(e)).toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }
  
  // Other methods (post, update, delete) can be implemented similarly if needed.
}
