import AVFoundation
import MapKit
import Speech
import SwiftUI

enum WaypointPage {
    case home, map, airPods
}

struct HomeDashboard: View {
    let model: WalkModel
    let viewportHeight: CGFloat
    let importRoute: () -> Void
    @Binding var page: WaypointPage
    @Binding var showingPlaces: Bool

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("savedPlaces") private var storedPlaces = Data()
    @State private var dictation = DestinationDictation()
    @State private var query = ""
    @FocusState private var destinationFocused: Bool
    @AccessibilityFocusState(for: .voiceOver) private var searchVoiceFocused: Bool
    @State private var link = ""
    @State private var showingSearch = false
    @State private var showingOfflineMaps = false
    @State private var showingExpandedMap = false
    @State private var reviewPlace: SavedPlace?
    @State private var pendingSavedPlace: SavedPlace?
    @State private var routeReady = false
    @State private var routeRequest: Task<Void, Never>?
    @AccessibilityFocusState(for: .voiceOver) private var reviewFocused: Bool
    @State private var showingVoice = false
    @State private var voiceMatches: [MKMapItem] = []
    @State private var voiceIndex = 0
    @State private var voiceMessage = ""
    @State private var voiceBusy = false
    @State private var voiceToken = UUID()
    @State private var speech = AVSpeechSynthesizer()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchAfterPlaces = false
    @State private var openVoiceOnSearch = false
    @State private var focusAfterVoice = false
    @State private var airPodsName: String?
    @State private var mapPosition: MapCameraPosition = .region(Self.previewRegion)
    @ScaledMetric(relativeTo: .body) private var mapHeight = 194.0
    @State private var baseHeight: CGFloat?

    private var extraHeight: CGFloat {
        guard let baseHeight, !dynamicTypeSize.isAccessibilitySize else { return 0 }
        return max(0, floor(viewportHeight - baseHeight))
    }

    private static var previewRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 1.2869, longitude: 103.8532),
            latitudinalMeters: 1100, longitudinalMeters: 1100
        )
    }
    private let ink = Color(white: 0.10)
    private let accent = Color(red: 0.70, green: 0.31, blue: 0.04)
    private let orange = Color(red: 0.98, green: 0.49, blue: 0.12)
    private let green = Color(red: 0.10, green: 0.42, blue: 0.23)

    private var places: [SavedPlace] {
        (try? JSONDecoder().decode([SavedPlace].self, from: storedPlaces)) ?? []
    }

    var body: some View {
        Group {
            switch page {
            case .home: dashboard
            case .map:
                VStack(spacing: 0) {
                    mapPage
                    routeFiles
                }
            case .airPods: airPodsPage
            }
        }
        .id(page)
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: page)
        .frame(maxWidth: 580)
        .frame(maxWidth: .infinity)
        .fullScreenCover(isPresented: $showingOfflineMaps) { offlineMapsSheet }
        .fullScreenCover(isPresented: $showingExpandedMap) {
            NavigationStack {
                mapContent
                    .navigationTitle("Map")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingExpandedMap = false }
                        }
                    }
            }
        }
        .task {
            refreshAudioRoute()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--preview-jurong-camp") {
                addJurongCampPreview()
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            refreshAudioRoute()
        }
        .sheet(isPresented: $showingSearch, onDismiss: closeRouteReview) {
            searchSheet
                .fullScreenCover(isPresented: $showingVoice, onDismiss: {
                    endVoice()
                    if focusAfterVoice {
                        focusAfterVoice = false
                        destinationFocused = true
                    } else if reviewPlace != nil {
                        reviewFocused = true
                    }
                }) { voiceScreen }
                .onAppear {
                    if openVoiceOnSearch {
                        openVoiceOnSearch = false
                        showingVoice = true
                    } else {
                        searchVoiceFocused = true
                    }
                }
        }
        .sheet(isPresented: $showingPlaces, onDismiss: {
            if let place = pendingSavedPlace {
                pendingSavedPlace = nil
                open(place)
            } else if searchAfterPlaces {
                searchAfterPlaces = false
                beginSearch()
            }
        }) { savedPlacesSheet }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { dictation.cancel() }
            if phase == .active { refreshAudioRoute() }
        }
        .onDisappear { dictation.cancel() }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
                .accessibilityElement(children: .contain)
                .accessibilitySortPriority(3)
            map
            savedPlacesSection(limit: 1)

            Text("Walk overview")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)

            airPodsCard
            let gridRow = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 9))
                : AnyLayout(HStackLayout(spacing: 9))
            Group {
                if #available(iOS 26.0, *) {
                    GlassEffectContainer(spacing: 5) { gridRow { destinationTiles } }
                } else {
                    gridRow { destinationTiles }
                }
            }
            .accessibilityElement(children: .contain)
            if model.planning { ProgressView("Finding a walking route") }

            if !model.routeMessage.isEmpty && !showingSearch {
                Text(model.routeMessage).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 580, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 5)
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height - extraHeight
        } action: { height in
            if abs((baseHeight ?? 0) - height) > 1 { baseHeight = height }
        }
        .frame(maxWidth: .infinity)
        .tint(accent)
    }

    private var routeFiles: some View {
        DisclosureGroup("Route files") {
            VStack(alignment: .leading, spacing: 8) {
                Button("Import GPX from Files", action: importRoute)
                    .frame(minHeight: 44)
                TextField("HTTPS GPX link", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                Button("Download route") { model.downloadGPX(link) }
                    .frame(minHeight: 44)
                    .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 6)
        }
        .font(.subheadline.weight(.semibold))
        .tint(accent)
        .padding(14)
        .waypointGlass(in: .rect(cornerRadius: 22))
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "location.north.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 46, height: 46)
                .waypointGlass(in: .rect(cornerRadius: 16))
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Waypoint").font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(airPodsName == nil ? "AirPods audio inactive" : "AirPods connected")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            Button {
                page = .airPods
            } label: {
                Image(systemName: "airpods.gen3")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(airPodsName == nil ? Color.secondary : green)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: airPodsName != nil)
                    .frame(width: 46, height: 46)
                    .waypointGlass(in: .rect(cornerRadius: 15), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("AirPods settings")
        }
    }

    private func savedPlacesSection(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Saved places")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    if page == .home { page = .map } else { showingPlaces = true }
                } label: {
                    Text("View all").font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .accessibilityLabel("View all saved places")
            }
            if places.isEmpty {
                Button {
                    showingPlaces = true
                } label: {
                    savedPlaceLabel(title: "Add a place", subtitle: "", icon: "plus")
                }
                .buttonStyle(.plain)
            }
            ForEach(places.prefix(limit)) { place in
                Button { open(place) } label: {
                    savedPlaceLabel(title: place.name, subtitle: place.address, icon: "bookmark.fill")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Prepares a walking route")
                .disabled(model.planning)
            }
        }
    }

    private func savedPlaceLabel(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 40, height: 40)
                .background(accent.opacity(0.08), in: .rect(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .waypointGlass(in: .rect(cornerRadius: 20), interactive: true)
        .accessibilityElement(children: .combine)
    }

    private var map: some View {
        mapContent(expandable: true)
            .frame(height: min(mapHeight, 260) + extraHeight * 0.42)
            .clipShape(.rect(cornerRadius: 24))
    }

    private var mapContent: some View { mapContent(expandable: false) }

    private func mapContent(expandable: Bool) -> some View {
        Map(position: $mapPosition, interactionModes: [.pan, .zoom]) {
            UserAnnotation()
            ForEach(places) { place in
                Marker(place.name, coordinate: place.point.coordinate)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .accessibilityHidden(true)
        .overlay(alignment: .topTrailing) {
            if expandable {
                Button {
                    showingExpandedMap = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.headline)
                        .frame(width: 48, height: 48)
                        .waypointGlass(in: .circle, interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Expand map")
                .padding(10)
            }
        }
        .overlay(alignment: .bottom) {
            Button {
                model.requestMapLocation()
                mapPosition = .userLocation(fallback: .region(Self.previewRegion))
            } label: {
                Label("My location", systemImage: "location.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .waypointGlass(in: .capsule, interactive: true)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 19)
        }
    }

    private var destinationTiles: some View {
        let routeSummary = model.savedRoute.map { "\($0.name) · \(Int($0.length.rounded())) m" }
        return Group {
            Button {
                if model.savedRoute == nil {
                    beginSearch()
                } else {
                    model.begin()
                }
            } label: {
                tile("Start walk", detail: routeSummary ?? "Choose a route",
                     icon: "figure.walk", accessory: "location.fill")
            }
            .accessibilityLabel("Start walk")
            .accessibilityValue(routeSummary ?? "Choose a route")
            .accessibilityHidden(model.savedRoute == nil)
            Button { beginSearch() } label: {
                tile("Search", detail: "Speak or type", icon: "magnifyingglass", accessory: "mappin.circle.fill")
            }
            .accessibilityLabel("Search for a destination")
            .accessibilityHint("Speak or type a place name or address")
            .accessibilityAction(named: Text("Speak a destination")) {
                openVoiceOnSearch = true
                beginSearch()
            }
        }
        .buttonStyle(.plain)
        .disabled(model.planning)
    }

    private func tile(_ title: String, detail: String, icon: String, accessory: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 5) {
                Text(detail).font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: accessory)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(orange)
                    .accessibilityHidden(true)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 105 + extraHeight * 0.58, alignment: .leading)
        .waypointGlass(in: .rect(cornerRadius: 24), interactive: true)
        .accessibilityElement(children: .combine)
    }

    private var airPodsCard: some View {
        Button {
            refreshAudioRoute()
            page = .airPods
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("AirPods", systemImage: "airpods.gen3")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(airPodsName == nil ? "Disconnected" : "Connected")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color(white: 0.94), in: .capsule)
                }
                HStack(alignment: .bottom) {
                    Text(airPodsName ?? "Head tracking")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    airPodsArtwork
                }
            }
            .padding(15)
            .frame(minHeight: 109)
            .waypointGlass(in: .rect(cornerRadius: 25), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens AirPods setup and audio practice")
    }

    private var airPodsArtwork: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: "airpods.gen3")
                .font(.system(size: 33, weight: .medium))
                .foregroundStyle(airPodsName == nil ? Color(white: 0.60) : green)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: airPodsName != nil)
            Image(systemName: "airpods.gen3.chargingcase.wireless.fill")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Color(white: 0.66))
        }
        .shadow(color: .black.opacity(0.26), radius: 3, x: 0, y: 2)
        .accessibilityHidden(true)
    }

    private var mapPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Map").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            mapContent.frame(height: 300).clipShape(.rect(cornerRadius: 24))
            dashboardAction("Offline maps", icon: "arrow.down.to.line") { showingOfflineMaps = true }
                .accessibilityValue("\(model.offlineMaps.count) downloaded")
            savedPlacesSection(limit: 3)
            dashboardAction("Try offline demo", icon: "figure.walk.circle") { model.beginDemo() }
                .accessibilityHint("Practice following the sound at a fork. Works without AirPods.")
        }
        .padding(16)
        .tint(accent)
    }

    private var airPodsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("AirPods").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 12) {
                airPodsArtwork.frame(maxWidth: .infinity)
                Text(airPodsName.map { "\($0) is the current audio output." }
                     ?? "Connect your AirPods in Bluetooth settings and put them on.")
                Text("Waypoint checks for head tracking when you start a walk.")
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .waypointGlass(in: .rect(cornerRadius: 24))

            dashboardAction("Practice AirPods guidance", icon: "airpods.gen3") {
                page = .home
                model.mode = .practice
                model.begin()
                model.enableHeadphones()
            }
        }
        .padding(16)
        .tint(accent)
    }

    private var searchSheet: some View {
        NavigationStack {
            Group {
                if let place = reviewPlace {
                    routeConfirmation(place)
                } else {
                    destinationSearchForm
                }
            }
            .navigationTitle(reviewPlace == nil ? "Find a destination" : "Confirm destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if reviewPlace != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Search", systemImage: "chevron.backward") {
                            closeRouteReview()
                            model.clearDestinationSearch()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingSearch = false }
                }
            }
        }
    }

    private var destinationSearchForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button {
                    destinationFocused = false
                    showingVoice = true
                } label: {
                    Label("Speak a destination", systemImage: "mic.fill")
                        .font(.title3.bold())
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 72)
                        .contentShape(.rect(cornerRadius: 24))
                        .waypointGlass(in: .rect(cornerRadius: 24), tint: accent.opacity(0.16), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityFocused($searchVoiceFocused)
                .disabled(model.planning)

                VStack(alignment: .leading, spacing: 10) {
                    TextField("Destination", text: $query)
                        .focused($destinationFocused)
                        .submitLabel(.search)
                        .onSubmit(search)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 54)
                        .background(Color(white: 0.97), in: .rect(cornerRadius: 15))
                    Button(action: search) {
                        Label("Search", systemImage: "magnifyingglass")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .waypointGlass(in: .capsule, interactive: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.planning || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(12)
                .waypointGlass(in: .rect(cornerRadius: 24))

                if model.planning {
                    ProgressView("Finding destinations")
                } else if !model.routeMessage.isEmpty && model.destinations.isEmpty {
                    Text(model.routeMessage).foregroundStyle(.secondary)
                }

                if !model.destinations.isEmpty {
                    Text("Destinations").font(.title3.bold())
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Array(model.destinations.enumerated()), id: \.offset) { index, destination in
                        let place = SavedPlace(destination)
                        HStack(spacing: 8) {
                            Button {
                                review(place, destination: destination)
                            } label: {
                                savedPlaceLabel(title: place.name, subtitle: place.address, icon: "mappin")
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("destinationResult-\(index)")
                            .disabled(model.planning)
                            Button {
                                toggleSaved(place)
                                announce(isSaved(place) ? "Saved \(place.name)." : "Removed \(place.name).")
                            } label: {
                                Image(systemName: isSaved(place) ? "bookmark.fill" : "bookmark")
                                    .font(.headline)
                                    .frame(width: 52, height: 52)
                                    .waypointGlass(in: .circle, interactive: true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isSaved(place) ? "Remove \(place.name) from saved places" : "Save \(place.name)")
                        }
                    }
                }
            }
            .frame(maxWidth: 540, alignment: .leading)
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(white: 0.96).ignoresSafeArea())
        .tint(accent)
    }

    private func dashboardAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Image(systemName: "chevron.right").accessibilityHidden(true)
            }
            .font(.headline)
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .waypointGlass(in: .rect(cornerRadius: 18), interactive: true)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func offlineDownloadAction(compact: Bool = false) -> some View {
        if model.currentOfflineMap != nil {
            Label("Available offline", systemImage: "checkmark.circle")
                .font(.headline)
                .frame(minHeight: 44)
        } else if model.downloadingMap {
            ProgressView("Downloading offline map")
                .frame(minHeight: 44)
        } else {
            Button {
                Task {
                    await model.downloadOfflineMap()
                    if !model.offlineMapMessage.isEmpty { announce(model.offlineMapMessage) }
                }
            } label: {
                Label("Download offline map", systemImage: "arrow.down.to.line")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .padding(.horizontal, compact ? 0 : 12)
            }
            .accessibilityHint("Saves the walking route and nearby streets for use without internet.")
        }
        if model.currentOfflineMap == nil && !model.offlineMapMessage.isEmpty {
            Text(model.offlineMapMessage).foregroundStyle(.secondary)
        }
    }

    private var offlineMapsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(model.offlineMaps.isEmpty
                         ? "Download a walking route while you’re online to use it later."
                         : "Start a saved walk near its original starting point.")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    if model.savedRoute != nil && model.currentOfflineMap == nil {
                        offlineDownloadAction()
                    } else if !model.offlineMapMessage.isEmpty && model.currentOfflineMap == nil {
                        Text(model.offlineMapMessage).foregroundStyle(.secondary)
                    }

                    ForEach(model.offlineMaps) { map in
                        offlineMapCard(map)
                    }

                    if model.offlineMaps.isEmpty {
                        Label("No offline maps yet", systemImage: "map")
                            .font(.title3.bold())
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .waypointGlass(in: .rect(cornerRadius: 24))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Offline maps")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingOfflineMaps = false }
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 54, minHeight: 44)
                }
            }
            .background(Color(white: 0.96).ignoresSafeArea())
        }
    }

    private func offlineMapCard(_ map: OfflineWalkingMap) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(map.route.name)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Label("\(Int(map.route.length.rounded())) m walking route", systemImage: "figure.walk")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            OfflineMapPreview(map: map, step: 0, position: nil, height: 260)

            Button {
                guard model.selectOfflineMap(map) else { return }
                showingOfflineMaps = false
                model.begin()
            } label: {
                Label("Start saved walk", systemImage: "figure.walk")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .waypointGlass(in: .capsule, tint: accent.opacity(0.2), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start saved walk to \(map.route.name)")

            Button(role: .destructive) { model.removeOfflineMap(map) } label: {
                Label("Remove download", systemImage: "trash")
                    .font(.body.weight(.medium))
                    .frame(minHeight: 44)
            }
            .accessibilityLabel("Remove download for \(map.route.name)")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .waypointGlass(in: .rect(cornerRadius: 26))
    }

    private func confirmationMap(_ route: WalkRoute, height: CGFloat) -> some View {
        Map(interactionModes: [.pan, .zoom]) {
            MapPolyline(coordinates: route.points.map(\.coordinate))
                .stroke(accent, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            if let start = route.points.first, let finish = route.points.last {
                Marker("Start", systemImage: "location", coordinate: start.coordinate).tint(accent)
                Marker("Destination", systemImage: "flag.fill", coordinate: finish.coordinate).tint(accent)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .frame(height: height)
        .clipShape(.rect(cornerRadius: 24))
        .accessibilityHidden(true)
    }

    private func routeConfirmation(_ place: SavedPlace) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(place.name).font(.title.bold())
                        if !place.address.isEmpty {
                            Text(place.address).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($reviewFocused)

                    if routeReady, let route = model.savedRoute {
                        if let map = model.currentOfflineMap {
                            OfflineMapPreview(map: map, step: 0, position: nil, height: 188)
                        } else {
                            confirmationMap(route, height: 208)
                        }
                        Label("\(Int(route.length.rounded())) m walking route", systemImage: "figure.walk")
                            .font(.headline)
                        offlineDownloadAction(compact: true)
                    } else if model.planning {
                        ProgressView("Finding a walking route")
                    } else if !model.routeMessage.isEmpty {
                        Text(model.routeMessage).foregroundStyle(.secondary)
                        Button("Try again") { review(place, destination: place.mapItem) }
                            .frame(minHeight: 44)
                    }
                }
                .frame(maxWidth: 540, alignment: .leading)
                .padding(18)
                .frame(maxWidth: .infinity)
            }
            if routeReady {
                Button {
                    speech.stopSpeaking(at: .immediate)
                    showingSearch = false
                    model.begin()
                } label: {
                    Label("Start walk", systemImage: "figure.walk")
                        .font(.headline)
                        .frame(maxWidth: 540, minHeight: 60)
                        .waypointGlass(in: .capsule, tint: accent.opacity(0.16), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("startConfirmedWalk")
                .disabled(model.planning)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(white: 0.96).ignoresSafeArea())
        .tint(accent)
        .task(id: place.id) { reviewFocused = true }
    }

    private var savedPlacesSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Saved places")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Button {
                        openVoiceOnSearch = true
                        searchAfterPlaces = true
                        showingPlaces = false
                    } label: {
                        savedPlaceLabel(title: "Speak to add a place", subtitle: "Say a name or address", icon: "mic.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Speak to add a place")
                    Button {
                        searchAfterPlaces = true
                        showingPlaces = false
                    } label: {
                        Label("Add a place by typing", systemImage: "keyboard")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    if places.isEmpty {
                        Text("Places you save will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(places) { place in
                        HStack(spacing: 8) {
                            Button {
                                pendingSavedPlace = place
                                showingPlaces = false
                            } label: {
                                savedPlaceLabel(title: place.name, subtitle: place.address, icon: "bookmark.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("savedDestination-\(place.name)")
                            .accessibilityHint("Prepares a walking route")
                            Menu {
                                Button("Remove from saved places", systemImage: "trash", role: .destructive) {
                                    toggleSaved(place)
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.headline)
                                    .frame(width: 44, height: 48)
                                    .waypointGlass(in: .capsule)
                            }
                            .accessibilityLabel("Options for \(place.name)")
                        }
                    }
                }
                .frame(maxWidth: 580, alignment: .leading)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
            .background(Color(white: 0.96).ignoresSafeArea())
            .tint(accent)
            .navigationTitle("Waypoint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { showingPlaces = false } }
        }
    }

    private func refreshAudioRoute() {
        airPodsName = AVAudioSession.sharedInstance().currentRoute.outputs.first {
            [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType)
                && $0.portName.localizedCaseInsensitiveContains("AirPods")
        }?.portName
    }

    private func beginSearch() {
        model.clearDestinationSearch()
        query = ""
        showingSearch = true
    }

    private var voiceScreen: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 18) {
                    Text("Add a place")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 20)
                    voiceFeedback
                    Spacer(minLength: 20)
                }
                .frame(minHeight: max(0, geometry.size.height - 28))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }
        }
        .safeAreaInset(edge: .bottom) { voiceControls }
        .background { Color(white: 0.97).ignoresSafeArea() }
        .foregroundStyle(.black)
        .preferredColorScheme(.light)
        .task { await listenForPlace() }
        .sensoryFeedback(.selection, trigger: dictation.listening)
        .onChange(of: dictation.message) { _, message in
            guard let message, !dictation.listening, message != "Transcribing…" else { return }
            announce(message)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { endVoice() }
        }
    }

    @ViewBuilder
    private var voiceFeedback: some View {
        if voiceMatches.indices.contains(voiceIndex) {
            let match = voiceMatches[voiceIndex]
            let place = SavedPlace(match)
            VStack(spacing: 10) {
                Text(place.name).font(.title2.bold())
                if !place.address.isEmpty { Text(place.address).foregroundStyle(Color(white: 0.28)) }
                Button {
                    toggleSaved(place)
                    announce("Saved \(place.name).")
                } label: {
                    Label(isSaved(place) ? "Saved" : "Save place", systemImage: "bookmark.fill")
                        .padding(.horizontal, 16)
                        .frame(minHeight: 48)
                        .waypointGlass(in: .capsule, interactive: true)
                }
                .buttonStyle(.plain)
                .disabled(isSaved(place))
                Button {
                    endVoice()
                    showingVoice = false
                    review(place, destination: match)
                } label: {
                    Label("Open walking route", systemImage: "figure.walk")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 54)
                        .waypointGlass(in: .capsule, tint: accent.opacity(0.16), interactive: true)
                }
                .buttonStyle(.plain)
                .disabled(voiceBusy)
                if voiceMatches.count > 1 {
                    Button("Next match") {
                        voiceIndex = (voiceIndex + 1) % voiceMatches.count
                        announceMatch()
                    }
                    .frame(minHeight: 44)
                }
            }
        }
        if !voiceMessage.isEmpty || voiceMatches.isEmpty {
            Text(voiceMessage.isEmpty ? dictation.message ?? "Say a place name or address." : voiceMessage)
                .font(.headline)
                .foregroundStyle(Color(white: 0.22))
        }
    }

    private var voiceControls: some View {
        VStack(spacing: 6) {
            Button("Type instead", systemImage: "keyboard") {
                endVoice()
                focusAfterVoice = true
                showingVoice = false
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 44)

            VStack(alignment: .leading, spacing: 8) {
                if let startedAt = dictation.startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
                        Label(String(format: "%d:%02d", seconds / 60, seconds % 60), systemImage: "circle.fill")
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color(red: 0.94, green: 0.45, blue: 0.36), .white)
                    }
                    .accessibilityHidden(true)
                }

                HStack(spacing: 12) {
                    Button {
                        endVoice()
                        showingVoice = false
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 46, height: 46)
                            .background(.white.opacity(0.15), in: .circle)
                    }
                    .accessibilityLabel("Close voice search")

                    voiceWaveform
                        .frame(height: 40)
                        .accessibilityHidden(true)

                    Button {
                        if dictation.listening {
                            dictation.finish()
                        } else {
                            Task { await listenForPlace() }
                        }
                    } label: {
                        Image(systemName: dictation.listening ? "arrow.up" : "mic.fill")
                            .frame(width: 50, height: 50)
                            .background(Color(red: 0.64, green: 0.26, blue: 0.21), in: .circle)
                    }
                    .accessibilityLabel(dictation.listening ? "Finish listening" : "Start listening")
                    .disabled(voiceBusy || dictation.message == "Transcribing…")
                }
            }
            .buttonStyle(.plain)
            .font(.headline)
            .foregroundStyle(.white)
            .padding(14)
            .background(Color(white: 0.10), in: .rect(cornerRadius: 28))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .background(Color(white: 0.97))
    }

    private var voiceWaveform: some View {
        let levels = dictation.levels
        let showLevels = dictation.listening && !reduceMotion
        return Canvas { context, size in
            let rows = 6
            let columns = DestinationDictation.waveformColumns
            let step = min(size.width / CGFloat(columns), size.height / CGFloat(rows))
            let dot = step * 0.70
            let left = (size.width - step * CGFloat(columns)) / 2
            for column in 0..<columns {
                let level = levels[column]
                let litRows = showLevels ? Int((level * Double(rows)).rounded()) : 0
                for row in 0..<rows {
                    let rect = CGRect(x: left + CGFloat(column) * step,
                                      y: size.height - CGFloat(row + 1) * step,
                                      width: dot, height: dot)
                    let color = row < litRows ? Color(red: 0.63, green: 0.80, blue: 0.60) : .white.opacity(0.10)
                    context.fill(Path(roundedRect: rect, cornerRadius: dot * 0.28), with: .color(color))
                }
            }
        }
    }

    private func listenForPlace() async {
        speech.stopSpeaking(at: .immediate)
        voiceMatches = []
        voiceMessage = ""
        voiceIndex = 0
        query = ""
        await dictation.start(update: { query = $0 }, completion: { lookupSpokenPlace() })
    }

    private func lookupSpokenPlace() {
        let transcript = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }
        let request = UUID()
        voiceToken = request
        voiceBusy = true
        voiceMessage = "Looking for \(transcript)…"
        Task {
            await model.searchDestinations(transcript)
            guard request == voiceToken, showingVoice else { return }
            voiceBusy = false
            voiceMatches = model.destinations
            if voiceMatches.isEmpty {
                voiceMessage = model.routeMessage
                announce(voiceMessage)
            } else {
                voiceMessage = ""
                announceMatch()
            }
        }
    }

    private func announceMatch() {
        guard voiceMatches.indices.contains(voiceIndex) else { return }
        let place = SavedPlace(voiceMatches[voiceIndex])
        let address = place.address.isEmpty ? "" : " \(place.address)."
        let match = voiceMatches.count > 1 ? "Match \(voiceIndex + 1) of \(voiceMatches.count). " : ""
        announce("\(match)Found \(place.name).\(address) You can save this place or open the walking route.")
    }

    private func announce(_ text: String) {
        if UIAccessibility.isVoiceOverRunning {
            AccessibilityNotification.Announcement(text).post()
        } else {
            speech.stopSpeaking(at: .immediate)
            speech.speak(AVSpeechUtterance(string: text))
        }
    }

    private func endVoice() {
        voiceToken = UUID()
        dictation.cancel()
        speech.stopSpeaking(at: .immediate)
        voiceMatches = []
        voiceBusy = false
    }

    private func search() {
        destinationFocused = false
        dictation.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task { await model.searchDestinations(text) }
    }

    private func open(_ place: SavedPlace) {
        beginSearch()
        review(place, destination: place.mapItem)
    }

    private func review(_ place: SavedPlace, destination: MKMapItem) {
        destinationFocused = false
        dictation.cancel()
        speech.stopSpeaking(at: .immediate)
        routeRequest?.cancel()
        reviewPlace = place
        routeReady = false
        routeRequest = Task {
            let planned = await model.planWalk(to: destination)
            guard !Task.isCancelled else { return }
            routeReady = planned
            if planned {
                announce("Walking route ready. Start walk is available.")
            } else if !model.routeMessage.isEmpty {
                announce(model.routeMessage)
            }
        }
    }

    private func closeRouteReview() {
        routeRequest?.cancel()
        routeRequest = nil
        reviewPlace = nil
        routeReady = false
    }

    #if DEBUG
    private func addJurongCampPreview() {
        let point = Point(latitude: 1.3320701, longitude: 103.6880563)
        let place = SavedPlace(name: "Jurong Camp 1", address: "Jurong Camp I, Singapore", point: point)
        if !places.contains(where: { $0.point.distance(to: point) < 25 }) {
            toggleSaved(place)
        }
        mapPosition = .region(MKCoordinateRegion(
            center: point.coordinate, latitudinalMeters: 1100, longitudinalMeters: 1100
        ))
    }
    #endif

    private func isSaved(_ place: SavedPlace) -> Bool {
        places.contains { $0.id == place.id }
    }

    private func toggleSaved(_ place: SavedPlace) {
        let updated = isSaved(place) ? places.filter { $0.id != place.id } : places + [place]
        if let data = try? JSONEncoder().encode(updated) { storedPlaces = data }
    }
}

private struct SavedPlace: Codable, Identifiable {
    let name: String
    let address: String
    let point: Point
    var id: String { "\(name)|\(point.latitude)|\(point.longitude)" }

    init(name: String, address: String, point: Point) {
        self.name = name
        self.address = address
        self.point = point
    }

    init(_ item: MKMapItem) {
        name = item.name ?? "Destination"
        if #available(iOS 26, *) {
            address = item.address?.fullAddress ?? ""
            point = Point(latitude: item.location.coordinate.latitude, longitude: item.location.coordinate.longitude)
        } else {
            address = item.placemark.title ?? ""
            point = Point(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude)
        }
    }

    var mapItem: MKMapItem {
        let item: MKMapItem
        if #available(iOS 26, *) {
            item = MKMapItem(location: point.location, address: nil)
        } else {
            item = MKMapItem(placemark: MKPlacemark(coordinate: point.coordinate))
        }
        item.name = name
        return item
    }
}

@MainActor
@Observable
private final class DestinationDictation {
    static let waveformColumns = 38
    private(set) var levels = Array(repeating: 0.0, count: waveformColumns)
    private(set) var startedAt: Date?
    private var lastMeterUpdate = 0.0
    private(set) var listening = false
    private(set) var message: String?
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var finishTask: Task<Void, Never>?
    private var token = UUID()
    private var hasTap = false
    private var hasSession = false
    private var lastText = ""
    private var complete: (() -> Void)?

    func start(update: @escaping (String) -> Void, completion: @escaping () -> Void) async {
        cancel()
        let attempt = token
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard token == attempt else { return }
        guard authorization == .authorized else {
            message = "Allow Speech Recognition in Settings, or search by typing."
            return
        }
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard token == attempt else { return }
        guard allowed else {
            message = "Allow Microphone access in Settings to dictate a destination."
            return
        }
        let speech = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-SG"))
        guard let speech, speech.isAvailable else {
            message = "Dictation is unavailable. You can still type a destination or use Siri."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            hasSession = true
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                cancel()
                message = "No microphone is available."
                return
            }
            let bufferRequest = SFSpeechAudioBufferRecognitionRequest()
            bufferRequest.shouldReportPartialResults = true
            recognizer = speech
            request = bufferRequest
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                bufferRequest.append(buffer)
                guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
                var energy: Float = 0
                for index in 0..<Int(buffer.frameLength) {
                    let sample = samples[index]
                    energy += sample * sample
                }
                let rms = Double((energy / Float(buffer.frameLength)).squareRoot())
                let level = min(1, max(0, (20 * log10(max(rms, 0.000_01)) + 55) / 40))
                Task { @MainActor [weak self] in
                    guard let self, self.token == attempt, self.listening else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    guard now - self.lastMeterUpdate >= 0.045 else { return }
                    self.lastMeterUpdate = now
                    self.levels.removeFirst()
                    self.levels.append(level)
                }
            }
            hasTap = true
            try engine.start()
            complete = completion
            startedAt = Date()
            listening = true
            message = "Listening…"
            recognitionTask = speech.recognitionTask(with: bufferRequest) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor in
                    guard let self, self.token == attempt else { return }
                    if let text, !text.isEmpty {
                        self.lastText = text
                        update(text)
                        if final {
                            self.deliverTranscript()
                            return
                        }
                        self.scheduleFinish(after: .seconds(2), attempt: attempt)
                    }
                    if failed {
                        self.deliverTranscript()
                    }
                }
            }
            scheduleFinish(after: .seconds(10), attempt: attempt)
        } catch {
            cancel()
            message = "Couldn’t start dictation. Try again or type a destination."
        }
    }

    private func scheduleFinish(after delay: Duration, attempt: UUID) {
        finishTask?.cancel()
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.token == attempt else { return }
            self.finish()
        }
    }

    func finish() {
        guard listening else { return }
        stopInput()
        startedAt = nil
        listening = false
        message = "Transcribing…"
        let attempt = token
        finishTask?.cancel()
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.token == attempt else { return }
            self.deliverTranscript()
        }
    }

    private func deliverTranscript() {
        let callback = complete
        let heard = !lastText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        cancel()
        if heard {
            callback?()
        } else {
            message = "Couldn’t hear a destination. Try again or type it."
        }
    }

    func cancel() {
        token = UUID()
        startedAt = nil
        lastMeterUpdate = 0
        levels = Array(repeating: 0, count: Self.waveformColumns)
        finishTask?.cancel()
        finishTask = nil
        stopInput()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        recognizer = nil
        if hasSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            hasSession = false
        }
        listening = false
        lastText = ""
        complete = nil
        message = nil
    }

    private func stopInput() {
        if hasTap {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
            request?.endAudio()
        }
    }
}


extension View {
    @ViewBuilder
    func waypointGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else if let tint {
            background(tint, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}
