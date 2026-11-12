import ARKit
import AVFoundation
import CoreLocation
import CoreMotion
import Observation
import SwiftUI
import WatchConnectivity

@MainActor
@Observable
final class WalkModel: NSObject, @preconcurrency CLLocationManagerDelegate, WCSessionDelegate {
    enum Mode: String, CaseIterable { case practice = "Practice", walk = "Live walk" }
    enum AudioStyle: String, CaseIterable { case spatial = "Spatial sound", speech = "Speech only" }
    var mode: Mode = .practice { didSet { if mode != oldValue { reset() } } }
    var audioStyle: AudioStyle = .spatial { didSet { audio.stopCue(); lastSpokenDirection = nil } }
    var savedRoute: WalkRoute?
    var status = "Ready for practice."
    var motionStatus = "Turn on AirPods motion to try real head tracking."
    var routeMessage = ""
    private(set) var cameraView: ARSCNView?
    private(set) var cameraStatus = ""
    private(set) var cameraYaw: Double?
    private(set) var headphoneYaw: Double?
    private(set) var audioOutput = ""
    private(set) var audioTestStatus = ""
    private(set) var cameraGuidesAudio = false
    private var cameraReferenceYaw: Double?
    private var cameraReferenceBearing = 0.0
    private var cameraRequest = UUID()
    private var headphoneRequest = UUID()
    private var headphoneStarted = 0.0
    private var lastCameraTick = 0.0
    private var audioTest: Task<Void, Never>?

    var cameraTurn: Double? {
        guard let cameraYaw, let cameraReferenceYaw, let route, !arrived,
              mode == .practice || locationUsable else { return nil }
        return signedAngle(route.heading(from: step) - cameraReferenceBearing
                           - signedAngle(cameraYaw - cameraReferenceYaw))
    }

    var useManualPractice: Bool {
        mode == .practice && !usingHeadphones && !cameraGuidesAudio
    }
    var practiceHeading = 0.0
    private(set) var step = 0
    private(set) var running = false
    private(set) var arrived = false
    private(set) var aligned = false
    private(set) var latestPoint: Point?
    private(set) var motionAvailable = false
    private(set) var usingHeadphones = false
    private(set) var heading: Double?
    private var latestFix: CLLocation?
    private var lastFixReceived = 0.0
    private var motionSample: CMDeviceMotion?
    private var lastMotionReceived = 0.0
    private var referenceYaw: Double?
    private var referenceBearing = 0.0
    private var lastSensor: CMDeviceMotion.SensorLocation?
    private var alignmentStart: Double?
    private var guidanceRequested = false
    private var lastSpokenDirection: String?
    private var lastAudioError = false
    private var loop: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private let location = CLLocationManager()
    private let motion = CMHeadphoneMotionManager()
    private let audio = GuidanceAudio()
    private let fileURL = URL.applicationSupportDirectory.appendingPathComponent("saved-route.json")

    var route: WalkRoute? { mode == .practice ? .practice : savedRoute }
    var instruction: String {
        if arrived { return "You’ve reached the end of the route." }
        return route?.instruction(from: step) ?? "Import a walking route to begin."
    }
    var degreesToTurn: Double? {
        guard let route, let heading else { return nil }
        return signedAngle(route.heading(from: step) - heading)
    }

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.activityType = .fitness
        location.distanceFilter = 1
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(WalkRoute.self, from: data),
           decoded.points.count >= 2 { savedRoute = decoded }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func begin() {
        guard route != nil, !running else { return }
        reset()
        running = true
        UIApplication.shared.isIdleTimerDisabled = mode == .walk
        if mode == .practice {
            heading = 0
            status = "Practice started. Use the turn buttons or connect AirPods."
            requestCue()
        } else {
            status = "Waiting for a location fix near the route start."
            location.requestWhenInUseAuthorization()
            location.startUpdatingLocation()
            enableHeadphones()
        }
        startLoop()
    }

    func reset() {
        loop?.cancel()
        loop = nil
        running = false
        location.stopUpdatingLocation()
        stopHeadphoneMotion()
        stopCamera()
        audioTest?.cancel()
        audioTest = nil
        audioTestStatus = ""
        audio.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        arrived = false
        aligned = false
        step = 0
        latestPoint = nil
        latestFix = nil
        lastFixReceived = 0
        motionSample = nil
        lastMotionReceived = 0
        lastSensor = nil
        referenceYaw = nil
        heading = nil
        practiceHeading = 0
        motionAvailable = false
        usingHeadphones = false
        guidanceRequested = false
        alignmentStart = nil
        lastAudioError = false
        motionStatus = "Turn on AirPods motion to try real head tracking."
        status = mode == .practice ? "Ready for practice." : "Start near the first point of the saved route."
    }

    func enableHeadphones() {
        guard running, !arrived else { return }
        if [.denied, .restricted].contains(CMHeadphoneMotionManager.authorizationStatus()) {
            motionStatus = "Allow Motion & Fitness for Waypoint in Settings."
            return
        }
        if !motion.isDeviceMotionAvailable {
            motionStatus = "No compatible headphones detected. Connect and wear both AirPods, then try again."
            return
        }
        stopHeadphoneMotion()
        motionStatus = "Waiting for AirPods motion. Allow Motion & Fitness if prompted."
        usingHeadphones = true
        headphoneStarted = ProcessInfo.processInfo.systemUptime
        if !cameraGuidesAudio { invalidateHeading() }
        let request = headphoneRequest
        motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, error in
            MainActor.assumeIsolated {
                guard let self, self.headphoneRequest == request else { return }
                if let sample { self.receiveMotion(sample) }
                else if let error {
                    self.stopHeadphoneMotion()
                    if !self.cameraGuidesAudio { self.invalidateHeading() }
                    self.motionStatus = "AirPods motion stopped. " + error.localizedDescription
                }
            }
        }
    }

    private func stopHeadphoneMotion() {
        headphoneRequest = UUID()
        motion.stopDeviceMotionUpdates()
        usingHeadphones = false
        motionAvailable = false
        motionSample = nil
        headphoneYaw = nil
        referenceYaw = nil
        lastMotionReceived = 0
        lastSensor = nil
    }

    func usePracticeButtons() {
        guard mode == .practice else { return }
        stopHeadphoneMotion()
        cameraGuidesAudio = false
        heading = practiceHeading
        motionStatus = "Practice buttons active."
        requestCue()
    }

    private func receiveMotion(_ sample: CMDeviceMotion) {
        let now = ProcessInfo.processInfo.systemUptime
        if (lastSensor != nil && lastSensor != sample.sensorLocation)
            || (lastMotionReceived > 0 && now - lastMotionReceived > 1) {
            referenceYaw = nil
            if !cameraGuidesAudio { invalidateHeading() }
        }
        lastSensor = sample.sensorLocation
        lastMotionReceived = now
        motionSample = sample
        motionAvailable = true
        headphoneYaw = -(sample.attitude.yaw * 180 / .pi)
        if let referenceYaw, !cameraGuidesAudio {
            heading = signedAngle(referenceBearing - (sample.attitude.yaw - referenceYaw) * 180 / .pi)
        } else {
            motionStatus = "AirPods motion received. Turn your head to check the angle, then tap Align AirPods."
        }
    }

    func startCamera() async {
        guard running, !arrived, cameraView == nil else { return }
        guard ARWorldTrackingConfiguration.isSupported else {
            cameraStatus = "Camera tracking requires a supported iPhone or iPad."
            return
        }
        let request = UUID()
        cameraRequest = request
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        guard cameraRequest == request, running, !arrived else { return }
        guard allowed else {
            cameraStatus = "Allow Camera for Waypoint in Settings."
            return
        }
        let view = ARSCNView()
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        view.session.run(configuration)
        cameraView = view
        cameraStatus = "Starting camera tracking. Point the rear camera down the route."
    }

    func stopCamera() {
        cameraRequest = UUID()
        cameraView?.session.pause()
        cameraView = nil
        cameraStatus = ""
        cameraReferenceYaw = nil
        cameraYaw = nil
        if cameraGuidesAudio {
            cameraGuidesAudio = false
            invalidateHeading()
            if let referenceYaw, let sample = motionSample, motionAvailable {
                heading = signedAngle(referenceBearing - (sample.attitude.yaw - referenceYaw) * 180 / .pi)
            } else if useManualPractice && running && !arrived {
                heading = practiceHeading
            }
            if heading != nil { requestCue() }
        }
    }

    func alignCamera() {
        guard let cameraYaw, let route, !arrived else { return }
        if mode == .walk && !atReference(route) {
            status = "Return to the start of this leg before aligning."
            return
        }
        cameraReferenceYaw = cameraYaw
        cameraReferenceBearing = mode == .practice ? practiceHeading : route.heading(from: step)
        if heading == nil || !usingHeadphones {
            cameraGuidesAudio = true
            heading = cameraReferenceBearing
            requestCue()
        }
    }

    func useCameraForAudio() {
        guard let cameraYaw, let cameraReferenceYaw else { return }
        cameraGuidesAudio = true
        heading = signedAngle(cameraReferenceBearing + cameraYaw - cameraReferenceYaw)
        requestCue()
    }

    private func updateCamera() {
        guard let session = cameraView?.session else { return }
        guard let frame = session.currentFrame,
              ProcessInfo.processInfo.systemUptime - frame.timestamp < 0.75,
              case .normal = frame.camera.trackingState else {
            if cameraYaw != nil {
                cameraReferenceYaw = nil
                if cameraGuidesAudio { invalidateHeading() }
            }
            cameraYaw = nil
            cameraStatus = "Camera tracking limited. Hold the phone upright in good light."
            return
        }
        let axis = frame.camera.transform.columns.2
        guard hypot(axis.x, axis.z) > 0.35 else {
            cameraYaw = nil
            if cameraGuidesAudio { invalidateHeading() }
            cameraStatus = "Point the rear camera along the route."
            return
        }
        let yaw = atan2(Double(-axis.x), Double(axis.z)) * 180 / .pi
        cameraYaw = yaw
        if let cameraReferenceYaw {
            cameraStatus = "Camera aligned to the route."
            if cameraGuidesAudio {
                heading = signedAngle(cameraReferenceBearing + yaw - cameraReferenceYaw)
            }
        } else {
            cameraStatus = "Point the camera along this leg, then tap Align camera."
        }
    }

    func testAudio() {
        audioTest?.cancel()
        audio.stopCue()
        audioTestStatus = "Testing left, then right."
        audioTest = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled { self.audio.stopCue(); self.audioTest = nil }
            }
            do {
                try self.audio.cue(offset: -75)
                try await Task.sleep(for: .milliseconds(850))
                self.audio.stopCue()
                try await Task.sleep(for: .milliseconds(220))
                try self.audio.cue(offset: 75)
                try await Task.sleep(for: .milliseconds(850))
                self.audioTestStatus = "Test finished. You should hear left, then right."
            } catch is CancellationError {
                return
            } catch {
                self.audioTestStatus = "Audio test failed. " + error.localizedDescription
            }
        }
    }

    func calibrate() {
        guard running, !arrived, let route, let sample = motionSample,
              motionAvailable, ProcessInfo.processInfo.systemUptime - lastMotionReceived < 1 else {
            motionStatus = "Wait for live AirPods motion before aligning."
            return
        }
        if mode == .walk && (!atReference(route)) {
            status = "Return to the start of this leg before aligning."
            return
        }
        cameraGuidesAudio = false
        referenceYaw = sample.attitude.yaw
        referenceBearing = mode == .practice ? practiceHeading : route.heading(from: step)
        heading = referenceBearing
        motionStatus = "AirPods calibrated. Head turns update the cue."
        status = "Heading aligned."
        requestCue()
    }

    func turnPractice(by degrees: Double) {
        guard mode == .practice, running, !arrived, useManualPractice else { return }
        practiceHeading = signedAngle(practiceHeading + degrees)
        heading = practiceHeading
        evaluateCue(at: ProcessInfo.processInfo.systemUptime)
    }

    func walkPracticeLeg() {
        guard mode == .practice, running, aligned, !arrived else { return }
        advance()
    }

    func requestCue() {
        guard running else { return }
        if arrived { audio.say(instruction); return }
        audio.stopCue()
        aligned = false
        alignmentStart = nil
        lastSpokenDirection = nil
        lastAudioError = false
        guidanceRequested = true
        if heading == nil {
            audio.say(mode == .walk ? "Heading unavailable. " + instruction : "Align your AirPods or camera, or use the practice buttons.")
        } else if audioStyle == .spatial {
            audio.say(instruction)
        }
    }

    func suspend() {
        guard running else { return }
        reset()
        status = "Session paused when the app left the foreground. Start again to recalibrate."
    }

    private func startLoop() {
        loop?.cancel()
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(35))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCameraTick > 0.1 {
            lastCameraTick = now
            updateCamera()
            audioOutput = audio.outputName
        }
        if usingHeadphones && now - max(lastMotionReceived, headphoneStarted) > 1.5 {
            if motionAvailable {
                referenceYaw = nil
                if !cameraGuidesAudio { invalidateHeading() }
            }
            motionAvailable = false
            headphoneYaw = nil
            switch CMHeadphoneMotionManager.authorizationStatus() {
            case .denied, .restricted: motionStatus = "Motion permission is off. Check Settings."
            default: motionStatus = "No live motion samples. Check that AirPods are connected and worn."
            }
        }
        guard audioTest == nil else { return }
        evaluateCue(at: now)
    }

    private func invalidateHeading() {
        referenceYaw = nil
        heading = nil
        aligned = false
        alignmentStart = nil
        if running && !arrived { guidanceRequested = true }
        audio.stopCue()
    }

    private func evaluateCue(at now: Double) {
        guard running, !arrived, let error = degreesToTurn,
              mode == .practice || locationUsable else {
            audio.stopCue()
            alignmentStart = nil
            aligned = false
            if mode == .walk && running && !arrived && latestFix != nil && !locationUsable {
                status = "Location uncertain. Directional confirmation paused."
            }
            return
        }
        let magnitude = abs(error)
        if !guidanceRequested {
            guard aligned, magnitude > 20 else { return }
            aligned = false
            guidanceRequested = true
        }
        if magnitude <= 14 {
            audio.stopCue()
            if alignmentStart == nil { alignmentStart = now }
            if now - (alignmentStart ?? now) >= 0.35 {
                aligned = true
                guidanceRequested = false
                status = cameraGuidesAudio ? "Camera pointing along the route." : "Facing the route."
                audio.say(cameraGuidesAudio ? "The camera is pointing along the route." : "You’re facing the route.")
            }
        } else {
            alignmentStart = nil
            aligned = false
            let direction = magnitude > 155 ? "Turn around." : error < 0 ? "Turn left." : "Turn right."
            status = direction
            if audioStyle == .speech {
                if lastSpokenDirection != direction {
                    audio.say(direction)
                    lastSpokenDirection = direction
                }
            } else {
                do { try audio.cue(offset: error) }
                catch {
                    if !lastAudioError {
                        lastAudioError = true
                        status = "Spatial playback unavailable. Using spoken directions."
                    }
                    if lastSpokenDirection != direction {
                        audio.say(direction)
                        lastSpokenDirection = direction
                    }
                }
            }
        }
    }

    private var locationUsable: Bool {
        guard let fix = latestFix else { return false }
        return fix.horizontalAccuracy >= 0 && fix.horizontalAccuracy <= 12
            && ProcessInfo.processInfo.systemUptime - lastFixReceived < 6
    }

    private func atReference(_ route: WalkRoute) -> Bool {
        guard locationUsable, let current = latestPoint else { return false }
        return current.distance(to: route.points[step]) <= 14
    }

    private func advance() {
        guard let route else { return }
        audio.stopCue()
        aligned = false
        if step == route.points.count - 2 {
            arrived = true
            guidanceRequested = false
            status = "Route complete."
            location.stopUpdatingLocation()
            stopHeadphoneMotion()
            stopCamera()
            audioTest?.cancel()
            audioTest = nil
            loop?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
            audio.say(instruction)
        } else {
            step += 1
            requestCue()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard running, mode == .walk, !arrived, let route, let fix = locations.last,
              abs(fix.timestamp.timeIntervalSinceNow) < 8 else { return }
        latestFix = fix
        lastFixReceived = ProcessInfo.processInfo.systemUptime
        let current = Point(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
        latestPoint = current
        guard locationUsable else {
            status = "Location uncertain. Directional confirmation paused."
            return
        }
        guard heading != nil else {
            status = atReference(route) ? "Face along this leg and align your AirPods or camera." : "Move to the start of this leg before aligning."
            return
        }
        let start = route.points[step]
        let end = route.points[step + 1]
        let segmentLength = start.distance(to: end)
        let distanceFromStart = start.distance(to: current)
        let relativeAngle = signedAngle(start.bearing(to: current) - start.bearing(to: end)) * .pi / 180
        let alongTrack = distanceFromStart * cos(relativeAngle)
        let crossTrack = abs(distanceFromStart * sin(relativeAngle))
        if crossTrack > max(16, fix.horizontalAccuracy * 1.6) || alongTrack < -18 {
            status = "Position is away from the route. Return to a known point."
            invalidateHeading()
            cameraReferenceYaw = nil
            return
        }
        if alongTrack > min(segmentLength * 0.55, 15),
           current.distance(to: end) <= min(10, segmentLength * 0.45) { advance() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard mode == .walk, running else { return }
        latestFix = nil
        audio.stopCue()
        status = "Location unavailable. Check location permission and try outdoors."
    }

    func importGPX(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try saveGPX(Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent) }
        catch { routeMessage = error.localizedDescription }
    }

    func downloadGPX(_ input: String) {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil else {
            routeMessage = "Enter an HTTPS link to a GPX file."
            return
        }
        downloadTask?.cancel()
        routeMessage = "Downloading route…"
        downloadTask = Task { @MainActor [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                try self?.saveGPX(data, name: url.deletingPathExtension().lastPathComponent)
            } catch {
                if !Task.isCancelled { self?.routeMessage = error.localizedDescription }
            }
        }
    }

    private func saveGPX(_ data: Data, name: String) throws {
        guard data.count <= 2_000_000 else { throw GPXError.invalid }
        let route = try GPXReader.read(data, name: name.isEmpty ? "Saved route" : name)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(route).write(to: fileURL, options: .atomic)
        if mode == .walk { reset() }
        savedRoute = route
        routeMessage = "Saved for offline use."
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["action"] as? String == "repeat" else { replyHandler(["repeated": false]); return }
        Task { @MainActor [weak self] in
            let running = self?.running == true
            if running { self?.requestCue() }
            replyHandler(["repeated": running])
        }
    }
}
