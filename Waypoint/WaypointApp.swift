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
    @State private var model = WalkModel()
    @State private var showingImporter = false
    @State private var downloadLink = ""

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
                         ? "Try a simulated walk with turn buttons or real AirPods motion."
                         : "Follow a saved GPX route with live location. Test on a supervised pedestrian path.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let route = model.route {
                        RouteSketch(route: route, step: model.step, position: model.latestPoint)
                            .frame(height: 150)
                            .accessibilityHidden(true)
                        Text("\(route.name) · \(Int(route.length.rounded())) m")
                            .font(.subheadline)
                    }
                    if model.mode == .walk && !model.running { routeControls }
                    if model.running {
                        if !model.arrived {
                            Text("Leg \(model.step + 1) of \((model.route?.points.count ?? 1) - 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(model.instruction).font(.title2.bold())
                        if !model.arrived {
                            Picker("Guidance audio", selection: $model.audioStyle) {
                                ForEach(WalkModel.AudioStyle.allCases, id: \.self) { Text($0.rawValue) }
                            }
                            .pickerStyle(.segmented)
                            if model.mode == .practice && !model.usingHeadphones {
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
                            motionControls
                        }
                        Button(model.arrived ? "Reset" : "End session", action: model.reset)
                            .buttonStyle(.bordered)
                    } else {
                        Button(model.mode == .practice ? "Start practice" : "Start walk", action: model.begin)
                            .buttonStyle(.borderedProminent)
                            .disabled(model.route == nil)
                    }
                    Text(model.status).font(.callout)
                }
                .frame(maxWidth: 580, alignment: .leading)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Waypoint")
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.init(filenameExtension: "gpx") ?? .xml]) { result in
                switch result {
                case .success(let url): model.importGPX(from: url)
                case .failure(let error): model.routeMessage = error.localizedDescription
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.suspend() }
        }
    }

    private var routeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Import GPX from Files") { showingImporter = true }
            TextField("HTTPS GPX link", text: $downloadLink)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            Button("Download for offline use") { model.downloadGPX(downloadLink) }
                .disabled(downloadLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if !model.routeMessage.isEmpty { Text(model.routeMessage).font(.caption) }
        }
        .buttonStyle(.bordered)
    }

    private var practiceTurns: some View {
        Group {
            Button("Turn left 15°") { model.turnPractice(by: -15) }
            Button("Turn right 15°") { model.turnPractice(by: 15) }
        }
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
                     : "At the start of this leg, face along the path and align.")
                Button("Align AirPods", action: model.calibrate).disabled(!model.motionAvailable)
                if model.mode == .practice {
                    Button("Use practice buttons", action: model.usePracticeButtons)
                }
            }
        }
        .font(.subheadline)
        .buttonStyle(.bordered)
    }
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
