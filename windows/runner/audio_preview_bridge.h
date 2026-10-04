#ifndef RUNNER_AUDIO_PREVIEW_BRIDGE_H_
#define RUNNER_AUDIO_PREVIEW_BRIDGE_H_

#include <memory>

namespace flutter {
class BinaryMessenger;
}

// Own on the Flutter platform thread and destroy before the engine. Playback
// uses Windows Media Foundation codecs; no network source is ever opened.
class AudioPreviewBridge {
 public:
  explicit AudioPreviewBridge(flutter::BinaryMessenger* messenger);
  ~AudioPreviewBridge();

  AudioPreviewBridge(const AudioPreviewBridge&) = delete;
  AudioPreviewBridge& operator=(const AudioPreviewBridge&) = delete;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_AUDIO_PREVIEW_BRIDGE_H_
