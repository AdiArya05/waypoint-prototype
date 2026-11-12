import AppIntents
import ARKit
import MapKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct WaypointApp: App {
    var body: some Scene {
        WindowGroup { WalkScreen() }
    }
}

struct WalkScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = WalkModel.shared
    @State private var showingImporter = false
    @State private var downloadLink = ""
    @State private var destinationQuery = ""

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("Route mode", selection: $model.mode) {
                        ForEach(WalkModel.Mode.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    Text(model.mode == .practice
                         ? "Try a simulated walk with turn buttons, AirPods, or your iPhone camera."
                         : "Say “Siri, start a walk with Waypoint” and tell Siri where you want to go.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let route = model.route {
                        if model.mode == .walk {
                            Map(interactionModes: [.pan, .zoom]) {
                                MapPolyline(coordinates: route.points.map(\.coordinate))
                                    .stroke(.blue, lineWidth: 6)
                                if let first = route.points.first, let last = route.points.last {
                                    Marker("Start", systemImage: "location", coordinate: first.coordinate)
                                    Marker("Destination", systemImage: "flag", coordinate: last.coordinate)
                                }
                                if let current = model.latestPoint {
                                    Annotation("Current location", coordinate: current.coordinate) {
                                        Circle().fill(.blue).strokeBorder(.white, lineWidth: 2)
                                            .frame(width: 16, height: 16)
                                    }
                                }
                            }
                            .id(route.name + String(describing: route.points.first) + String(describing: route.points.last))
                            .frame(height: 200)
                            .clipShape(.rect(cornerRadius: 16))
                            .accessibilityHidden(true)
                        } else {
                            RouteSketch(route: route, step: model.step, position: model.latestPoint)
                                .frame(height: 150)
                                .accessibilityHidden(true)
                        }
                        Text("\(route.name) · \(Int(route.length.rounded())) m")
                            .font(.subheadline)
                    }
                    if model.mode == .walk && !model.running { routeControls }
                    if model.running {
                        if !model.arrived {
                            Picker("Guidance audio", selection: $model.audioStyle) {
                                ForEach(WalkModel.AudioStyle.allCases, id: \.self) { Text($0.rawValue) }
                            }
                            .pickerStyle(.segmented)
                            if model.useManualPractice {
                                ViewThatFits {
                                    HStack { practiceTurns }
                                    VStack(alignment: .leading) { practiceTurns }
                                }
                            }
                            if model.mode == .practice {
                                Button("Walk this leg", action: model.walkPracticeLeg)
                                    .disabled(!model.aligned)
                                    .buttonStyle(.borderedProminent)
                            }
                            Button("Repeat direction", action: model.requestCue)
                                .buttonStyle(.bordered)
                            cameraControls
                            motionControls
                            audioControls
                        }
                        Button(model.arrived ? "Reset" : "End session", action: model.reset)
                            .buttonStyle(.bordered)
                    } else {
                        Button(model.mode == .practice ? "Start practice" : "Start walk", action: model.begin)
                            .buttonStyle(.borderedProminent)
                            .disabled(model.route == nil || model.planning)
                    }
                    Text(model.status).font(.callout)
                    if model.running && !model.arrived && model.mode == .walk {
                        Text("Say “Siri, repeat directions with Waypoint” or “Siri, stop my Waypoint walk.”")
                            .font(.subheadline)
                    }
                }
                .frame(maxWidth: 580, alignment: .leading)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.running { directionsBanner }
            }
            .navigationTitle("Waypoint")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.init(filenameExtension: "gpx") ?? .xml]) { result in
                switch result {
                case .success(let url): model.importGPX(from: url)
                case .failure(let error): model.routeMessage = error.localizedDescription
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.didEnterBackground() }
        }
    }

    private var directionsBanner: some View {
        HStack(spacing: 16) {
            Image(systemName: model.maneuverIcon)
                .font(.system(size: 30, weight: .semibold))
                .frame(width: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.instruction)
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                if let distance = model.distanceToTurn {
                    Text("\(Int(distance.rounded())) m to next point")
                        .font(.subheadline.weight(.medium))
                }
                if let next = model.nextManeuver {
                    Text(next).font(.subheadline)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: 580, alignment: .leading)
        .background(Color(red: 0.04, green: 0.29, blue: 0.24), in: .rect(cornerRadius: 18))
        .padding(.horizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.background)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("directionsBanner")
    }

    private var routeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search for a destination", text: $destinationQuery)
                .accessibilityHint("Use keyboard dictation to speak a destination.")
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .onSubmit(search)
            Button("Search from current location", action: search)
                .disabled(model.planning || destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if model.planning { ProgressView() }
            ForEach(Array(model.destinations.enumerated()), id: \.offset) { _, destination in
                Button {
                    Task { await model.planWalk(to: destination) }
                } label: {
                    VStack(alignment: .leading) {
                        Text(destination.name ?? "Destination")
                        if #available(iOS 26, *), let address = destination.address?.fullAddress {
                            Text(address).font(.caption)
                        } else if let subtitle = destination.placemark.title {
                            Text(subtitle).font(.caption)
                        }
                    }
                }
                .disabled(model.planning)
            }
            DisclosureGroup("Use a saved GPX route") {
                Button("Import GPX from Files") { showingImporter = true }
                TextField("HTTPS GPX link", text: $downloadLink)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button("Download for offline use") { model.downloadGPX(downloadLink) }
                    .disabled(downloadLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(model.planning)
            if !model.routeMessage.isEmpty { Text(model.routeMessage).font(.caption) }
        }
        .buttonStyle(.bordered)
    }

    private func search() {
        let query = destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        Task { await model.searchDestinations(query) }
    }

    private var practiceTurns: some View {
        Group {
            Button("Turn left 15°") { model.turnPractice(by: -15) }
            Button("Turn right 15°") { model.turnPractice(by: 15) }
        }
        .buttonStyle(.bordered)
    }

    private var cameraControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let view = model.cameraView {
                CameraPreview(view: view)
                    .frame(height: 260)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottom) {
                        if let turn = model.cameraTurn {
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 46, weight: .bold))
                                    .rotationEffect(.degrees(turn))
                                    .accessibilityHidden(true)
                                Text(cameraDirection(turn))
                                    .font(.headline)
                            }
                                .accessibilityElement(children: .combine)
                                .padding(12)
                                .foregroundStyle(.white)
                                .background(abs(turn) <= 14 ? Color(red: 0.04, green: 0.29, blue: 0.24) : .black.opacity(0.85), in: .rect(cornerRadius: 18))
                                .padding()
                                .accessibilityAddTraits(.updatesFrequently)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 12))
                if model.mode == .practice {
                    Button("Align camera", action: model.alignCamera).disabled(model.cameraYaw == nil)
                }
                if !model.cameraGuidesAudio && model.cameraTurn != nil {
                    Button("Use camera for audio guidance", action: model.useCameraForAudio)
                }
                Button("Turn off camera", action: model.stopCamera)
            } else {
                Button("Open route camera") { Task { await model.startCamera() } }
            }
            if !model.cameraStatus.isEmpty {
                Text(model.cameraStatus)
            }
        }
        .font(.subheadline)
        .buttonStyle(.bordered)
    }

    private func cameraDirection(_ angle: Double) -> String {
        if abs(angle) <= 14 { return "Along route" }
        if abs(angle) > 155 { return "Turn around" }
        return angle < 0 ? "Route to the left" : "Route to the right"
    }

    private var audioControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !model.audioOutput.isEmpty { Text("Audio output: " + model.audioOutput) }
            Button("Test left and right audio", action: model.testAudio)
            if !model.audioTestStatus.isEmpty { Text(model.audioTestStatus) }
        }
        .font(.subheadline)
        .buttonStyle(.bordered)
    }

    private var motionControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(model.motionStatus)
            Button(model.usingHeadphones ? "Reconnect AirPods motion" : "Enable AirPods motion",
                   action: model.enableHeadphones)
            if model.usingHeadphones {
                Text(model.mode == .practice
                     ? "Face forward, then align. Turn your head to follow the cue."
                     : model.cameraView == nil
                     ? "Hold the phone flat. Point its top edge where you’re facing, then tap Align AirPods."
                     : "Hold the rear camera in the direction you’re facing, then tap Align AirPods.")
                if let yaw = model.headphoneYaw {
                    Text("Live head angle: \(Int(yaw.rounded()))°")
                        .monospacedDigit()
                        .accessibilityLabel("Live head angle")
                        .accessibilityValue("\(Int(yaw.rounded())) degrees")
                }
                Button("Align AirPods", action: model.calibrate).disabled(!model.motionAvailable)
            }
            if model.mode == .practice && !model.useManualPractice {
                Button("Use practice buttons", action: model.usePracticeButtons)
            }
        }
        .font(.subheadline)
        .buttonStyle(.bordered)
    }
}

private struct CameraPreview: UIViewRepresentable {
    let view: ARSCNView

    func makeUIView(context: Context) -> ARSCNView {
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct RouteSketch: View {
    let route: WalkRoute
    let step: Int
    let position: Point?

    var body: some View {
        Canvas { context, size in
            let points = route.points
            guard let first = points.first, let last = points.last else { return }
            let latitudeScale = max(0.01, cos(first.latitude * .pi / 180))
            let longitudes = points.map { signedAngle($0.longitude - first.longitude) * latitudeScale }
            let minLon = longitudes.min() ?? 0
            let maxLon = longitudes.max() ?? 0
            let minLat = points.map(\.latitude).min() ?? 0
            let maxLat = points.map(\.latitude).max() ?? 0
            let scale = min((size.width - 32) / max(maxLon - minLon, 0.0000001),
                            (size.height - 32) / max(maxLat - minLat, 0.0000001))
            func plot(_ p: Point) -> CGPoint {
                let x = signedAngle(p.longitude - first.longitude) * latitudeScale
                return CGPoint(x: size.width / 2 + (x - (minLon + maxLon) / 2) * scale,
                               y: size.height / 2 - (p.latitude - (minLat + maxLat) / 2) * scale)
            }
            let path = Path { path in
                path.move(to: plot(first))
                for point in points.dropFirst() { path.addLine(to: plot(point)) }
            }
            context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            context.draw(Text("A").font(.caption.bold()), at: plot(first), anchor: .bottomTrailing)
            context.draw(Text("B").font(.caption.bold()), at: plot(last), anchor: .bottomLeading)
            let active = plot(position ?? points[min(step, points.count - 1)])
            if CGRect(origin: .zero, size: size).contains(active) {
                context.fill(Path(ellipseIn: CGRect(x: active.x - 5, y: active.y - 5, width: 10, height: 10)),
                             with: .color(.orange))
            }
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}


struct StartWaypointWalk: AppIntent {
    static let title: LocalizedStringResource = "Start a Walk"
    static let openAppWhenRun = true

    @Parameter(title: "Destination", requestValueDialog: "Where would you like to walk?")
    var destination: String

    static var parameterSummary: some ParameterSummary {
        Summary("Walk to \(\.$destination)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = WalkModel.shared
        guard !model.running || model.arrived else {
            return .result(dialog: "A walk is already active. Say stop my Waypoint walk to end it first.")
        }
        if model.arrived { model.reset() }
        model.mode = .walk
        let query = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .result(dialog: "Please say a destination.") }
        guard !model.planning else { return .result(dialog: "Waypoint is already looking up a route.") }
        await model.searchDestinations(query)
        guard let match = model.destinations.first else {
            return .result(dialog: "\(model.routeMessage)")
        }
        let name = match.name ?? query
        let address: String?
        if #available(iOS 26, *) {
            address = match.address?.fullAddress
        } else {
            address = match.placemark.title
        }
        let place = [name, address].compactMap { $0 }.joined(separator: ", ")
        try await requestConfirmation(dialog: "Start walking to \(place)?")
        guard await model.planWalk(to: match) else {
            return .result(dialog: "\(model.routeMessage)")
        }
        model.begin()
        return .result(dialog: "Walking to \(name).")
    }
}

struct RepeatWaypointDirections: AppIntent {
    static let title: LocalizedStringResource = "Repeat Directions"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = WalkModel.shared
        guard model.running else { return .result(dialog: "There’s no active Waypoint walk.") }
        return .result(dialog: "\(model.spokenDirection)")
    }
}

struct StopWaypointWalk: AppIntent {
    static let title: LocalizedStringResource = "Stop the Walk"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = WalkModel.shared
        guard model.running else { return .result(dialog: "There’s no active Waypoint walk.") }
        model.reset()
        return .result(dialog: "Waypoint walk ended.")
    }
}

struct WaypointShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartWaypointWalk(),
            phrases: ["Start a walk with \(.applicationName)"],
            shortTitle: "Start a Walk",
            systemImageName: "figure.walk"
        )
        AppShortcut(
            intent: RepeatWaypointDirections(),
            phrases: ["Repeat directions with \(.applicationName)"],
            shortTitle: "Repeat Directions",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: StopWaypointWalk(),
            phrases: ["Stop my \(.applicationName) walk"],
            shortTitle: "Stop Walk",
            systemImageName: "stop.circle"
        )
    }
}
