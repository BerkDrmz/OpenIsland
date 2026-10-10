import AppKit
import AVFoundation
import IslandCore
import SwiftUI

/// Session mutations are confined to CameraMirror's serial queue, including configuration.
protocol CameraSessionBackend: AnyObject, Sendable {
    var session: AVCaptureSession { get }
    /// Çalışan oturum koptu (AVCaptureSession çalışma hatası veya kullanılan kamera ayrıldı). Herhangi bir iş
    /// parçacığında çağrılabilir; `CameraMirror` ana kuyruğa alır.
    var onFailure: (@Sendable () -> Void)? { get set }
    func configure(cameraID: String?) -> Bool
    func start() -> Bool
    func stop()
    /// Durdurur ve girişi bırakır: sonraki `configure` kamerayı baştan bağlar.
    func reset()
}

private final class SessionBox: CameraSessionBackend, @unchecked Sendable {
    let session = AVCaptureSession()
    var onFailure: (@Sendable () -> Void)? {
        get { lock.withLock { failureHandler } }
        set { lock.withLock { failureHandler = newValue } }
    }
    private let lock = NSLock()
    private var failureHandler: (@Sendable () -> Void)?
    /// Bağlı kameranın kimliği (bildirimler başka iş parçacığında okur).
    private var connectedDeviceID: String?
    private var observers: [NSObjectProtocol] = []

    /// Cihazda görülen: uyku/uyanma ya da kamerayı başka bir uygulamanın kullanması sonrası CoreMediaIO kamerayı yeni
    /// bir nesneyle yeniden duyurabiliyor. Eski giriş `startRunning` sonrası hemen çalışma hatası veriyordu
    /// (-11800; altında `CMIOGraphConnectNodeInput` -67520) ve önizleme siyah kalıyordu. Bu iki bildirim o kopmayı
    /// yakalar; düzeltme `CameraMirror.sessionFailed` içinde.
    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session,
                                            queue: nil) { [weak self] _ in self?.onFailure?() })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil,
                                            queue: nil) { [weak self] note in
            guard let self, let device = note.object as? AVCaptureDevice,
                  self.lock.withLock({ self.connectedDeviceID == device.uniqueID }) else { return }
            self.onFailure?()
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func configure(cameraID: String?) -> Bool {
        let devices = CameraMirror.discovery().devices
        guard let device = devices.first(where: { $0.uniqueID == cameraID })
            ?? devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
            ?? devices.first ?? AVCaptureDevice.default(for: .video) else { return false }
        // Yalnızca aynı ve hâlâ bağlı aygıt nesnesi yeniden kullanılır; kimlik aynı olsa bile yeniden duyurulmuş bir
        // kamera için giriş baştan kurulur (eskiden kimlik eşleşince bayat giriş kullanılıyordu).
        let current = session.inputs.lazy.compactMap { $0 as? AVCaptureDeviceInput }.first
        if let current, current.device === device, device.isConnected { return true }
        guard let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let previous = session.inputs
        previous.forEach(session.removeInput)
        guard session.canAddInput(input) else {
            previous.filter(session.canAddInput).forEach(session.addInput)
            return false
        }
        session.sessionPreset = .high
        session.addInput(input)
        lock.withLock { connectedDeviceID = device.uniqueID }
        return true
    }

    func start() -> Bool {
        if !session.isRunning { session.startRunning() }
        return session.isRunning
    }

    func stop() { if session.isRunning { session.stopRunning() } }

    func reset() {
        stop()
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.commitConfiguration()
        lock.withLock { connectedDeviceID = nil }
    }
}

/// Closing the panel invalidates queued work immediately, without waiting for the capture queue.
private final class CameraRequestGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func advance() -> UInt64 { lock.withLock { value &+= 1; return value } }
    func contains(_ generation: UInt64) -> Bool { lock.withLock { value == generation } }
}

/// Live preview only; no capture or recording. An unused mirror never creates a session.
@MainActor
@Observable
final class CameraMirror {
    enum State: Equatable { case idle, starting, running, denied, unavailable }
    struct Camera: Identifiable, Hashable {
        let id: String
        let name: String
    }

    private(set) var state: State = .idle
    private(set) var cameras: [Camera] = []
    private(set) var selectedCameraID: String? = UserDefaults.standard.string(forKey: "mirrorCameraID")
    @ObservationIgnored private var sessionBox: (any CameraSessionBackend)?
    @ObservationIgnored private let queue = DispatchQueue(label: "openisland.camera", qos: .userInitiated)
    @ObservationIgnored private let requests = CameraRequestGeneration()
    @ObservationIgnored private let makeSession: () -> any CameraSessionBackend
    @ObservationIgnored private let readAuthorization: () -> AVAuthorizationStatus
    @ObservationIgnored private let requestAuthorization: (@escaping @Sendable (Bool) -> Void) -> Void
    /// Kopan oturum için bu açılıştaki yeniden bağlanma denemeleri (`sessionFailed`); her `start` sıfırlar.
    @ObservationIgnored private var recoveries = 0
    static let maximumRecoveries = 2

    init(makeSession: @escaping () -> any CameraSessionBackend = { SessionBox() },
         readAuthorization: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .video) },
         requestAuthorization: @escaping (@escaping @Sendable (Bool) -> Void) -> Void = {
             AVCaptureDevice.requestAccess(for: .video, completionHandler: $0)
         }) {
        self.makeSession = makeSession
        self.readAuthorization = readAuthorization
        self.requestAuthorization = requestAuthorization
    }

    private var box: any CameraSessionBackend {
        if let sessionBox { return sessionBox }
        let box = makeSession()
        box.onFailure = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.sessionFailed() } }
        }
        sessionBox = box
        return box
    }
    var session: AVCaptureSession { box.session }

    func start() {
        guard state != .running, state != .starting else { return }
        let generation = requests.advance()
        recoveries = 0
        state = .starting
        switch readAuthorization() {
        case .authorized:
            run(generation: generation)
        case .notDetermined:
            requestAuthorization { [weak self] granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.state == .starting,
                              self.requests.contains(generation) else { return }
                        if granted { self.run(generation: generation) } else { self.state = .denied }
                    }
                }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        guard state == .running || state == .starting else { return }
        _ = requests.advance()
        state = .idle
        guard let box = sessionBox else { return }
        queue.async { box.stop() }
    }

    private func run(generation: UInt64) {
        let box = box, requests = requests, cameraID = selectedCameraID
        queue.async { [weak self] in
            guard requests.contains(generation) else { return }
            let configured = box.configure(cameraID: cameraID)
            guard requests.contains(generation) else { return }
            let running = configured && box.start()
            if !running || !requests.contains(generation) { box.stop() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, requests.contains(generation) else { return }
                    self.state = running ? .running : .unavailable
                }
            }
        }
    }

    /// Ayna açıkken oturum koptu: girişi bırakıp kamerayı baştan bağla. Sınırlı deneme (döngü yok); yine olmazsa
    /// siyah önizleme yerine "başlatılamadı" gösterilir. Panel kapalıyken gelen bildirim yok sayılır.
    private func sessionFailed() {
        guard state == .running || state == .starting, let box = sessionBox else { return }
        let generation = requests.advance()
        guard recoveries < Self.maximumRecoveries else {
            state = .unavailable
            queue.async { box.reset() }
            return
        }
        recoveries += 1
        // Görünen önizleme sökülmez: aynı önizleme katmanı yeni girişe birkaç ms içinde bağlanır. Durumu
        // "başlatılıyor"a çevirmek önizlemeyi kaldırıp ölçek geçişiyle yeniden ekliyordu (görünür takılma).
        if state != .running { state = .starting }
        queue.async { box.reset() }
        run(generation: generation)
    }

    /// Kamera listesi kamera kuyruğunda taranır: süreçteki ilk tarama ~0,22 sn sürüyor (ölçüm) ve ana iş
    /// parçacığında Ayna sekmesi açılırken adanın animasyonunu donduruyordu.
    func refreshCameras() {
        queue.async { [weak self] in
            let found = Self.discovery().devices.map { Camera(id: $0.uniqueID, name: $0.localizedName) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.cameras != found else { return }
                    self.cameras = found
                }
            }
        }
    }

    func select(_ camera: Camera) {
        selectedCameraID = camera.id
        UserDefaults.standard.set(camera.id, forKey: "mirrorCameraID")
        guard state == .running || state == .starting, readAuthorization() == .authorized else { return }
        run(generation: requests.advance())
    }

    nonisolated fileprivate static func discovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video, position: .unspecified
        )
    }
}

/// AVCaptureVideoPreviewLayer'ı SwiftUI'a taşır; ayna görüntüsü için yatay çevrilir.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
    }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        nonisolated(unsafe) private var startObserver: NSObjectProtocol?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            previewLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(previewLayer)
            // Kurtarmada giriş yenilenince önizleme bağlantısı da yenilenir; ayna çevirmesi yeniden uygulanır.
            startObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.didStartRunningNotification, object: nil, queue: .main
            ) { [weak self] note in
                let started = note.object.map { ObjectIdentifier($0 as AnyObject) }
                MainActor.assumeIsolated {
                    guard let self, let session = self.previewLayer.session,
                          started == ObjectIdentifier(session) else { return }
                    self.needsLayout = true
                }
            }
        }

        deinit {
            if let startObserver { NotificationCenter.default.removeObserver(startObserver) }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) desteklenmiyor") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
            CATransaction.commit()
        }
    }
}

struct MirrorPanel: View {
    let mirror: CameraMirror

    var body: some View {
        HStack(spacing: IslandLayoutEngine.Mirror.spacing) {
            ZStack {
                Circle().fill(IslandPalette.fill)
                switch mirror.state {
                case .running:
                    CameraPreview(session: mirror.session)
                        .clipShape(Circle())
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                case .denied:
                    Image(systemName: "video.slash.fill").font(.system(size: 26)).foregroundStyle(IslandPalette.tertiary)
                case .unavailable:
                    Image(systemName: "web.camera").font(.system(size: 26)).foregroundStyle(IslandPalette.tertiary)
                        .accessibilityHidden(true)
                case .idle, .starting:
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: IslandLayoutEngine.Mirror.previewSize, height: IslandLayoutEngine.Mirror.previewSize)
            .overlay(Circle().strokeBorder(IslandPalette.separator, lineWidth: 0.5))
            .accessibilityLabel("Kamera önizlemesi")

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Ayna").font(IslandType.title)
                    Spacer()
                    Menu {
                        ForEach(mirror.cameras) { camera in
                            Button {
                                mirror.select(camera)
                            } label: {
                                if camera.id == mirror.selectedCameraID { Label(camera.name, systemImage: "checkmark") } else { Text(camera.name) }
                            }
                        }
                    } label: {
                        Image(systemName: "web.camera").font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Kamera seç")
                    .accessibilityLabel("Kamera seç")
                    .onAppear(perform: mirror.refreshCameras)
                }
                Text(caption)
                    .font(IslandType.body)
                    .foregroundStyle(IslandPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if mirror.state == .denied {
                    Button("Kamera iznini aç") {
                        NSWorkspace.shared.open(PermissionsCenter.Pane.camera.url)
                    }
                    .buttonStyle(.plain)
                    .font(IslandType.bodyEmphasized)
                } else if mirror.state == .unavailable {
                    Button("Yeniden dene", action: mirror.start)
                        .buttonStyle(.plain)
                        .font(IslandType.bodyEmphasized)
                }
            }
            .frame(maxWidth: IslandLayoutEngine.Mirror.captionWidth, alignment: .leading)
        }
        .animation(IslandMotion.expand, value: mirror.state)
        .onAppear { mirror.start() }
        .onDisappear { mirror.stop() }
    }

    private var caption: String {
        switch mirror.state {
        case .running: "Toplantıdan önce saç ve kadraj kontrolü. Görüntü kaydedilmez; sekmeden çıkınca kamera kapanır."
        case .denied: "Kamera izni verilmedi. Sistem Ayarları › Gizlilik ve Güvenlik › Kamera."
        case .unavailable: "Kamera başlatılamadı. Kapak kapalı olabilir ya da kamera az önce başka bir uygulamadaydı."
        case .idle, .starting: "Kamera başlatılıyor…"
        }
    }
}
