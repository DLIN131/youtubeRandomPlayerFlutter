import 'dart:io';

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
  static const int _maxDirectCandidatesPerClientSet = 3;
  static const Duration _backendProbeTimeout = Duration(seconds: 1);
  static const Duration _setSourceTimeout = Duration(seconds: 5);
  static const Duration _rateLimitCooldown = Duration(minutes: 20);
  static const Map<String, String> _youtubeHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
    'Referer': 'https://www.youtube.com/',
    'Origin': 'https://www.youtube.com',
    'Accept': '*/*',
  };

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
    Object? lastError;
    final triedUrls = <String>{};

    // Stage 1: fast path. Stage 2: recovery path if stage 1 failed.
    final clientSets = <List<YoutubeApiClient>>[
      [YoutubeApiClient.ios, YoutubeApiClient.android],
      [YoutubeApiClient.androidVr],
      [YoutubeApiClient.android],
      [YoutubeApiClient.tv, YoutubeApiClient.ios],
    ];

    for (final clients in clientSets) {
      try {
        final manifest = await _yt.videos.streams.getManifest(
          video.videoId,
          ytClients: clients,
        );

        final audioStreams = manifest.audioOnly.toList()
          ..sort((a, b) =>
              b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));

        var picked = 0;
        for (final stream in audioStreams) {
          final url = stream.url.toString();
          if (!triedUrls.add(url)) continue;
          if (picked >= _maxDirectCandidatesPerClientSet) break;
          picked++;

          try {
            await _setAndPlaySource(
              url: url,
              tag: mediaItem,
              headers: _youtubeHeaders,
            );
            debugPrint(
              'Direct playback succeeded for ${video.videoId} '
              '(itag=${stream.tag}, bitrate=${stream.bitrate.bitsPerSecond}).',
            );
            return true;
          } catch (e) {
            lastError = e;
            debugPrint(
              'Direct candidate failed for ${video.videoId} '
              '(itag=${stream.tag}, bitrate=${stream.bitrate.bitsPerSecond}): $e',
            );
          }
        }
      } on RequestLimitExceededException catch (e) {
        _rateLimitedUntil = DateTime.now().add(_rateLimitCooldown);
        debugPrint(
          'Rate-limited by YouTube for ${video.videoId}: $e. '
          'Cooldown until $_rateLimitedUntil',
        );
        throw RateLimitedPlaybackException(_rateLimitCooldown);
      } catch (e) {
        lastError = e;
        debugPrint(
            'Manifest fetch failed for ${video.videoId} with current client set: $e');
      }
    }

    if (lastError != null) {
      debugPrint(
          'All direct playback attempts failed for ${video.videoId}: $lastError');
    }
    return false;
  }

  Future<bool> _tryPlayBackend(PlaylistVideo video, MediaItem mediaItem) async {
    final url = '$_fallbackAudioBaseUrl/${video.videoId}';
    final backendAvailable = await _probeUrl(url);
    if (!backendAvailable) {
      debugPrint('Skip backend fallback because endpoint probe failed: $url');
      return false;
    }

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

  Future<bool> _probeUrl(String url) async {
    final uri = Uri.parse(url);
    final client = HttpClient()..connectionTimeout = _backendProbeTimeout;

    try {
      final headRequest = await client.headUrl(uri);
      final headResponse =
          await headRequest.close().timeout(_backendProbeTimeout);
      final headStatus = headResponse.statusCode;
      await headResponse.drain();
      if (headStatus >= 200 && headStatus < 400) {
        return true;
      }
      if (headStatus != HttpStatus.methodNotAllowed) {
        return false;
      }

      final getRequest = await client.getUrl(uri);
      getRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final getResponse =
          await getRequest.close().timeout(_backendProbeTimeout);
      final getStatus = getResponse.statusCode;
      await getResponse.drain();
      return getStatus >= 200 && getStatus < 400;
    } catch (e) {
      debugPrint('Backend probe exception for $url: $e');
      return false;
    } finally {
      client.close(force: true);
    }
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
