import UIKit
import AVFoundation
import LiveKitClient


/// Nosmai + LiveKit on iOS, natively.
///
/// **Nosmai owns the camera and the preview; LiveKit only publishes.**
///
/// The integration is three things:
///
///  1. Let Nosmai own capture — `NosmaiCore.shared.camera` opens the camera and
///     renders the filtered preview into a view you give it. Remember that
///     `startCapture()` and `startProcessing()` are both required.
///  2. Tap the filtered output with `NosmaiCore.liveFrameStreamCallback` and push
///     each buffer into a LiveKit `BufferCapturer`.
///  3. Never let LiveKit open a camera.
///
/// Unlike Android, there is no shared-context step: `CVPixelBuffer`s are
/// IOSurface-backed, so handing one to LiveKit is a refcount bump rather than a
/// GPU copy. There is also no camera plumbing to write — `NosmaiCamera` owns it,
/// including `switchCamera`.
final class ViewController: UIViewController {

    // ── Fill these in ────────────────────────────────────────────────────
    // Nosmai licence keys are bound to your bundle id (see project.yml).
    private let nosmaiLicenseKey = "YOUR_NOSMAI_IOS_KEY"

    // A device cannot reach your machine over localhost — use the LAN IP.
    //   livekit-server --dev --bind 0.0.0.0
    //   lk token create --api-key devkey --api-secret secret \
    //     --join --room my-room --identity phone --valid-for 720h
    private let livekitURL = "ws://192.168.1.100:7880"
    private let livekitToken = "YOUR_JOIN_TOKEN"

    // ── State ────────────────────────────────────────────────────────────
    private let previewView = UIView()
    private let statusLabel = UILabel()
    private let goLiveButton = UIButton(type: .system)
    private let switchButton = UIButton(type: .system)
    private let filterBar = UIScrollView()

    private var room: Room?
    private var capturer: BufferCapturer?
    private var isStreaming = false
    /// Guards the Go Live button while a connect is still in flight — without it
    /// a second tap during "Connecting…" builds a second Room.
    private var isConnecting = false

    /// Effects discovered in the bundle, so adding a .nosmai needs no code change.
    private var filters: [URL] = []
    private var selectedFilter: URL?
    private var filterButtons: [UIButton] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        discoverFilters()
        requestCameraAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.status("Camera permission denied — enable it in Settings")
                return
            }
            self.startNosmai()
        }
    }

    // ── Nosmai: owns the camera and the preview ──────────────────────────

    /// Ask for the camera BEFORE Nosmai starts.
    ///
    /// `startCapture()` *checks* `AVCaptureDevice.authorizationStatus` but never
    /// *requests* it. On a fresh install the status is still `.notDetermined`
    /// when we get there, so `startCapture()` returns false and the first run
    /// dies with "Camera failed to start" — even though iOS is showing the
    /// permission prompt at that very moment, and nothing ever retries.
    /// Asking first makes the first launch behave like every later one.
    private func requestCameraAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    private func startNosmai() {
        NosmaiCore.shared().initialize(withAPIKey: nosmaiLicenseKey) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard success else {
                    self.status("Nosmai init failed: \(error?.localizedDescription ?? "unknown")")
                    return
                }
                // The SDK renders the filtered preview into this view and drives
                // the camera itself — no AVCaptureSession to write.
                NosmaiCore.shared().camera?.attach(to: self.previewView)

                // BOTH calls are required, always, in this order.
                //
                // startCapture() only opens the capture session; it deliberately
                // does not start SDK processing, so the caller must pair it with
                // startProcessing(). Without that, every camera frame is
                // discarded before it reaches the pipeline, which breaks two
                // things at once and neither reports an error:
                //   • no CVPixelBuffers are emitted, so a LiveKit publish()
                //     waits for a first frame that never comes and times out;
                //   • applyEffect() only queues the effect and reports success —
                //     the queue is drained by startProcessing, so filters
                //     silently do nothing.
                // The raw camera preview still shows live video throughout,
                // which makes this look like "only the filters are broken".
                if NosmaiCore.shared().camera?.startCapture() == true {
                    NosmaiSDK.sharedInstance()?.startProcessing()
                    self.status("Nosmai ready — tap Go Live")
                } else {
                    self.status("Camera failed to start")
                }
            }
        }
    }

    @objc private func switchCamera() {
        // Camera switching goes through NOSMAI, never LiveKit — LiveKit does not
        // own the camera, and mirroring is derived from facing inside the SDK.
        NosmaiCore.shared().camera?.switch()
        status("Camera switched")
    }

    // ── LiveKit: only publishes ──────────────────────────────────────────

    @objc private func toggleStreaming() {
        guard !isConnecting else { return }
        isStreaming ? stopStreaming() : startStreaming()
    }

    private func startStreaming() {
        isConnecting = true
        status("Connecting…")
        Task {
            defer { isConnecting = false }
            do {
                // Simulcast is ON by default, and each extra layer needs its own
                // differently-scaled copy of every frame — reintroducing per-frame
                // work on a path that exists to avoid exactly that. One layer is
                // the right default here; turn it back on deliberately if you
                // need it.
                let room = Room(roomOptions: RoomOptions(
                    defaultVideoPublishOptions: VideoPublishOptions(simulcast: false)
                ))
                self.room = room
                try await room.connect(url: livekitURL, token: livekitToken)

                // A BufferCapturer takes frames we push, rather than opening a
                // camera of its own. This is the whole integration point.
                // createBufferTrack is the public factory; BufferCapturer's
                // own initializer is internal to the SDK.
                let track = LocalVideoTrack.createBufferTrack(name: "nosmai", source: .camera)
                guard let capturer = track.capturer as? BufferCapturer else {
                    self.status("Unexpected capturer type")
                    return
                }
                self.capturer = capturer

                // Set before arming the callback: publish() waits for the track
                // to produce its first frame, so the gate below must already be
                // open during that window.
                self.isStreaming = true

                // Arm frame output through NosmaiCore's FAN-OUT — NOT through
                // NosmaiSDK.setCVPixelBufferCallback.
                //
                // NosmaiCore installs one permanent block into the SDK
                // singleton's single callback slot at init and dispatches each
                // frame from there to the video recorder AND to
                // liveFrameStreamCallback. Calling setCVPixelBufferCallback
                // ourselves would clobber Core's block and detach recording.
                // Assigning this property also enables live frame output on its
                // own, so no setLiveFrameOutputEnabled call is needed here.
                //
                // This block runs on Nosmai's render thread, not the main thread,
                // with the camera thread waiting behind it. Anything slow in here
                // costs preview frame rate directly, so it does the minimum:
                // gate, hand off, count.
                var pushed = 0
                NosmaiCore.shared().liveFrameStreamCallback = { [weak self] pixelBuffer, timestamp in
                    guard self?.isStreaming == true else { return }
                    // Pushed synchronously: the buffer is IOSurface-backed and
                    // LiveKit retains what it needs, so there is no copy here.
                    // Holding it beyond this call would starve the SDK's shallow
                    // producer pool instead.
                    capturer.capture(pixelBuffer,
                                     timeStampNs: Int64(timestamp * 1_000_000_000))
                    // Kept in the block, not on self: only this thread touches it,
                    // and it resets with every new streaming session.
                    pushed += 1
                    if pushed == 1 || pushed % 60 == 0 {
                        NSLog("[NosmaiLiveKit] pushed %ld frames (%ldx%ld)", pushed,
                              CVPixelBufferGetWidth(pixelBuffer),
                              CVPixelBufferGetHeight(pixelBuffer))
                    }
                }

                try await room.localParticipant.publish(videoTrack: track)

                await MainActor.run {
                    self.goLiveButton.setTitle("Stop", for: .normal)
                    self.status("Publishing — check a remote viewer")
                }
            } catch {
                await MainActor.run { self.status("Failed: \(error.localizedDescription)") }
                stopStreaming()
            }
        }
    }

    /// Teardown order: stop producing before leaving the room.
    private func stopStreaming() {
        isStreaming = false
        // Clearing the fan-out callback is what disables live-frame output; the
        // isStreaming gate above already stops frames reaching the capturer.
        // Do NOT also poke setCVPixelBufferCallback — that slot belongs to
        // NosmaiCore, and clearing it breaks recording too.
        NosmaiCore.shared().liveFrameStreamCallback = nil
        capturer = nil
        Task { await room?.disconnect(); room = nil }
        goLiveButton.setTitle("Go Live", for: .normal)
        status("Stopped")
    }

    // ── Filters ──────────────────────────────────────────────────────────

    /// Build the selector from whatever .nosmai packages are bundled, so adding
    /// an effect is a drag-and-drop rather than a code change.
    private func discoverFilters() {
        // Look in the bundle root AND in Filters/, since a folder reference
        // keeps its directory structure while individual resources are
        // flattened. Checking both means it works either way.
        let root = Bundle.main.urls(forResourcesWithExtension: "nosmai", subdirectory: nil) ?? []
        let sub = Bundle.main.urls(forResourcesWithExtension: "nosmai", subdirectory: "Filters") ?? []
        filters = (root + sub).sorted { $0.lastPathComponent < $1.lastPathComponent }
        NSLog("[NosmaiLiveKit] discovered %d filter(s)", filters.count)

        var x: CGFloat = 8
        addFilterChip(title: "None", url: nil, x: &x)
        for url in filters {
            addFilterChip(title: displayName(url), url: url, x: &x)
        }
        filterBar.contentSize = CGSize(width: x, height: 44)
    }

    private func addFilterChip(title: String, url: URL?, x: inout CGFloat) {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 13)
        b.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        b.setTitleColor(.white, for: .normal)
        b.layer.cornerRadius = 8
        b.sizeToFit()
        b.frame = CGRect(x: x, y: 4, width: b.frame.width + 24, height: 36)
        b.addAction(UIAction { [weak self] _ in self?.select(url) }, for: .touchUpInside)
        filterBar.addSubview(b)
        filterButtons.append(b)
        x += b.frame.width + 8
    }

    /// "reindeer_face.nosmai" -> "Reindeer Face"
    private func displayName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func select(_ url: URL?) {
        guard let url else {
            NosmaiCore.shared().effects?.clearAREffect()
            NosmaiCore.shared().effects?.clearFilter()
            selectedFilter = nil
            status("Filters cleared")
            return
        }
        // applyEffect handles both AR effects and plain filters — the SDK routes
        // on the package's manifest type.
        NosmaiCore.shared().effects?.applyEffect(url.path) { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    self?.selectedFilter = url
                    self?.status("Applied \(self?.displayName(url) ?? "")")
                } else {
                    self?.status("Filter failed: \(error?.localizedDescription ?? "unknown")")
                }
            }
        }
    }

    // ── UI ───────────────────────────────────────────────────────────────

    private func status(_ msg: String) {
        NSLog("[NosmaiLiveKit] %@", msg)
        DispatchQueue.main.async { self.statusLabel.text = msg }
    }

    private func buildUI() {
        view.backgroundColor = .black

        previewView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewView)

        filterBar.translatesAutoresizingMaskIntoConstraints = false
        filterBar.showsHorizontalScrollIndicator = false
        view.addSubview(filterBar)

        switchButton.setTitle("Switch", for: .normal)
        switchButton.addTarget(self, action: #selector(switchCamera), for: .touchUpInside)
        goLiveButton.setTitle("Go Live", for: .normal)
        goLiveButton.addTarget(self, action: #selector(toggleStreaming), for: .touchUpInside)
        for b in [switchButton, goLiveButton] {
            b.translatesAutoresizingMaskIntoConstraints = false
            b.backgroundColor = UIColor.systemPurple
            b.setTitleColor(.white, for: .normal)
            b.layer.cornerRadius = 10
            b.contentEdgeInsets = UIEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
            view.addSubview(b)
        }

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .lightGray
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.numberOfLines = 2
        statusLabel.text = "Starting…"
        view.addSubview(statusLabel)

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: g.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: filterBar.topAnchor, constant: -8),

            filterBar.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            filterBar.heightAnchor.constraint(equalToConstant: 44),
            filterBar.bottomAnchor.constraint(equalTo: switchButton.topAnchor, constant: -8),

            switchButton.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            switchButton.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -12),
            goLiveButton.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            goLiveButton.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -12),

            statusLabel.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -8),
        ])
    }
}
