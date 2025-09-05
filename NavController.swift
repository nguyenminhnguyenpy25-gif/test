import Foundation
import SwiftUI
import MapKit
import CoreLocation

final class LocationManager: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
    var lastLocation: CLLocation?
    var onLocation: ((CLLocation) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 1.0
    }

    func requestPermissions() {
        manager.requestWhenInUseAuthorization()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.manager.requestAlwaysAuthorization()
        }
    }

    func start() {
        guard CLLocationManager.locationServicesEnabled() else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        print("Location auth changed: \(s)")
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        lastLocation = loc
        onLocation?(loc)
    }
}

final class RouteManager {
    func requestRoute(from origin: CLLocationCoordinate2D, to dest: CLLocationCoordinate2D, completion: @escaping (MKRoute?) -> Void) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: dest))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false

        let directions = MKDirections(request: request)
        directions.calculate { response, error in
            if let r = response?.routes.first {
                completion(r)
            } else {
                print("Route error: \(String(describing: error))")
                completion(nil)
            }
        }
    }
}

final class StepTracker {
    private(set) var route: MKRoute?
    private(set) var currentStepIndex = 0
    var onStepChanged: ((Int, MKRoute.Step) -> Void)?

    var advanceThresholdMeters: Double = 20.0
    var rerouteThresholdMeters: Double = 50.0

    func setRoute(_ r: MKRoute) {
        route = r
        currentStepIndex = 0
        if let s = currentStep() {
            onStepChanged?(currentStepIndex, s)
        }
    }

    func clear() {
        route = nil
        currentStepIndex = 0
    }

    func currentStep() -> MKRoute.Step? {
        guard let r = route, currentStepIndex < r.steps.count else { return nil }
        return r.steps[currentStepIndex]
    }

    func updateLocation(_ loc: CLLocation) {
        guard let step = currentStep() else { return }

        let endCoord = lastCoordinate(of: step.polyline) ?? step.polyline.coordinate
        let endLoc = CLLocation(latitude: endCoord.latitude, longitude: endCoord.longitude)
        let distToEnd = loc.distance(from: endLoc)

        if distToEnd <= advanceThresholdMeters {
            currentStepIndex += 1
            if let newStep = currentStep() {
                onStepChanged?(currentStepIndex, newStep)
            } else {
                print("Route finished")
            }
            return
        }

        if let r = route {
            let dToRoute = distanceFromLocationToPolyline(loc, polyline: r.polyline)
            if dToRoute > rerouteThresholdMeters {
                print("Possibly off-route (distance to route: \(Int(dToRoute)) m)")
                // You could trigger a re-route here (NavController handles re-request)
            }
        }
    }

    private func lastCoordinate(of polyline: MKPolyline) -> CLLocationCoordinate2D? {
        let count = polyline.pointCount
        guard count > 0 else { return nil }
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return coords.last
    }

    private func distanceFromLocationToPolyline(_ loc: CLLocation, polyline: MKPolyline) -> Double {
        let count = polyline.pointCount
        guard count > 0 else { return Double.greatestFiniteMagnitude }
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        var minDist = Double.greatestFiniteMagnitude
        for i in 0..<count {
            let c = coords[i]
            let p = CLLocation(latitude: c.latitude, longitude: c.longitude)
            let d = p.distance(from: loc)
            if d < minDist { minDist = d }
        }
        return minDist
    }
}

final class ESPWebSocketManager {
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private(set) var isConnected = false
    private var address: String = ""   

    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?

    func connect(to address: String) {
        disconnect() 
        self.address = address
        guard let url = URL(string: "ws://\(address)") else {
            print("Invalid WS URL")
            return
        }
        let cfg = URLSessionConfiguration.default
        session = URLSession(configuration: cfg)
        task = session!.webSocketTask(with: url)
        task!.resume()
        isConnected = true
        receiveLoop()
        DispatchQueue.main.async { self.onConnected?() }
        print("WS connecting to \(url)")
    }

    func disconnect() {
        if let t = task {
            t.cancel(with: .goingAway, reason: nil)
            task = nil
        }
        session = nil
        if isConnected {
            isConnected = false
            DispatchQueue.main.async { self.onDisconnected?() }
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            switch result {
            case .failure(let err):
                print("WS receive error: \(err)")
                self?.handleDisconnect()
            case .success(let msg):
                switch msg {
                case .string(let s): print("WS recv string: \(s)")
                case .data(let d): print("WS recv data: \(d.count) bytes")
                @unknown default: break
                }
                self?.receiveLoop()
            }
        }
    }

    private func handleDisconnect() {
        isConnected = false
        DispatchQueue.main.async { self.onDisconnected?() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self, !self.isConnected, !self.address.isEmpty else { return }
            print("Attempting WS reconnect to \(self.address)")
            self.connect(to: self.address)
        }
    }

    func sendStep(index: Int, instruction: String, distanceText: String, maneuver: String) {
        let dict: [String: Any] = [
            "index": index,
            "instruction": instruction,
            "distance_text": distanceText,
            "maneuver": maneuver
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else { return }

        if let t = task {
            t.send(.data(data)) { [weak self] err in
                if let err = err {
                    print("WS send error: \(err). Falling back to HTTP POST.")
                    self?.postFallback(data: data)
                } else {
                    print("WS send ok")
                }
            }
        } else {
            postFallback(data: data)
        }
    }

    private func postFallback(data: Data) {
        var host = "http://\(address)/step"
        if address.isEmpty { print("No address for fallback"); return }
        guard let url = URL(string: host) else { print("Invalid fallback URL"); return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { print("HTTP post error: \(err)") }
            else { print("HTTP post fallback succeeded") }
        }
        task.resume()
    }
}

final class NavController: ObservableObject {
    @Published var currentStepText: String = ""
    @Published var currentStepDistanceText: String = ""
    @Published var currentIndex: Int = -1
    @Published var websocketConnected: Bool = false
    @Published var status: String = "Idle"
    @Published var espAddress: String = "192.168.1.55:81" 

    let locationManager = LocationManager()
    let routeManager = RouteManager()
    let stepTracker = StepTracker()
    let wsManager = ESPWebSocketManager()

    init() {
        locationManager.onLocation = { [weak self] loc in
            self?.stepTracker.updateLocation(loc)
        }

        stepTracker.onStepChanged = { [weak self] idx, step in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.currentIndex = idx
                self.currentStepText = step.instructions
                self.currentStepDistanceText = NavController.formatDistance(step.distance)
                self.status = "Step \(idx)"
            }
            let maneuver = NavController.detectManeuver(from: step.instructions)
            self.wsManager.sendStep(index: idx, instruction: step.instructions, distanceText: NavController.formatDistance(step.distance), maneuver: maneuver)
        }

        wsManager.onConnected = { [weak self] in
            DispatchQueue.main.async {
                self?.websocketConnected = true
                self?.status = "Connected to ESP"
            }
        }
        wsManager.onDisconnected = { [weak self] in
            DispatchQueue.main.async {
                self?.websocketConnected = false
                self?.status = "ESP disconnected"
            }
        }
    }

    func startLocationServices() {
        locationManager.requestPermissions()
        locationManager.start()
        status = "Locating..."
    }

    func connectESP() {
        wsManager.connect(to: espAddress)
        status = "Connecting to \(espAddress)"
    }

    func disconnectESP() {
        wsManager.disconnect()
        status = "Disconnected"
    }

    func startNavigation(to destinationText: String) {
        guard let origin = locationManager.lastLocation?.coordinate else {
            status = "Waiting for location..."
            return
        }

        parseDestination(destinationText) { [weak self] coord, name in
            guard let self = self else { return }
            self.routeManager.requestRoute(from: origin, to: coord) { route in
                if let r = route {
                    self.stepTracker.setRoute(r)
                    DispatchQueue.main.async {
                        self.status = "Route set to \(name)"
                    }
                } else {
                    DispatchQueue.main.async {
                        self.status = "Route failed"
                    }
                }
            }
        }
    }

    func stopNavigation() {
        stepTracker.clear()
        currentIndex = -1
        currentStepText = ""
        currentStepDistanceText = ""
        status = "Navigation stopped"
    }

    private func parseDestination(_ text: String, completion: @escaping (CLLocationCoordinate2D, String) -> Void) {
        if let coord = NavController.parseLatLon(text) {
            completion(coord, "\(coord.latitude),\(coord.longitude)")
            return
        }

        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = text
        let search = MKLocalSearch(request: req)
        search.start { resp, err in
            if let item = resp?.mapItems.first {
                completion(item.placemark.coordinate, item.name ?? text)
            } else {
                DispatchQueue.main.async {
                    self.status = "Destination not found"
                }
            }
        }
    }

    static func parseLatLon(_ text: String) -> CLLocationCoordinate2D? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return nil
    }

    static func formatDistance(_ meters: Double) -> String {
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        let mf = MeasurementFormatter()
        mf.unitStyle = .short
        mf.unitOptions = .naturalScale
        mf.locale = Locale.current
        return mf.string(from: measurement)
    }

    static func detectManeuver(from instruction: String) -> String {
        let s = instruction.lowercased()
        if s.contains("u-turn") || s.contains("u turn") || s.contains("uturn") { return "uturn" }
        if s.contains("right") { return "turn-right" }
        if s.contains("left") { return "turn-left" }
        if s.contains("straight") || s.contains("continue") { return "straight" }
        return "straight"
    }
}