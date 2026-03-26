import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/playlist_video.dart';

class LocalStorageService {
  static const String _playlistKey = 'saved_local_playlist_data';
  static const String _playlistTitleKey = 'saved_local_playlist_title';

  Future<void> saveCurrentPlaylist(List<PlaylistVideo> videos, String title) async {
    final prefs = await SharedPreferences.getInstance();
    if (videos.isEmpty) {
      await prefs.remove(_playlistKey);
      await prefs.remove(_playlistTitleKey);
      return;
    }

    final String jsonString = jsonEncode(videos.map((v) => v.toJson()).toList());
    await prefs.setString(_playlistKey, jsonString);
    await prefs.setString(_playlistTitleKey, title);
  }

  Future<Map<String, dynamic>?> loadCurrentPlaylist() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_playlistKey);
    final title = prefs.getString(_playlistTitleKey) ?? 'Local Playlist';

    if (jsonString == null || jsonString.isEmpty) {
      return null;
    }

    try {
      final List<dynamic> jsonList = jsonDecode(jsonString);
      final List<PlaylistVideo> videos = jsonList
          .map((item) => PlaylistVideo.fromJson(item as Map<String, dynamic>))
          .toList();

      return {
        'videos': videos,
        'title': title,
      };
    } catch (e) {
      return null;
    }
  }
}
