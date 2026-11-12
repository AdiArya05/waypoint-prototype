import AppIntents
import ARKit
import MapKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct WaypointApp: App {
    var body: some Scene {
        WindowGroup { WalkScreen().preferredColorScheme(.light) }
    }
}

struct WalkScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var dockSelection
    @State private var model = WalkModel.shared
    @State private var showingImporter = false
    @State private var page: WaypointPage = .home
    @State private var showingSavedPlaces = false
    @State private var walkMapPosition: MapCameraPosition = .automatic
    @State private var showingEndConfirmation = false
    private let walkAccent = Color(red: 0.70, green: 0.31, blue: 0.04)

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollViewReader { proxy in
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        ScrollView {
                            if model.mode == .walk && !model.running {
                                HomeDashboard(
                                    model: model,
                                    viewportHeight: max(0, geometry.size.height - homeDockHeight - 16),
                                    importRoute: { showingImporter = true },
                                    page: $page,
                                    showingPlaces: $showingSavedPlaces
                                )
                                .padding(.bottom, 8)
                                .id("home")
                            } else if model.demoActive, let route = model.route {
                                offlineDemo(route)
                            } else if model.mode == .walk, let route = model.route {
                                activeWalk(route)
                            } else {
                                VStack(alignment: .leading, spacing: 20) {
                                    Picker("Route mode", selection: $model.mode) {
                                        ForEach(WalkModel.Mode.allCases, id: \.self) { Text($0.rawValue) }
                                    }
                                    .pickerStyle(.segmented)
                                    Text("Try a simulated walk with turn buttons, AirPods, or your iPhone camera.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    if let route = model.route {
                                        RouteSketch(route: route, step: model.step, position: model.latestPoint)
                                            .frame(height: 150)
                                            .accessibilityHidden(true)
                                        Text("\(route.name) · \(Int(route.length.rounded())) m")
                                            .font(.subheadline)
                                    }
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
                        }
                        .onChange(of: page) { _, _ in proxy.scrollTo("home", anchor: .top) }
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            if model.mode == .walk && model.running {
                                walkActions
                            }
                        }
                        if model.mode == .walk && !model.running {
                            homeDock { withAnimation { proxy.scrollTo("home", anchor: .top) } }
                                .padding(.vertical, 8)
                        }
                    }
                    .background {
                        if model.mode == .walk && !model.running {
                            LinearGradient(colors: [Color(white: 0.97), Color(red: 0.94, green: 0.95, blue: 0.96), Color(white: 0.98)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                                .ignoresSafeArea()
                        } else {
                            Color(white: 0.96).ignoresSafeArea()
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.running {
                    if model.mode == .walk, let route = model.route {
                        walkHeader(route)
                    } else if !model.demoActive {
                        directionsBanner
                    }
                }
            }
            .toolbar(model.mode == .walk && !model.running ? .hidden : .visible, for: .navigationBar)
            .navigationTitle(model.mode == .walk && model.running ? "Walking route" : "Waypoint")
            .navigationBarTitleDisplayMode(.inline)
            .alert("End this walk?", isPresented: $showingEndConfirmation) {
                Button("Keep walking", role: .cancel) {}
                Button("End walk", role: .destructive, action: model.reset)
            }
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

    private let homeDockHeight: CGFloat = 58

    private func homeDock(onHome: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
            dockButton("Home", icon: "house.fill", destination: .home, onReselect: onHome)
            dockButton("Map", icon: "mappin.circle.fill", destination: .map)
            dockButton("AirPods", icon: "airpods.gen3", destination: .airPods)
        }
        .padding(5)
        .waypointGlass(in: .capsule, interactive: true)
        .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.76), value: page)
        .sensoryFeedback(.selection, trigger: page)
        .frame(maxWidth: .infinity, minHeight: homeDockHeight)
    }

    private func dockButton(_ title: String, icon: String, destination: WaypointPage,
                            onReselect: @escaping () -> Void = {}) -> some View {
        let selected = page == destination
        return Button {
            if selected { onReselect() } else { page = destination }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .scaleEffect(selected ? 1.12 : 1)
                Text(title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(selected ? walkAccent : .primary)
            .frame(minWidth: 74, minHeight: 48)
            .background {
                if selected {
                    Capsule()
                        .fill(walkAccent.opacity(0.12))
                        .matchedGeometryEffect(id: "selectedPage", in: dockSelection)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func walkHeader(_ route: WalkRoute) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Destination", systemImage: "flag.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(walkAccent)
                .accessibilityHidden(true)
            Text(route.name)
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel("Destination, \(route.name)")
            directionsBanner
        }
        .frame(maxWidth: 580, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.96))
    }

    private func activeWalk(_ route: WalkRoute) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            walkMap(route)
            if !model.arrived {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Guidance", systemImage: "speaker.wave.2.fill")
                        .font(.headline)
                    Text(model.status).font(.body)
                    Text(model.motionStatus).font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .waypointGlass(in: .rect(cornerRadius: 22))
                DisclosureGroup("Camera and audio settings") {
                    VStack(alignment: .leading, spacing: 13) {
                        Picker("Guidance audio", selection: Bindable(model).audioStyle) {
                            ForEach(WalkModel.AudioStyle.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        cameraControls
                        motionControls
                        audioControls
                    }
                    .padding(.vertical, 10)
                }
                .padding(14)
                .waypointGlass(in: .rect(cornerRadius: 20))
            }
        }
        .frame(maxWidth: 580, alignment: .leading)
        .padding(16)
        .frame(maxWidth: .infinity)
        .tint(walkAccent)
        .onAppear { walkMapPosition = .automatic }
    }

    private func offlineDemo(_ route: WalkRoute) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Offline practice walk")
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
            RouteSketch(route: route, step: model.arrived ? route.points.count - 1 : model.step,
                        position: nil, streets: [WalkRoute.demoBranch], includeStreetBounds: true)
                .frame(height: 200)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Label(model.instruction, systemImage: model.maneuverIcon)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                if !model.arrived {
                    Text(model.status).font(.body.weight(.medium))
                    if model.demoTrackingLost {
                        Label("Spoken directions on", systemImage: "speaker.wave.2")
                    } else if model.step == 1 && !model.aligned {
                        Text(model.useManualPractice ? "Follow the sound with the turn buttons."
                             : "Turn your head toward the sound.")
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .waypointGlass(in: .rect(cornerRadius: 22))

            if !model.arrived {
                if model.useManualPractice {
                    ViewThatFits {
                        HStack { demoTurnButtons }
                        VStack { demoTurnButtons }
                    }
                }
                demoButton("Walk this leg", icon: "figure.walk", prominent: true, action: model.walkPracticeLeg)
                    .disabled(!model.aligned)
                demoButton("Repeat direction", icon: "speaker.wave.2", action: model.requestCue)
                if model.step == 1 && !model.demoTrackingLost {
                    demoButton("Simulate tracking loss", icon: "airpods", action: model.useDemoSpeechFallback)
                }
                motionControls
            }
            demoButton(model.arrived ? "Back to Home" : "Exit demo", icon: "house", action: model.endDemo)
        }
        .frame(maxWidth: 540, alignment: .leading)
        .padding(16)
        .frame(maxWidth: .infinity)
        .tint(walkAccent)
    }

    private var demoTurnButtons: some View {
        Group {
            demoButton("Turn left 15°", icon: "arrow.turn.up.left") { model.turnPractice(by: -15) }
            demoButton("Turn right 15°", icon: "arrow.turn.up.right") { model.turnPractice(by: 15) }
        }
    }

    private func demoButton(_ title: String, icon: String, prominent: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.headline)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 52)
                .waypointGlass(in: .capsule, tint: prominent ? walkAccent.opacity(0.2) : nil, interactive: true)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func walkMap(_ route: WalkRoute) -> some View {
        if let map = model.currentOfflineMap {
            OfflineMapPreview(map: map, step: model.step, position: model.latestPoint, height: 252)
        } else {
            onlineWalkMap(route)
        }
    }

    private func onlineWalkMap(_ route: WalkRoute) -> some View {
        Map(position: $walkMapPosition, interactionModes: [.pan, .zoom]) {
            MapPolyline(coordinates: route.points.map(\.coordinate))
                .stroke(walkAccent, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            if let first = route.points.first, let last = route.points.last {
                Marker("Start", systemImage: "location", coordinate: first.coordinate)
                    .tint(walkAccent)
                Marker("Destination", systemImage: "flag.fill", coordinate: last.coordinate)
                    .tint(walkAccent)
            }
            if let current = model.latestPoint {
                Annotation("Current location", coordinate: current.coordinate) {
                    Circle().fill(.blue).strokeBorder(.white, lineWidth: 3)
                        .frame(width: 19, height: 19)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .accessibilityHidden(true)
        .frame(height: 252)
        .overlay(alignment: .bottomTrailing) {
            Button {
                walkMapPosition = .automatic
            } label: {
                Label("Show full route", systemImage: "map")
                    .labelStyle(.iconOnly)
                    .font(.headline)
                    .frame(width: 46, height: 46)
                    .waypointGlass(in: .circle, interactive: true)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            .padding(.bottom, 19)
        }
        .clipShape(.rect(cornerRadius: 24))
    }

    private var walkActions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            if !model.arrived {
                Button(action: model.requestCue) {
                    Label("Repeat direction", systemImage: "speaker.wave.2.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .waypointGlass(in: .capsule, interactive: true)
                }
                Button(role: .destructive) {
                    showingEndConfirmation = true
                } label: {
                    Label("End walk", systemImage: "stop.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 48)
                        .waypointGlass(in: .capsule, interactive: true)
                }
            } else {
                Button(action: model.reset) {
                    Label("Back to Home", systemImage: "house.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .waypointGlass(in: .capsule, interactive: true)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: 580)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private var directionsBanner: some View {
        HStack(spacing: 16) {
            Image(systemName: model.guidancePauseMessage == nil ? model.maneuverIcon : "location.slash")
                .font(.system(size: 30, weight: .semibold))
                .frame(width: 48)
                .foregroundStyle(model.mode == .practice ? .white : walkAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.guidancePauseMessage ?? model.instruction)
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                if model.guidancePauseMessage == nil, let distance = model.distanceToTurn {
                    Text("\(Int(distance.rounded())) m to next point")
                        .font(.subheadline.weight(.medium))
                }
                if model.guidancePauseMessage == nil, let next = model.nextManeuver {
                    Text(next).font(.subheadline)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(model.mode == .practice ? .white : .primary)
        .padding(16)
        .frame(maxWidth: 580, alignment: .leading)
        .background(model.mode == .practice ? Color(red: 0.04, green: 0.29, blue: 0.24) : .clear,
                    in: .rect(cornerRadius: 22))
        .waypointGlass(in: .rect(cornerRadius: 22), tint: model.mode == .practice ? .clear : walkAccent.opacity(0.15))
        .padding(.horizontal, model.mode == .practice ? 16 : 0)
        .padding(.vertical, model.mode == .practice ? 6 : 0)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("directionsBanner")
        .accessibilityAction(named: Text("Repeat direction"), model.requestCue)
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
                        .accessibilityHidden(true)
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
    var streets: [[Point]] = []
    var includeStreetBounds = false
    var geographicPadding = 0.0

    var body: some View {
        Canvas { context, size in
            let points = route.points
            guard let first = points.first, let last = points.last else { return }
            let latitudeScale = max(0.01, cos(first.latitude * .pi / 180))
            let viewportPoints = includeStreetBounds ? points + streets.flatMap { $0 } : points
            let longitudes = viewportPoints.map { signedAngle($0.longitude - first.longitude) * latitudeScale }
            let minLon = longitudes.min() ?? 0
            let maxLon = longitudes.max() ?? 0
            let minLat = viewportPoints.map(\.latitude).min() ?? 0
            let maxLat = viewportPoints.map(\.latitude).max() ?? 0
            let scale = min((size.width - 32) / max(maxLon - minLon + 2 * geographicPadding, 0.0000001),
                            (size.height - 32) / max(maxLat - minLat + 2 * geographicPadding, 0.0000001))
            func plot(_ p: Point) -> CGPoint {
                let x = signedAngle(p.longitude - first.longitude) * latitudeScale
                return CGPoint(x: size.width / 2 + (x - (minLon + maxLon) / 2) * scale,
                               y: size.height / 2 - (p.latitude - (minLat + maxLat) / 2) * scale)
            }
            let streetPath = Path { path in
                for street in streets {
                    guard let first = street.first else { continue }
                    path.move(to: plot(first))
                    for point in street.dropFirst() { path.addLine(to: plot(point)) }
                }
            }
            context.stroke(streetPath, with: .color(.gray.opacity(0.65)),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
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
        .background(Color(red: 0.93, green: 0.95, blue: 0.91))
        .clipShape(.rect(cornerRadius: 18))
    }
}


struct OfflineMapPreview: View {
    let map: OfflineWalkingMap
    let step: Int
    let position: Point?
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            RouteSketch(route: map.route, step: step, position: position, streets: map.streets, geographicPadding: 0.00065)
                .frame(height: height)
                .accessibilityHidden(true)
            Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                .font(.caption)
                .frame(minHeight: 44)
        }
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
