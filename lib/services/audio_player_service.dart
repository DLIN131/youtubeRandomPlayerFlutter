
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/playlist_video.dart';

class AudioPlayerService {
  AudioPlayerService();

  static const String _fallbackAudioBaseUrl =
      'https://ytdl-server-byvu.onrender.com/download';
  static const bool _enableBackendFallback = true;
  static const Duration _setSourceTimeout = Duration(seconds: 15);
  static const Duration _rateLimitCooldown = Duration(minutes: 20);

  final AudioPlayer player = AudioPlayer();
  final YoutubeExplode _yt = YoutubeExplode();

  DateTime? _rateLimitedUntil;

  Future<void> playVideo(PlaylistVideo video) async {
    if (kIsWeb) {
      throw UnsupportedError('Web playback blocked by CORS.');
    }

    final limitedUntil = _rateLimitedUntil;
    if (limitedUntil != null && DateTime.now().isBefore(limitedUntil)) {
      throw RateLimitedPlaybackException(
          limitedUntil.difference(DateTime.now()));
    }

    final mediaItem = MediaItem(
      id: video.videoId,
      title: video.title,
      artist: 'YouTube Playlist',
      artUri:
          video.thumbnailUrl.isEmpty ? null : Uri.tryParse(video.thumbnailUrl),
    );

    final playedDirectly = await _tryPlayDirect(video, mediaItem);
    if (playedDirectly) {
      return;
    }

    if (_enableBackendFallback) {
      debugPrint(
          'Direct audio playback failed for ${video.videoId}, trying backend fallback.');
      final playedByBackend = await _tryPlayBackend(video, mediaItem);
      if (playedByBackend) {
        return;
      }

      throw Exception(
          'Unable to play this video audio right now (both direct and backend failed).');
    }

    throw Exception(
        'Unable to play this video audio right now (direct source failed).');
  }

  Future<void> pause() => player.pause();

  Future<void> resume() => player.play();

  Future<void> seekBy(Duration offset) async {
    final current = player.position;
    var nextPosition = current + offset;
    if (nextPosition < Duration.zero) {
      nextPosition = Duration.zero;
    }

    final duration = player.duration;
    if (duration != null && nextPosition > duration) {
      nextPosition = duration;
    }

    await player.seek(nextPosition);
  }

  Future<void> setVolume(double value) => player.setVolume(value);

  Future<void> dispose() async {
    _yt.close();
    await player.dispose();
  }

  Future<bool> _tryPlayDirect(PlaylistVideo video, MediaItem mediaItem) async {
    // These clients return pre-signed stream URLs that can be played
    // without special cookies/tokens - unlike the default web client.
    // tv and androidVr are the most reliable for direct playback.
    final clientsToTry = <YoutubeApiClient>[
      YoutubeApiClient.tv,
      YoutubeApiClient.androidVr,
      YoutubeApiClient.ios,
    ];

    for (final client in clientsToTry) {
      try {
        final manifest = await _yt.videos.streams.getManifest(
          video.videoId,
          ytClients: [client],
        );
        final audioStreams = manifest.audioOnly.toList()
          ..sort((a, b) =>
              b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));

        if (audioStreams.isEmpty) continue;

        final stream = audioStreams.first;
        final url = stream.url.toString();

        await _setAndPlaySource(url: url, tag: mediaItem);
        debugPrint(
          'Direct playback succeeded for ${video.videoId} '
          'using client ${client.runtimeType} '
          '(itag=${stream.tag}, bitrate=${stream.bitrate.bitsPerSecond}).',
        );
        return true;
      } on RequestLimitExceededException catch (e) {
        _rateLimitedUntil = DateTime.now().add(_rateLimitCooldown);
        debugPrint(
          'Rate-limited by YouTube for ${video.videoId}: $e. '
          'Cooldown until $_rateLimitedUntil',
        );
        throw RateLimitedPlaybackException(_rateLimitCooldown);
      } catch (e) {
        debugPrint(
            'Client ${client.runtimeType} failed for ${video.videoId}: $e');
      }
    }

    debugPrint('All direct clients failed for ${video.videoId}.');
    return false;
  }

  Future<bool> _tryPlayBackend(PlaylistVideo video, MediaItem mediaItem) async {
    final url = '$_fallbackAudioBaseUrl/${video.videoId}';
    // Skip probe; just attempt to play. The _setSourceTimeout will catch failures.
    try {
      await _setAndPlaySource(url: url, tag: mediaItem);
      debugPrint('Backend playback succeeded for ${video.videoId}.');
      return true;
    } catch (e) {
      debugPrint('Backend playback failed for ${video.videoId}: $e');
      return false;
    }
  }

  Future<void> _setAndPlaySource({
    required String url,
    required MediaItem tag,
    Map<String, String>? headers,
  }) async {
    await player.stop();

    final source = AudioSource.uri(
      Uri.parse(url),
      tag: tag,
      headers: headers,
    );
    await player.setAudioSource(source).timeout(_setSourceTimeout);
    await player.play();
  }
}

class RateLimitedPlaybackException implements Exception {
  const RateLimitedPlaybackException(this.retryAfter);

  final Duration retryAfter;

  @override
  String toString() {
    final minutes = retryAfter.inMinutes < 1 ? 1 : retryAfter.inMinutes;
    return 'YouTube is rate-limiting this IP. Retry after about $minutes minute(s).';
  }
}
