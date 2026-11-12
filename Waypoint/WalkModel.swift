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
    private var motionTimestamp = -1.0
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
        location.stopUpdatingLocation()
        motion.stopDeviceMotionUpdates()
        audio.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        running = false
        arrived = false
        aligned = false
        step = 0
        latestPoint = nil
        latestFix = nil
        lastFixReceived = 0
        motionTimestamp = -1
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
        guard motion.isDeviceMotionAvailable else {
            motionStatus = "Headphone motion unavailable. Pair and wear compatible AirPods, then try again."
            return
        }
        if usingHeadphones { motion.stopDeviceMotionUpdates() }
        motionStatus = "Waiting for AirPods motion. Allow Motion & Fitness if prompted."
        usingHeadphones = true
        motionAvailable = false
        motionTimestamp = -1
        lastMotionReceived = 0
        lastSensor = nil
        invalidateHeading()
        motion.startDeviceMotionUpdates()
    }

    func usePracticeButtons() {
        guard mode == .practice else { return }
        motion.stopDeviceMotionUpdates()
        usingHeadphones = false
        motionAvailable = false
        referenceYaw = nil
        heading = practiceHeading
        motionStatus = "Practice buttons active."
        requestCue()
    }

    func calibrate() {
        guard running, !arrived, let route, let sample = motion.deviceMotion,
              motionAvailable, sample.timestamp == motionTimestamp else {
            motionStatus = "Wait for live AirPods motion before aligning."
            return
        }
        if mode == .walk && (!atReference(route)) {
            status = "Return to the start of this leg before aligning."
            return
        }
        referenceYaw = sample.attitude.yaw
        referenceBearing = mode == .practice ? practiceHeading : route.heading(from: step)
        heading = referenceBearing
        motionStatus = "AirPods calibrated. Head turns update the cue."
        status = "Heading aligned."
        requestCue()
    }

    func turnPractice(by degrees: Double) {
        guard mode == .practice, running, !arrived, !usingHeadphones else { return }
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
            audio.say(mode == .walk ? "Heading unavailable. " + instruction : "Align your AirPods or use the practice buttons.")
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
        if usingHeadphones {
            if let sample = motion.deviceMotion, sample.timestamp != motionTimestamp {
                if let lastSensor, lastSensor != sample.sensorLocation { invalidateHeading() }
                if lastMotionReceived > 0, now - lastMotionReceived > 1 { invalidateHeading() }
                lastSensor = sample.sensorLocation
                motionTimestamp = sample.timestamp
                lastMotionReceived = now
                motionAvailable = true
                if let referenceYaw {
                    heading = signedAngle(referenceBearing - (sample.attitude.yaw - referenceYaw) * 180 / .pi)
                } else {
                    motionStatus = "Motion received. Face the reference direction and tap Align."
                }
            } else if now - lastMotionReceived > 1 {
                if motionAvailable { invalidateHeading() }
                motionAvailable = false
                switch CMHeadphoneMotionManager.authorizationStatus() {
                case .denied, .restricted: motionStatus = "Motion permission is off. Check Settings."
                default: motionStatus = "No live motion samples. Check that AirPods are connected and worn."
                }
            }
        }
        evaluateCue(at: now)
    }

    private func invalidateHeading() {
        referenceYaw = nil
        heading = nil
        aligned = false
        alignmentStart = nil
        audio.stopCue()
    }

    private func evaluateCue(at now: Double) {
        guard running, guidanceRequested, !arrived, let error = degreesToTurn,
              mode == .practice || locationUsable else {
            audio.stopCue()
            alignmentStart = nil
            if mode == .walk && running && !arrived && latestFix != nil && !locationUsable {
                status = "Location uncertain. Directional confirmation paused."
            }
            return
        }
        let magnitude = abs(error)
        if magnitude <= 14 {
            audio.stopCue()
            if alignmentStart == nil { alignmentStart = now }
            if now - (alignmentStart ?? now) >= 0.35 {
                aligned = true
                guidanceRequested = false
                status = "Facing the path."
                audio.say("You’re facing the path.")
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
                        status = "Spatial playback unavailable. Select Speech only."
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
            motion.stopDeviceMotionUpdates()
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
            status = atReference(route) ? "Face along this leg and tap Align." : "Move to the start of this leg before aligning."
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
