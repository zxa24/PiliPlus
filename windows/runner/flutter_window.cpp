#include "flutter_window.h"

#include <d3d11.h>
#include <flutter/standard_method_codec.h>
#include <wrl/client.h>

#include <optional>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

// D3D11_DECODER_PROFILE_AV1_VLD_PROFILE0: AV1 Main, which is what Bilibili
// and YouTube serve. Spelt out rather than taken from the SDK headers, which
// only declare it with a recent Windows SDK.
constexpr GUID kAv1Profile0 = {
    0xb8be4ccb, 0xcf53, 0x46ba, {0x8d, 0x59, 0xd6, 0xb8, 0xa6, 0xda, 0x5d, 0x2a}};

// The others the two platforms serve, spelt out for the same reason as AV1's
// (the SDK only declares them; defining them needs dxguid.lib): H.264 up to
// High without film grain, HEVC Main, VP9 Profile 0 (8-bit).
constexpr GUID kH264Profile = {
    0x1b81be68, 0xa0c7, 0x11d3, {0xb9, 0x84, 0x00, 0xc0, 0x4f, 0x2e, 0x73, 0xc5}};
constexpr GUID kHevcMainProfile = {
    0x5b11d51b, 0x2f4c, 0x4452, {0xbc, 0xc3, 0x09, 0xf2, 0xa1, 0x16, 0x0c, 0xc0}};
constexpr GUID kVp9Profile0 = {
    0x463707f8, 0xa1d0, 0x4585, {0x87, 0x6d, 0x83, 0xaa, 0x6d, 0x60, 0xb8, 0x9e}};

// The decoder profiles the default GPU offers through D3D11 video, the path
// mpv's d3d11va hardware decoding takes. Empty when there is no such GPU.
std::vector<GUID> DecoderProfiles() {
  std::vector<GUID> profiles;
  Microsoft::WRL::ComPtr<ID3D11Device> device;
  if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                               D3D11_CREATE_DEVICE_VIDEO_SUPPORT, nullptr, 0,
                               D3D11_SDK_VERSION, &device, nullptr, nullptr))) {
    return profiles;
  }
  Microsoft::WRL::ComPtr<ID3D11VideoDevice> video;
  if (FAILED(device.As(&video))) return profiles;
  const UINT count = video->GetVideoDecoderProfileCount();
  for (UINT i = 0; i < count; i++) {
    GUID profile;
    if (SUCCEEDED(video->GetVideoDecoderProfile(i, &profile))) {
      profiles.push_back(profile);
    }
  }
  return profiles;
}

bool Offers(const std::vector<GUID>& profiles, const GUID& wanted) {
  for (const auto& profile : profiles) {
    if (IsEqualGUID(profile, wanted)) return true;
  }
  return false;
}

// Whether the default GPU offers an AV1 decoder.
bool HasAv1Decoder() { return Offers(DecoderProfiles(), kAv1Profile0); }

// LibrePili: {"avc": bool, "hevc": bool, "vp9": bool, "av1": bool}, for
// marking a quality that would be decoded in software.
flutter::EncodableMap HardwareDecoders() {
  const auto profiles = DecoderProfiles();
  return {
      {flutter::EncodableValue("avc"),
       flutter::EncodableValue(Offers(profiles, kH264Profile))},
      {flutter::EncodableValue("hevc"),
       flutter::EncodableValue(Offers(profiles, kHevcMainProfile))},
      {flutter::EncodableValue("vp9"),
       flutter::EncodableValue(Offers(profiles, kVp9Profile0))},
      {flutter::EncodableValue("av1"),
       flutter::EncodableValue(Offers(profiles, kAv1Profile0))},
  };
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  codecs_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "librepili/codecs",
          &flutter::StandardMethodCodec::GetInstance());
  codecs_channel_->SetMethodCallHandler(
      [](const auto& call, auto result) {
        if (call.method_name() == "av1Hardware") {
          result->Success(flutter::EncodableValue(HasAv1Decoder()));
        } else if (call.method_name() == "hardwareDecoders") {
          result->Success(flutter::EncodableValue(HardwareDecoders()));
        } else {
          result->NotImplemented();
        }
      });

  // window_manager's show / setSize bring the window to the top and take
  // the focus; the self-test runs behind whatever the user is doing
  self_test_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "librepili/selftest",
          &flutter::StandardMethodCodec::GetInstance());
  self_test_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (call.method_name() == "resize" && args) {
          const int width =
              std::get<int>(args->at(flutter::EncodableValue("width")));
          const int height =
              std::get<int>(args->at(flutter::EncodableValue("height")));
          ::SetWindowPos(GetHandle(), nullptr, 0, 0, width, height,
                         SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // flutter_controller_->engine()->SetNextFrameCallback([&]() {
  //   this->Show();
  // });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
