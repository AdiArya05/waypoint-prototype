import Foundation
import CoreLocation

struct Point: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var location: CLLocation { .init(latitude: latitude, longitude: longitude) }
    func distance(to other: Point) -> Double { location.distance(from: other.location) }

    func bearing(to other: Point) -> Double {
        let a = latitude * .pi / 180
        let b = other.latitude * .pi / 180
        let d = (other.longitude - longitude) * .pi / 180
        return atan2(sin(d) * cos(b), cos(a) * sin(b) - sin(a) * cos(b) * cos(d)) * 180 / .pi
    }
}

func signedAngle(_ degrees: Double) -> Double {
    let wrapped = degrees.truncatingRemainder(dividingBy: 360)
    if wrapped > 180 { return wrapped - 360 }
    if wrapped <= -180 { return wrapped + 360 }
    return wrapped
}

struct WalkRoute: Codable {
    static let forkDemo = WalkRoute(name: "Park loop", points: practice.points)
    static let demoBranch = [practice.points[1], Point(latitude: 0.00064, longitude: -0.00032)]

    var name: String
    let points: [Point]

    static let practice = WalkRoute(name: "Practice path", points: [
        .init(latitude: 0, longitude: 0),
        .init(latitude: 0.0004, longitude: 0),
        .init(latitude: 0.00064, longitude: 0.00032),
        .init(latitude: 0.0010, longitude: 0.00032)
    ])

    var length: Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    static func walking(name: String, points: [Point]) throws -> WalkRoute {
        let distinct = points.reduce(into: [Point]()) { result, point in
            if result.last.map({ $0.distance(to: point) >= 1 }) ?? true { result.append(point) }
        }
        guard distinct.count >= 2 else { throw GPXError.invalid }

        // Keep meaningful changes in path geometry while removing densely spaced map vertices.
        var retained: Set<Int> = [0, distinct.count - 1]
        var ranges = [(0, distinct.count - 1)]
        let route = WalkRoute(name: name, points: distinct)
        while let (first, last) = ranges.popLast() {
            guard last - first > 1 else { continue }
            var greatestDistance = 3.0
            var split: Int?
            for index in (first + 1)..<last {
                let distance = route.projection(of: distinct[index], from: first, to: last).distance
                if distance > greatestDistance {
                    greatestDistance = distance
                    split = index
                }
            }
            if let split {
                retained.insert(split)
                ranges.append((first, split))
                ranges.append((split, last))
            }
        }
        return WalkRoute(name: name, points: retained.sorted().map { distinct[$0] })
    }

    func projection(of point: Point, from step: Int, to endIndex: Int? = nil)
        -> (distance: Double, fraction: Double, length: Double) {
        let start = points[step]
        let end = points[endIndex ?? step + 1]
        let length = start.distance(to: end)
        guard length > 0 else { return (start.distance(to: point), 0, 0) }
        let angle = signedAngle(start.bearing(to: point) - start.bearing(to: end)) * .pi / 180
        let radialDistance = start.distance(to: point)
        let along = radialDistance * cos(angle)
        let across = radialDistance * sin(angle)
        let clamped = min(length, max(0, along))
        return (hypot(across, along - clamped), along / length, length)
    }

    func heading(from step: Int) -> Double {
        points[step].bearing(to: points[step + 1])
    }

    func instruction(from step: Int) -> String {
        guard step > 0 else { return "Follow the first path." }
        let turn = signedAngle(heading(from: step) - heading(from: step - 1))
        if abs(turn) > 150 { return "Turn around and follow the next path." }
        if abs(turn) < 15 { return "Continue straight." }
        return turn < 0 ? "Take the path to your left." : "Take the path to your right."
    }
}

enum GPXError: LocalizedError {
    case invalid
    var errorDescription: String? { "Choose a GPX file containing one continuous route or track with at least two distinct points." }
}

final class GPXReader: NSObject, XMLParserDelegate {
    private var tracks: [[Point]] = []
    private var routes: [[Point]] = []
    private var trackIndex: Int?
    private var routeIndex: Int?

    static func read(_ data: Data, name: String) throws -> WalkRoute {
        let reader = GPXReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse() else { throw GPXError.invalid }
        let candidates = reader.routes.filter { !$0.isEmpty }
        let segments = candidates.isEmpty ? reader.tracks.filter { !$0.isEmpty } : candidates
        guard segments.count == 1, let raw = segments.first else { throw GPXError.invalid }
        let points = raw.reduce(into: [Point]()) { result, point in
            if result.last.map({ $0.distance(to: point) >= 2 }) ?? true { result.append(point) }
        }
        guard points.count >= 2, points.count <= 10_000 else { throw GPXError.invalid }
        return WalkRoute(name: name, points: points)
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        let tag = element.split(separator: ":").last
        if tag == "trkseg" { tracks.append([]); trackIndex = tracks.count - 1 }
        if tag == "rte" { routes.append([]); routeIndex = routes.count - 1 }
        guard tag == "trkpt" || tag == "rtept",
              let lat = attributes["lat"].flatMap(Double.init),
              let lon = attributes["lon"].flatMap(Double.init),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return }
        let point = Point(latitude: lat, longitude: lon)
        if tag == "trkpt", let trackIndex { tracks[trackIndex].append(point) }
        if tag == "rtept", let routeIndex { routes[routeIndex].append(point) }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let tag = element.split(separator: ":").last
        if tag == "trkseg" { trackIndex = nil }
        if tag == "rte" { routeIndex = nil }
    }
}

struct OfflineWalkingMap: Codable, Identifiable {
    let id: UUID
    let route: WalkRoute
    let streets: [[Point]]

    func matches(_ other: WalkRoute) -> Bool {
        route.name == other.name && route.points == other.points
    }

    private struct Response: Decodable {
        struct Way: Decodable {
            struct Node: Decodable { let lat: Double; let lon: Double }
            let geometry: [Node?]
        }
        let elements: [Way]
        let remark: String?
    }

    static func download(for route: WalkRoute) async throws -> Self {
        guard let first = route.points.first,
              let south = route.points.map(\.latitude).min(),
              let north = route.points.map(\.latitude).max(),
              let west = route.points.map(\.longitude).min(),
              let east = route.points.map(\.longitude).max()
        else { throw DownloadError.area }
        let latitudePadding = 0.001
        let longitudePadding = latitudePadding / max(0.1, cos(first.latitude * .pi / 180))
        guard north - south <= 0.05, east - west <= 0.05,
              abs(first.latitude) < 85, west - longitudePadding >= -180, east + longitudePadding <= 180
        else { throw DownloadError.area }
        let bounds = [south - latitudePadding, west - longitudePadding,
                      north + latitudePadding, east + longitudePadding].map { String($0) }.joined(separator: ",")
        let endpoint = URL(string: "https://overpass.openstreetmap.fr/api/interpreter")!
        let query = """
            [out:json][timeout:20][maxsize:16777216];
            way[highway](\(bounds));out geom(\(bounds));
            """
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "data", value: query)]
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.percentEncodedQuery.map { Data($0.utf8) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8_000_000
        else { throw DownloadError.unavailable }
        let map = try JSONDecoder().decode(Response.self, from: data)
        guard map.remark == nil else { throw DownloadError.unavailable }
        let streets = map.elements.flatMap { way -> [[Point]] in
            var lines: [[Point]] = []
            var line: [Point] = []
            for node in way.geometry {
                if let node {
                    line.append(Point(latitude: node.lat, longitude: node.lon))
                } else {
                    if line.count >= 2 { lines.append(line) }
                    line.removeAll(keepingCapacity: true)
                }
            }
            if line.count >= 2 { lines.append(line) }
            return lines
        }
        guard !streets.isEmpty else { throw DownloadError.unavailable }
        return Self(id: UUID(), route: route, streets: streets)
    }

    enum DownloadError: LocalizedError {
        case area, unavailable
        var errorDescription: String? {
            switch self {
            case .area: "This route covers too large an area. Try a shorter walking route."
            case .unavailable: "The map provider couldn’t complete the download. Try again online."
            }
        }
    }
}
