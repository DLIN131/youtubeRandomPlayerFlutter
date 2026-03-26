# youtube_random_player_flutter_bg

Flutter rewrite of the original Vue YouTube Random Player project.

## Features
- Input YouTube playlist ID or full playlist URL
- Fetch playlist videos from YouTube Data API
- Play / pause / previous / next
- Random shuffle mode
- Search videos in current list
- Background playback (music keeps playing when screen is off)

## Project Path
`d:\proj_bk\personal\youtebeRP_flutter\youtube_random_player_flutter_bg`

## Important
This environment does not currently have the `flutter` command available.
I already prepared Flutter source files (`lib/`) and `pubspec.yaml`.

After Flutter is installed on your machine, run these commands in this folder:

```bash
flutter create .
flutter pub get
flutter run
```

## API Key
Current key is kept from your old project at:
- `lib/services/youtube_api_service.dart`

You should replace it with your own YouTube Data API key.

## Android Background Playback
In `android/app/src/main/AndroidManifest.xml`, ensure these entries exist:

```xml
<uses-permission android:name="android.permission.INTERNET" />

<application ...>
  <service
      android:name="com.ryanheise.audioservice.AudioService"
      android:foregroundServiceType="mediaPlayback"
      android:exported="true">
    <intent-filter>
      <action android:name="android.media.browse.MediaBrowserService" />
    </intent-filter>
  </service>
</application>
```

## iOS Background Playback
In Xcode, enable:
- Signing & Capabilities -> Background Modes -> Audio, AirPlay, and Picture in Picture

Or add to `ios/Runner/Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
</array>
```
