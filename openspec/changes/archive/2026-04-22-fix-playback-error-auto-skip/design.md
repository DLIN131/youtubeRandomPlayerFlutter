## Context

`lib/app.dart` 的 `initState()` 中有三個並發的播放狀態監聽器：

1. `playerStateStream` — 偵測 `ProcessingState.completed`，呼叫 `_playNext()`
2. `playbackEventStream` — 偵測原生 audio engine 的錯誤事件，用 `Future.delayed` 呼叫 `_playNext()`
3. `_playVideoObject.catchError` — 偵測串流解析失敗，呼叫 `_playNext()`

這三條路徑沒有互鎖，當背景播放出錯時，路徑 1 和 2 可能同時觸發。路徑 2 使用 `Future.delayed(2s)` 但這並不能防止重複呼叫。

`_playVideoObject()` 頭部有 `if (_isChangingTrack) return;`，這是唯一的防重入鎖，但當：
- 路徑 2 第一次呼叫 `_playNext()` → `_playVideoObject()` 設 `_isChangingTrack = true`
- `_resolveStreamUrl` 失敗 → `catchError` 設 `_isChangingTrack = false`，再呼叫 `_playNext()` (路徑 3)
- 此時路徑 2 的 `Future.delayed` 到期，又呼叫一次 `_playNext()`

這就造成了雙重觸發，第二次觸發時因 `_isChangingTrack = true`（因路徑 3 正在執行）而被丟棄，然後路徑 3 也可能遇到錯誤，導致 `_isChangingTrack` 最終停在 `false`，但卻沒有任何 `_playNext()` 被接受，播放器進入死狀態。

**背景播放的額外問題**：`just_audio_background` 在背景模式下，當歌曲 URL 過期或後端 fallback 回應緩慢時，原生媒體 session 可能發出 `playbackEventStream` 的錯誤多次（Android MediaSession 有時重試機制）。

## Goals / Non-Goals

**Goals:**
- 確保播放錯誤（無論是串流解析失敗或原生播放失敗）都能觸發一次且僅一次的 `_playNext()`
- 確保 `_isChangingTrack` 旗標不會因任何情況永久鎖死
- 在連續多首無法播放時，能在跳過一定次數後停下來通知使用者
- 在背景模式下與前景模式下具有一致的錯誤恢復行為

**Non-Goals:**
- 不重寫播放引擎架構（仍使用 `just_audio` + `ConcatenatingAudioSource`）
- 不改變 YouTube 串流解析策略
- 不增加新的 UI 畫面或設定頁

## Decisions

### 決策 1：使用「防抖 + 去重」的 `_triggerAutoSkip()` 函數取代分散的 `_playNext()` 呼叫

**問題**：三個地方都呼叫 `_playNext()`，無法互相協調。

**方案**：引入一個中央化的 `_triggerAutoSkip()` 函數，內部使用 `DateTime` 時間戳記做防抖（debounce），在 3 秒內只接受第一次觸發。

```dart
DateTime? _lastAutoSkipAt;

void _triggerAutoSkip() {
  final now = DateTime.now();
  if (_lastAutoSkipAt != null && now.difference(_lastAutoSkipAt!) < const Duration(seconds: 3)) {
    return; // debounced
  }
  _lastAutoSkipAt = now;
  _playNext();
}
```

**優點**：最簡單的修改，不需要引入複雜的 RxDart 或 StreamController，也不影響正常播放流程。

**替代方案考慮**：使用 `StreamController` + `debounceTime`（需引入 `rxdart`，額外依賴）；使用 `Timer`（更複雜，且需 `cancel` 管理）。

---

### 決策 2：為 `_isChangingTrack` 加入 5 秒安全逾時

**問題**：若 `catchError` 因某種極端情況沒被觸發（如 `Future` 被取消），`_isChangingTrack` 永遠是 `true`。

**方案**：在 `_playVideoObject()` 設定 `_isChangingTrack = true` 的同時，啟動一個 `Future.delayed(5s)` 的強制重置：

```dart
_isChangingTrack = true;
Future.delayed(const Duration(seconds: 5), () {
  if (_isChangingTrack) {
    _isChangingTrack = false;
  }
});
```

---

### 決策 3：連續錯誤計數器，超過 5 次停止自動跳過

**問題**：若整個播放清單的 URL 都失效（例如 IP 被 rate-limit），會造成無限迴圈消耗資源。

**方案**：加入 `_consecutiveErrorCount` 計數器，在 `_triggerAutoSkip()` 中遞增，在正常播放開始後重置為 0。若超過 5 次，顯示 SnackBar 並停止。

---

### 決策 4：`playVideoAsCurrent` 前加入 `player.stop()`

**問題**：背景播放出錯後，`AudioPlayer` 內部狀態可能是 `error` 或 `idle(error)`，此時直接呼叫 `setAudioSource` 可能在某些 `just_audio` 版本上不能清除錯誤狀態。

**方案**：在 `AudioPlayerService.playVideoAsCurrent()` 開頭加入：
```dart
try { await player.stop(); } catch (_) {}
```
這可以確保 player 回到乾淨的 `stopped` 狀態。

## Risks / Trade-offs

- **防抖 3 秒可能延遲錯誤恢復** → 在使用者正常的快速切歌場景中，3 秒窗口已能區分「使用者主動切歌」與「系統自動跳過」，可接受。
- **安全逾時可能與正常的長時間載入衝突** → 5 秒應已超過正常串流解析時間，若解析超過 5 秒基本上就是失敗，可接受。
- **`player.stop()` 增加一次 method channel 呼叫** → 微小的性能影響，可接受。
