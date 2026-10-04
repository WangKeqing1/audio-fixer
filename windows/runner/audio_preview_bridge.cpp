#include "audio_preview_bridge.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfplay.h>
#include <propvarutil.h>
#include <wrl/client.h>

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <deque>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <utility>

namespace {
using Microsoft::WRL::ComPtr;
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Result = flutter::MethodResult<Value>;
constexpr UINT kPlayerEvent = WM_APP + 0x317;
constexpr UINT_PTR kPositionTimer = 1;
constexpr ULONGLONG kPreparationTimeoutMs = 15000;
constexpr wchar_t kWindowClass[] = L"AudioFixer.AudioPreview.CallbackWindow";

const Value* Find(const Map* map, const char* key) {
  if (map == nullptr) return nullptr;
  const auto it = map->find(Value(key));
  return it == map->end() ? nullptr : &it->second;
}

bool ReadInt(const Map* map, const char* key, int64_t* result) {
  const Value* value = Find(map, key);
  if (value == nullptr) return false;
  if (const auto* number = std::get_if<int64_t>(value)) {
    *result = *number;
    return true;
  }
  if (const auto* number = std::get_if<int32_t>(value)) {
    *result = *number;
    return true;
  }
  return false;
}

const std::string* ReadString(const Map* map, const char* key) {
  const Value* value = Find(map, key);
  return value == nullptr ? nullptr : std::get_if<std::string>(value);
}

int HexDigit(char ch) {
  if (ch >= '0' && ch <= '9') return ch - '0';
  if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
  if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
  return -1;
}

// Deliberately accept only local drive-absolute paths and hostless file URIs.
// Do not feed an arbitrary URI to Media Foundation's network source resolver.
bool LocalPath(const std::string& input, std::wstring* result) {
  if (input.empty() || input.size() > 131072) return false;
  std::string path = input;
  if (input.size() >= 5 && _strnicmp(input.c_str(), "file:", 5) == 0) {
    if (input.size() < 8 || input.substr(5, 3) != "///" ||
        input.find_first_of("?#") != std::string::npos) {
      return false;
    }
    path.clear();
    for (size_t i = 8; i < input.size(); ++i) {
      if (input[i] == '%') {
        if (i + 2 >= input.size()) return false;
        const int high = HexDigit(input[i + 1]);
        const int low = HexDigit(input[i + 2]);
        if (high < 0 || low < 0) return false;
        path.push_back(static_cast<char>((high << 4) | low));
        i += 2;
      } else {
        path.push_back(input[i]);
      }
    }
  }
  const bool drive_letter = !path.empty() &&
      ((path[0] >= 'a' && path[0] <= 'z') ||
       (path[0] >= 'A' && path[0] <= 'Z'));
  if (path.size() < 3 || !drive_letter || path[1] != ':' ||
      (path[2] != '/' && path[2] != '\\') ||
      path.find('\0') != std::string::npos ||
      path.find(':', 2) != std::string::npos) {
    return false;
  }
  std::replace(path.begin(), path.end(), '/', '\\');
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                      path.data(), static_cast<int>(path.size()),
                                      nullptr, 0);
  if (size <= 0) return false;
  result->resize(static_cast<size_t>(size));
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.data(),
                          static_cast<int>(path.size()), result->data(), size)
      != size) {
    return false;
  }
  const std::wstring root = result->substr(0, 3);
  return GetDriveTypeW(root.c_str()) != DRIVE_REMOTE;
}

std::string ErrorCode(HRESULT hr) {
  if (hr == E_ACCESSDENIED || hr == HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED)) {
    return "permission_denied";
  }
  if (hr == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) ||
      hr == HRESULT_FROM_WIN32(ERROR_PATH_NOT_FOUND) ||
      hr == HRESULT_FROM_WIN32(ERROR_SHARING_VIOLATION) ||
      hr == HRESULT_FROM_WIN32(ERROR_NOT_READY)) {
    return "source_unavailable";
  }
  if (hr == MF_E_UNSUPPORTED_BYTESTREAM_TYPE ||
      hr == MF_E_UNSUPPORTED_FORMAT || hr == MF_E_INVALIDMEDIATYPE ||
      hr == MF_E_TOPO_CODEC_NOT_FOUND || hr == MF_E_TOPO_UNSUPPORTED) {
    return "unsupported_format";
  }
  if (hr == MF_E_NO_AUDIO_PLAYBACK_DEVICE ||
      hr == MF_E_AUDIO_PLAYBACK_DEVICE_INVALIDATED ||
      hr == MF_E_AUDIO_PLAYBACK_DEVICE_IN_USE ||
      hr == MF_E_AUDIO_SERVICE_NOT_RUNNING) {
    return "audio_focus_denied";
  }
  return "playback_failed";
}

Value HResultDetails(HRESULT hr) {
  return Value(Map{{Value("hresult"), Value(static_cast<int64_t>(hr))}});
}

int64_t TimeMs(const PROPVARIANT& value) {
  if (value.vt == VT_UI8) {
    return static_cast<int64_t>(std::min<ULONGLONG>(
        value.uhVal.QuadPart / 10000,
        static_cast<ULONGLONG>(std::numeric_limits<int64_t>::max())));
  }
  if (value.vt == VT_I8) return std::max<int64_t>(0, value.hVal.QuadPart / 10000);
  return 0;
}

struct NativeEvent {
  uint64_t generation = 0;
  MFP_EVENT_TYPE type = MFP_EVENT_TYPE_ERROR;
  HRESULT hr = S_OK;
  ComPtr<IMFPMediaItem> item;
};

// This is the only state shared with Media Foundation callback threads. It
// never owns the bridge or invokes Flutter. A generation fences old players.
struct CallbackQueue {
  std::mutex mutex;
  HWND window = nullptr;
  uint64_t generation = 0;
  bool closed = false;
  std::deque<NativeEvent> events;
};

class PlayerCallback final : public IMFPMediaPlayerCallback {
 public:
  PlayerCallback(std::shared_ptr<CallbackQueue> queue, uint64_t generation)
      : queue_(std::move(queue)), generation_(generation) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
    if (object == nullptr) return E_POINTER;
    *object = nullptr;
    if (iid == __uuidof(IUnknown) || iid == __uuidof(IMFPMediaPlayerCallback)) {
      *object = static_cast<IMFPMediaPlayerCallback*>(this);
      AddRef();
      return S_OK;
    }
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG remaining = --references_;
    if (remaining == 0) delete this;
    return remaining;
  }
  void STDMETHODCALLTYPE OnMediaPlayerEvent(MFP_EVENT_HEADER* header) override {
    if (header == nullptr) return;
    try {
      std::lock_guard<std::mutex> lock(queue_->mutex);
      if (queue_->closed || queue_->generation != generation_ ||
          queue_->window == nullptr) {
        return;
      }
      NativeEvent event;
      event.generation = generation_;
      event.type = header->eEventType;
      event.hr = header->hrEvent;
      if (event.type == MFP_EVENT_TYPE_MEDIAITEM_CREATED && SUCCEEDED(event.hr)) {
        event.item = MFP_GET_MEDIAITEM_CREATED_EVENT(header)->pMediaItem;
      }
      queue_->events.push_back(std::move(event));
      PostMessageW(queue_->window, kPlayerEvent, 0, 0);
    } catch (const std::bad_alloc&) {
      // Never unwind through a COM callback. The platform timer also drains
      // events and enforces a preparation deadline if allocation failed.
    }
  }

 private:
  std::atomic<ULONG> references_{1};
  const std::shared_ptr<CallbackQueue> queue_;
  const uint64_t generation_;
};
}  // namespace

class AudioPreviewBridge::Impl {
 public:
  explicit Impl(flutter::BinaryMessenger* messenger)
      : queue_(std::make_shared<CallbackQueue>()),
        methods_(messenger, "audio_fixer/audio_preview",
                 &flutter::StandardMethodCodec::GetInstance()),
        events_(messenger, "audio_fixer/audio_preview_events",
                &flutter::StandardMethodCodec::GetInstance()) {
    // The runner normally already initialized COM. Balance only this call's
    // successful initialization; RPC_E_CHANGED_MODE means COM is usable too.
    const HRESULT com_hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    owns_com_ = SUCCEEDED(com_hr);
    initialization_hr_ = (SUCCEEDED(com_hr) || com_hr == RPC_E_CHANGED_MODE)
                             ? S_OK : com_hr;
    if (SUCCEEDED(initialization_hr_)) {
      initialization_hr_ = MFStartup(MF_VERSION);
      owns_media_foundation_ = SUCCEEDED(initialization_hr_);
    }
    if (SUCCEEDED(initialization_hr_)) initialization_hr_ = CreateCallbackWindow();

    methods_.SetMethodCallHandler(
        [this](const flutter::MethodCall<Value>& call,
               std::unique_ptr<Result> result) { HandleMethod(call, std::move(result)); });
    events_.SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<Value>>(
        [this](const Value*, std::unique_ptr<flutter::EventSink<Value>>&& sink)
            -> std::unique_ptr<flutter::StreamHandlerError<Value>> {
          sink_ = std::move(sink);
          Emit();
          return nullptr;
        },
        [this](const Value*) -> std::unique_ptr<flutter::StreamHandlerError<Value>> {
          sink_.reset();
          const HRESULT hr = ReleasePlayer();
          if (FAILED(hr)) {
            status_ = "error";
            error_code_ = "release_failed";
            return std::make_unique<flutter::StreamHandlerError<Value>>(
                "release_failed", "Could not release the audio source.", nullptr);
          }
          SetStoppedState();
          return nullptr;
        }));
  }

  ~Impl() {
    // Both handlers capture this; unregister while messenger/engine still live.
    methods_.SetMethodCallHandler(nullptr);
    events_.SetStreamHandler(nullptr);
    sink_.reset();
    ReleasePlayer();
    {
      std::lock_guard<std::mutex> lock(queue_->mutex);
      queue_->closed = true;
      queue_->window = nullptr;
    }
    if (window_ != nullptr) {
      KillTimer(window_, kPositionTimer);
      DestroyWindow(window_);
    }
    player_.Reset();
    byte_stream_.Reset();
    if (owns_media_foundation_) MFShutdown();
    if (owns_com_) CoUninitialize();
  }

 private:
  HRESULT CreateCallbackWindow() {
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = WindowProc;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpszClassName = kWindowClass;
    if (RegisterClassW(&window_class) == 0 &&
        GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
      return HRESULT_FROM_WIN32(GetLastError());
    }
    window_ = CreateWindowExW(0, kWindowClass, L"", 0, 0, 0, 0, 0,
                              HWND_MESSAGE, nullptr, window_class.hInstance, this);
    if (window_ == nullptr) return HRESULT_FROM_WIN32(GetLastError());
    queue_->window = window_;
    if (SetTimer(window_, kPositionTimer, 200, nullptr) == 0) {
      return HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_MEMORY);
    }
    return S_OK;
  }

  static LRESULT CALLBACK WindowProc(HWND window, UINT message,
                                      WPARAM wparam, LPARAM lparam) {
    auto* self = reinterpret_cast<Impl*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      const auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
      self = static_cast<Impl*>(create->lpCreateParams);
      SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    }
    if (self != nullptr) {
      if (message == kPlayerEvent) {
        self->DrainEvents();
        return 0;
      }
      if (message == WM_TIMER && wparam == kPositionTimer) {
        self->Tick();
        return 0;
      }
      if (message == WM_NCDESTROY) SetWindowLongPtrW(window, GWLP_USERDATA, 0);
    }
    return DefWindowProcW(window, message, wparam, lparam);
  }

  Value State() const {
    return Value(Map{
        {Value("requestId"), Value(request_id_)},
        {Value("trackId"), track_id_.empty() ? Value() : Value(track_id_)},
        {Value("status"), Value(status_)},
        {Value("positionMs"), Value(position_ms_)},
        {Value("durationMs"), Value(duration_ms_)},
        {Value("errorCode"), error_code_.empty() ? Value() : Value(error_code_)},
    });
  }

  void SetStoppedState() {
    status_ = "stopped";
    error_code_.clear();
    track_id_.clear();
    path_.clear();
    position_ms_ = 0;
    duration_ms_ = 0;
    // Keep request_id_ and latest_request_id_: delayed commands from the
    // released session must not become eligible to open a file again.
  }

  void Emit() {
    if (sink_) sink_->Success(State());
  }

  void HandleMethod(const flutter::MethodCall<Value>& call,
                    std::unique_ptr<Result> result) {
    const auto& method = call.method_name();
    const Map* args = call.arguments() == nullptr
                          ? nullptr : std::get_if<Map>(call.arguments());
    if (method == "getState") {
      RefreshPosition();
      result->Success(State());
      return;
    }
    if (method == "stop") {
      const HRESULT hr = ReleasePlayer();
      if (FAILED(hr)) {
        status_ = "error";
        error_code_ = "release_failed";
        Emit();
        result->Error("release_failed", "Could not safely release audio playback.",
                      HResultDetails(hr));
        return;
      }
      SetStoppedState();
      Emit();
      result->Success();
      return;
    }
    if (method == "play") {
      Play(args, std::move(result));
      return;
    }
    if (method != "pause" && method != "seek") {
      result->NotImplemented();
      return;
    }
    int64_t request = 0;
    if (!ReadInt(args, "requestId", &request) || request <= 0) {
      result->Error("invalid_argument", "requestId must be a positive integer.");
      return;
    }
    int64_t position = 0;
    if (method == "seek" &&
        (!ReadInt(args, "positionMs", &position) || position < 0)) {
      result->Error("invalid_argument", "positionMs must be a nonnegative integer.");
      return;
    }
    // Commands from a superseded request cannot pause or seek its successor.
    if (request != request_id_ || !player_) {
      result->Success();
      return;
    }
    HRESULT hr = S_OK;
    if (method == "pause") {
      desired_playing_ = false;
      if (media_ready_) hr = player_->Pause();
      if (SUCCEEDED(hr)) {
        RefreshPosition();
        status_ = "paused";
        Emit();
      }
    } else if (media_ready_) {
      if (duration_ms_ > 0) position = std::min(position, duration_ms_);
      // Prevent overflow converting user-supplied milliseconds to 100ns units.
      position = std::min(position, std::numeric_limits<int64_t>::max() / 10000);
      PROPVARIANT target{};
      target.vt = VT_I8;
      target.hVal.QuadPart = position * 10000;
      hr = player_->SetPosition(MFP_POSITIONTYPE_100NS, &target);
      if (SUCCEEDED(hr)) {
        ++pending_seeks_;
        position_ms_ = position;
        if (status_ == "completed") status_ = "paused";
        Emit();
      }
    }
    if (FAILED(hr)) {
      Fail(hr);
      result->Error(ErrorCode(hr), "The audio operation failed.", HResultDetails(hr));
    } else {
      result->Success();
    }
  }

  void Play(const Map* args, std::unique_ptr<Result> result) {
    int64_t request = 0;
    const auto* track = ReadString(args, "trackId");
    const auto* uri = ReadString(args, "uri");
    if (!ReadInt(args, "requestId", &request) || request <= 0 ||
        track == nullptr || track->empty() || uri == nullptr) {
      result->Error("invalid_argument", "play requires requestId, trackId and uri.");
      return;
    }
    std::wstring path;
    if (!LocalPath(*uri, &path)) {
      result->Error("invalid_source", "Only local Windows audio files are supported.");
      return;
    }
    if (request < latest_request_id_ ||
        (request == latest_request_id_ &&
         (status_ == "stopped" || status_ == "error" || !player_))) {
      result->Success();
      return;
    }
    if (request == request_id_ && player_ && track_id_ == *track && path_ == path) {
      if (status_ == "playing" || (status_ == "loading" && desired_playing_)) {
        result->Success();
        return;
      }
      desired_playing_ = true;
      HRESULT hr = S_OK;
      if (media_ready_) hr = player_->Play();
      if (FAILED(hr)) {
        Fail(hr);
        result->Error(ErrorCode(hr), "Could not resume audio.", HResultDetails(hr));
      } else {
        status_ = "loading";
        preparation_started_ = GetTickCount64();
        Emit();
        result->Success();
      }
      return;
    }
    const HRESULT release_hr = ReleasePlayer();
    if (FAILED(release_hr)) {
      result->Error("release_failed", "Could not release the previous audio source.",
                    HResultDetails(release_hr));
      return;
    }
    latest_request_id_ = std::max(latest_request_id_, request);
    request_id_ = request;
    track_id_ = *track;
    path_ = path;
    status_ = "loading";
    error_code_.clear();
    position_ms_ = 0;
    duration_ms_ = 0;
    desired_playing_ = true;
    preparation_started_ = GetTickCount64();
    Emit();

    HRESULT hr = initialization_hr_;
    if (SUCCEEDED(hr)) {
      const DWORD attributes = GetFileAttributesW(path.c_str());
      if (attributes == INVALID_FILE_ATTRIBUTES) {
        hr = HRESULT_FROM_WIN32(GetLastError());
      } else if ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
        hr = HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND);
      }
    }
    if (SUCCEEDED(hr)) {
      // Own the byte stream instead of allowing a URL source to own an opaque
      // file handle. Close() is the synchronous release barrier before writes.
      hr = MFCreateFile(MF_ACCESSMODE_READ, MF_OPENMODE_FAIL_IF_NOT_EXIST,
                        MF_FILEFLAGS_NONE, path.c_str(), &byte_stream_);
    }
    if (SUCCEEDED(hr)) {
      ComPtr<IMFAttributes> attributes;
      hr = byte_stream_.As(&attributes);
      if (SUCCEEDED(hr)) {
        hr = attributes->SetString(MF_BYTESTREAM_ORIGIN_NAME, path.c_str());
      }
    }
    if (SUCCEEDED(hr)) {
      ComPtr<IMFPMediaPlayerCallback> callback;
      callback.Attach(new (std::nothrow) PlayerCallback(queue_, generation_));
      if (!callback) {
        hr = E_OUTOFMEMORY;
      } else {
        hr = MFPCreateMediaPlayer(nullptr, FALSE, MFP_OPTION_FREE_THREADED_CALLBACK,
                                  callback.Get(), nullptr, &player_);
      }
    }
    if (SUCCEEDED(hr)) {
      // Parsing/codec discovery is asynchronous, so a slow or damaged file
      // does not block Flutter's platform thread during preparation.
      hr = player_->CreateMediaItemFromObject(byte_stream_.Get(), FALSE, 0, nullptr);
    }
    if (FAILED(hr)) {
      Fail(hr);
      result->Error(ErrorCode(hr), "Could not open audio preview.", HResultDetails(hr));
      return;
    }
    result->Success();
  }

  HRESULT ReleasePlayer() {
    // Invalidate first. A callback arriving while Shutdown is running cannot
    // publish an old state or retain a fresh media-item reference in the queue.
    ++generation_;
    std::deque<NativeEvent> discarded;
    {
      std::lock_guard<std::mutex> lock(queue_->mutex);
      queue_->generation = generation_;
      discarded.swap(queue_->events);
    }
    // Release COM pointers outside the callback lock to avoid reentrant locks.
    discarded.clear();
    desired_playing_ = false;
    media_ready_ = false;
    pending_seeks_ = 0;
    preparation_started_ = 0;
    HRESULT failure = S_OK;
    if (player_) {
      const HRESULT hr = player_->Shutdown();
      if (SUCCEEDED(hr) || hr == MF_E_SHUTDOWN) {
        player_.Reset();
      } else {
        failure = hr;  // Retain the obligation for a later stop retry.
      }
    }
    if (byte_stream_) {
      const HRESULT hr = byte_stream_->Close();
      if (SUCCEEDED(hr) || hr == MF_E_SHUTDOWN) {
        byte_stream_.Reset();
      } else if (SUCCEEDED(failure)) {
        failure = hr;
      }
    }
    return failure;
  }

  void Fail(HRESULT hr, const std::string& code = "") {
    status_ = "error";
    error_code_ = code.empty() ? ErrorCode(hr) : code;
    ReleasePlayer();  // Keep failed resources alive for an explicit stop retry.
    Emit();
  }

  void DrainEvents() {
    // Pop one at a time. Keeping media items for other callbacks in a local
    // batch could retain a file across ReleasePlayer's write barrier.
    for (;;) {
      NativeEvent event;
      {
        std::lock_guard<std::mutex> lock(queue_->mutex);
        if (queue_->events.empty()) break;
        event = std::move(queue_->events.front());
        queue_->events.pop_front();
      }
      if (event.generation != generation_ || !player_) continue;
      HandleEvent(event);
    }
  }

  void HandleEvent(NativeEvent& event) {
    if (FAILED(event.hr)) {
      event.item.Reset();
      Fail(event.hr);
      return;
    }
    HRESULT hr = S_OK;
    switch (event.type) {
      case MFP_EVENT_TYPE_MEDIAITEM_CREATED: {
        BOOL has_audio = FALSE;
        BOOL selected = FALSE;
        hr = event.item ? event.item->HasAudio(&has_audio, &selected) : E_FAIL;
        if (SUCCEEDED(hr) && (!has_audio || !selected)) hr = MF_E_UNSUPPORTED_FORMAT;
        if (SUCCEEDED(hr)) {
          PROPVARIANT duration{};
          if (SUCCEEDED(event.item->GetDuration(MFP_POSITIONTYPE_100NS, &duration))) {
            duration_ms_ = TimeMs(duration);
          }
          PropVariantClear(&duration);
          hr = player_->SetMediaItem(event.item.Get());
        }
        event.item.Reset();
        break;
      }
      case MFP_EVENT_TYPE_MEDIAITEM_SET:
        media_ready_ = true;
        if (desired_playing_) {
          hr = player_->Play();
        } else {
          preparation_started_ = 0;
          status_ = "paused";
        }
        break;
      case MFP_EVENT_TYPE_PLAY:
        preparation_started_ = 0;
        if (desired_playing_) {
          status_ = "playing";
        } else {
          // A pause issued while loading must win over a delayed play event.
          hr = player_->Pause();
          status_ = "paused";
        }
        break;
      case MFP_EVENT_TYPE_PAUSE:
        if (!desired_playing_) status_ = "paused";
        break;
      case MFP_EVENT_TYPE_POSITION_SET:
        if (pending_seeks_ > 0) --pending_seeks_;
        break;
      case MFP_EVENT_TYPE_PLAYBACK_ENDED:
        if (pending_seeks_ > 0) break;
        desired_playing_ = false;
        preparation_started_ = 0;
        status_ = "completed";
        if (duration_ms_ > 0) position_ms_ = duration_ms_;
        break;
      case MFP_EVENT_TYPE_ERROR:
        hr = E_FAIL;
        break;
      default:
        break;
    }
    if (FAILED(hr)) {
      Fail(hr);
    } else {
      RefreshPosition();
      Emit();
    }
  }

  void RefreshPosition() {
    if (!player_ || !media_ready_) return;
    PROPVARIANT duration{};
    if (duration_ms_ == 0 &&
        SUCCEEDED(player_->GetDuration(MFP_POSITIONTYPE_100NS, &duration))) {
      duration_ms_ = TimeMs(duration);
    }
    PropVariantClear(&duration);
    if (status_ == "completed" || pending_seeks_ > 0) return;
    PROPVARIANT position{};
    if (SUCCEEDED(player_->GetPosition(MFP_POSITIONTYPE_100NS, &position))) {
      position_ms_ = TimeMs(position);
      if (duration_ms_ > 0) position_ms_ = std::min(position_ms_, duration_ms_);
    }
    PropVariantClear(&position);
  }

  void Tick() {
    DrainEvents();
    if (preparation_started_ != 0 &&
        GetTickCount64() - preparation_started_ >= kPreparationTimeoutMs) {
      Fail(HRESULT_FROM_WIN32(ERROR_TIMEOUT), "preparation_timeout");
      return;
    }
    if (status_ == "playing") {
      RefreshPosition();
      Emit();
    }
  }

  std::shared_ptr<CallbackQueue> queue_;
  flutter::MethodChannel<Value> methods_;
  flutter::EventChannel<Value> events_;
  std::unique_ptr<flutter::EventSink<Value>> sink_;
  ComPtr<IMFPMediaPlayer> player_;
  ComPtr<IMFByteStream> byte_stream_;
  HWND window_ = nullptr;
  HRESULT initialization_hr_ = S_OK;
  bool owns_com_ = false;
  bool owns_media_foundation_ = false;
  bool desired_playing_ = false;
  bool media_ready_ = false;
  uint64_t generation_ = 0;
  size_t pending_seeks_ = 0;
  int64_t request_id_ = 0;
  int64_t latest_request_id_ = 0;
  int64_t position_ms_ = 0;
  int64_t duration_ms_ = 0;
  ULONGLONG preparation_started_ = 0;
  std::string track_id_;
  std::wstring path_;
  std::string status_ = "idle";
  std::string error_code_;
};

AudioPreviewBridge::AudioPreviewBridge(flutter::BinaryMessenger* messenger)
    : impl_(std::make_unique<Impl>(messenger)) {}
AudioPreviewBridge::~AudioPreviewBridge() = default;
