# Nosmai + LiveKit — native iOS example

Publishes a **Nosmai-filtered camera feed** to a LiveKit room from a plain Swift
app. AR effects and beauty at full frame rate, with no per-frame copies.

Measured **~30 fps at 720×1280 with AR effects active** on an iPhone 15.

> Using Flutter? See [`nosmai_livekit_bridge`](https://github.com/nosmai/nosmai_livekit_bridge)
> instead — it wraps all of this. There is a matching native Android example too.

---

## The model: Nosmai owns the camera, LiveKit publishes

This is the one thing to understand before reading the code.

```
AVCaptureSession ──► Nosmai (filters + AR) ──┬──► on-screen preview (attach(to:))
                                             └──► LiveKit encoder   (BufferCapturer)
```

**Nosmai owns the camera and the preview. LiveKit only encodes and transports.**

LiveKit must never capture. A second capture path means a second pipeline
contending for the same camera, and on iOS `AVCaptureSession` will simply refuse
the second claim. Everything else stays LiveKit's job — the room, signalling,
publishing, subscriptions. It just doesn't capture.

### The thing that surprises people

**`startCapture()` and `startProcessing()` are two separate calls, and you need
both.**

```swift
NosmaiCore.shared().camera?.attach(to: previewView)
NosmaiCore.shared().camera?.startCapture()      // opens the AVCaptureSession
NosmaiSDK.sharedInstance()?.startProcessing()   // starts the filter pipeline
```

`startCapture()` deliberately does not start SDK processing — that is left to the
caller. Omit `startProcessing()` and every frame is discarded before it reaches
the pipeline, which fails in a way that is actively misleading:

- **Filters appear to work but do nothing.** `applyEffect` only queues the effect
  and calls your completion with `success = true`. The queue is drained by
  `startProcessing()`.
- **No `CVPixelBuffer`s are ever emitted**, so `publish()` waits for a first
  frame that never comes and fails after 10s with `Code=101 "Timed out"`.
- **The preview still shows live video the whole time**, because
  `attach(to:)` inserts a raw `AVCaptureVideoPreviewLayer` underneath the
  SDK's GL surface — which stays hidden until a processed frame arrives.

Between them those three symptoms read as "the filters are broken", which is the
wrong place to look.

---

## Install

### Prerequisites

| | |
|---|---|
| Xcode | 15 or newer (verified on 26.2) |
| Device | **A real iPhone.** The SDK ships one device-only `arm64` slice and the pod excludes every simulator architecture, so there is no simulator build to make. |
| Deployment target | iOS 15.0 — the Nosmai pod's minimum |
| [CocoaPods](https://cocoapods.org) | Any recent version (verified on 1.17). `project.yml` pins `objectVersion: 54` so 1.15's `Xcodeproj` can still parse the generated project. |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | `brew install xcodegen` |
| A Nosmai licence key | iOS keys are bound to a bundle id, and are different from your Android key. Contact [admin@nosmai.com](mailto:admin@nosmai.com). |
| A LiveKit server | Cloud, self-hosted, or `livekit-server --dev` — see [Testing locally](#testing-locally) |

### 1. Generate the project and install pods

There is no `.xcodeproj` in the repo: `project.yml` is the source of truth and
the project is a build artifact.

```bash
brew install xcodegen
xcodegen generate
pod install
open NosmaiLiveKitExample.xcworkspace   # the WORKSPACE, not the .xcodeproj
```

`pod install` fetches the Nosmai SDK for you — it is a published pod:

```ruby
pod 'NosmaiCameraSDK', '~> 3.0.0'
```

There is no framework to download by hand and no binary vendored in this repo.
If Nosmai has given you a framework build directly (a pre-release, or a build
with internal logging enabled), unpack it somewhere ignored by git and point the
pod at that folder instead — the commented line in the `Podfile` shows the form:

```ruby
pod 'NosmaiCameraSDK', :path => './LocalNosmai'
```

Re-run `xcodegen generate` after every edit to `project.yml`, and `pod install`
after every edit to the `Podfile`.

### 2. Set your bundle id and team

Licence keys are bound to a bundle id — they must match, or initialisation fails.

```yaml
# project.yml
PRODUCT_BUNDLE_IDENTIFIER: com.your.app
DEVELOPMENT_TEAM: YOUR_TEAM_ID          # or sign manually in Xcode
```

### 3. Fill in the three constants

All three live at the top of `NosmaiLiveKitExample/ViewController.swift`:

```swift
private let nosmaiLicenseKey = "YOUR_NOSMAI_IOS_KEY"
private let livekitURL       = "ws://192.168.1.100:7880"   // your LAN IP
private let livekitToken     = "YOUR_JOIN_TOKEN"
```

Keep real keys and tokens out of commits.

### 4. Add effects (optional)

Drop `.nosmai` packages into `NosmaiLiveKitExample/Filters/`. The selector is
built from whatever is there at runtime, so adding an effect needs no code
change. The folder is gitignored — the packages are yours to supply.

---

## Usage

The whole integration is three steps, all in `ViewController.swift`. Everything
else in that file is UI.

```swift
// 1. Ask for the camera, then let Nosmai own it. BOTH calls, in this order.
NosmaiCore.shared().initialize(withAPIKey: nosmaiLicenseKey) { success, error in
    DispatchQueue.main.async {
        NosmaiCore.shared().camera?.attach(to: self.previewView)
        if NosmaiCore.shared().camera?.startCapture() == true {
            NosmaiSDK.sharedInstance()?.startProcessing()
        }
    }
}

// 2. Publish a BufferCapturer — a capturer that takes frames you push
//    rather than opening a camera of its own.
let track = LocalVideoTrack.createBufferTrack(name: "nosmai", source: .camera)
let capturer = track.capturer as! BufferCapturer
try await room.localParticipant.publish(videoTrack: track)

// 3. Forward Nosmai's filtered frames into it.
NosmaiCore.shared().liveFrameStreamCallback = { pixelBuffer, timestamp in
    capturer.capture(pixelBuffer, timeStampNs: Int64(timestamp * 1_000_000_000))
}

// Filters apply live, mid-stream.
NosmaiCore.shared().effects?.applyEffect(url.path) { success, error in ... }

// Camera switching goes through NOSMAI, never LiveKit.
NosmaiCore.shared().camera?.switch()

// Teardown — stop producing before leaving the room.
NosmaiCore.shared().liveFrameStreamCallback = nil
await room.disconnect()
```

The example publishes video only; it never enables a LiveKit audio track.

---

## API

The calls that matter, and why each one is the one to use.

| Call | Purpose |
|---|---|
| `NosmaiCore.shared().initialize(withAPIKey:completion:)` | Brings up the SDK. Everything below is invalid before its completion fires. |
| `camera?.attach(to:)` | Hands Nosmai the view it renders the filtered preview into. No `AVCaptureSession` to write. |
| `camera?.startCapture()` | Opens the capture session. **Does not** start the filter pipeline. |
| `NosmaiSDK.sharedInstance()?.startProcessing()` | Starts the filter pipeline. Required — see [the model](#the-thing-that-surprises-people). |
| `camera?.switch()` | Front/back. Mirroring is derived from facing inside the SDK, so there is no mirror call to pair with it. |
| `effects?.applyEffect(_:completion:)` | Applies a `.nosmai` package. Routes AR effects and plain filters on the package's manifest type. |
| `effects?.clearAREffect()` / `clearFilter()` | Back to an unfiltered feed. |
| `NosmaiCore.shared().liveFrameStreamCallback` | The frame tap. **Not** `NosmaiSDK.setCVPixelBufferCallback` — see Gotchas. Assigning it enables live frame output; `nil` disables it. |
| `LocalVideoTrack.createBufferTrack(name:source:)` | The public factory for a push-driven track. `BufferCapturer`'s own initialiser is internal to LiveKit. |
| `BufferCapturer.capture(_:timeStampNs:)` | Pushes one `CVPixelBuffer` at the SDK's timestamp. |

---

## Gotchas

**Ask for the camera yourself.** `startCapture()` *checks*
`AVCaptureDevice.authorizationStatus` but never *requests* it. On a fresh install
the status is still `.notDetermined` when you get there, so the first launch
returns `false` — "Camera failed to start" — while iOS is showing the permission
prompt, and nothing retries. `ViewController` calls
`AVCaptureDevice.requestAccess(for: .video)` first for exactly this reason.

**Use `NosmaiCore.liveFrameStreamCallback`, not
`NosmaiSDK.setCVPixelBufferCallback`.** `NosmaiCore` installs one permanent block
into the SDK's single callback slot at init and fans out from there to the video
recorder *and* to your callback. Setting the SDK slot yourself clobbers Core's
block and silently detaches recording. Assigning `liveFrameStreamCallback` also
enables live frame output on its own — you do not need `setLiveFrameOutputEnabled`.

**That callback is not on the main thread.** It runs on Nosmai's render thread
with the camera thread waiting behind it, so anything slow in there costs preview
frame rate directly. Wrap and hand off; do not decode, resize, or hop queues.

**Set your `isStreaming` gate before publishing, not after.** `publish()` blocks
waiting for the track's first frame, so a gate that opens afterwards guarantees
the timeout it was meant to avoid.

**Never let LiveKit open a camera.** `createBufferTrack` is the only correct
factory here; `createCameraTrack` will fight Nosmai for the capture device.

**Turn simulcast off.** It is on by default, and every extra layer needs its own
differently-scaled copy of each frame — per-frame work on a path that exists to
avoid exactly that. The example passes
`RoomOptions(defaultVideoPublishOptions: VideoPublishOptions(simulcast: false))`.

**Leave `stopLocalTrackOnUnpublish` at its default here.** The Flutter bridge
tells you to set it `false`, and that is right *there* — the native object behind
that track belongs to the plugin. In this example the track and its
`BufferCapturer` are minted by LiveKit, so letting LiveKit stop them on unpublish
is correct. Do not copy the bridge's setting across without copying its reason.

**Camera switching goes through Nosmai**, never LiveKit. Mirroring is derived
from camera facing inside the SDK — there is no mirror call to make.

**Backgrounding needs nothing special.** iOS interrupts the capture session, so
Nosmai stops producing on its own; LiveKit mutes local `.camera`-source tracks
via `suspendLocalVideoTracksInBackground` (on by default) and unmutes them on
return. Publishing the track with `source: .camera` is what opts into that.

**Local dev servers need two Info.plist keys.** `NSAppTransportSecurity` for
cleartext `ws://`, and `NSLocalNetworkUsageDescription` because iOS 14+ gates LAN
access behind consent. Without the latter, signalling connects and then media
dies with `TRANSPORT_FAILURE`. Neither is needed against a `wss://` server, and
you should not ship `NSAllowsArbitraryLoads`.

**arm64 device only.** The pod sets
`EXCLUDED_ARCHS[sdk=iphonesimulator*] = arm64 x86_64`, so there is no simulator
build — not a stub, nothing at all. Plug in a phone.

---

## Testing locally

No cloud account needed:

```bash
brew install livekit livekit-cli
livekit-server --dev --bind 0.0.0.0

lk token create --api-key devkey --api-secret secret \
  --join --room my-room --identity phone --valid-for 720h
```

Use your machine's **LAN IP**, not `localhost` — a phone cannot reach the host
otherwise. Restarting `--dev` regenerates its signing key, so previously minted
tokens start failing with a bare 401.

`tools/livekit-viewer/` in the
[`nosmai_livekit_bridge`](https://github.com/nosmai/nosmai_livekit_bridge) repo
is a minimal browser viewer that renders the published stream without cropping
and reports live resolution, orientation, fps and codec. Serve it over plain
`http://` — `ws://` is blocked as mixed content from an `https://` page, which
also rules out the hosted LiveKit Meet demo against a local dev server.

To confirm frames are actually flowing, watch the Xcode console:

```
[NosmaiLiveKit] pushed 1 frames (720x1280)
[NosmaiLiveKit] pushed 60 frames (720x1280)
```

That log fires from inside the frame callback, so it is only reachable if a
buffer completed the full filter chain.

---

## How it works

### The frame path

Nosmai's output buffers are IOSurface-backed, so handing one to LiveKit is a
refcount bump rather than a GPU copy — no readback, no colour conversion, no CPU
copies. `BufferCapturer.capture` wraps the buffer in WebRTC's `RTCCVPixelBuffer`
and pushes it straight at the video source.

Unlike Android there is no shared-context step to get right: no EGL, so nothing
to join, and no ordering trap around `initialize()`. There is also no camera
plumbing to write — `NosmaiCamera` owns the `AVCaptureSession`, including
`switch()`. The Android example's `Camera2Helper` has no counterpart here.

### The files

| File | What it is |
|---|---|
| `NosmaiLiveKitExample/ViewController.swift` | The integration. Mostly UI; the three steps above are the point. |
| `NosmaiLiveKitExample/Bridging-Header.h` | Nosmai is an Objective-C framework with no Swift module map, so it is reached through a bridging header rather than `import nosmai`. |
| `project.yml` | The project definition. Source of truth; run `xcodegen generate`. |
| `Podfile` | `NosmaiCameraSDK` + `LiveKitClient`. Note the module is `LiveKitClient`, not `LiveKit`. |

---

## Licence

MIT — see [LICENSE](LICENSE). The Nosmai SDK itself is licensed separately.
