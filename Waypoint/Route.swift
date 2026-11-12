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
