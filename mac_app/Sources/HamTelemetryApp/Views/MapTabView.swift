// FILE: mac_app/Sources/HamTelemetryApp/Views/MapTabView.swift
//
// MapKit-backed live map with the drone position, trail polyline, and a
// GPS quality footer.

import SwiftUI
import MapKit

struct MapTabView: View {
    @EnvironmentObject var t: TelemetryModel
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
    @State private var followDrone = true

    var body: some View {
        VStack(spacing: 0) {
            MapRepresentable(region: $region, trail: t.trail, drone: droneCoord)
            gpsFooter
        }
        .onChange(of: droneCoordKey) { _ in
            if followDrone, let c = droneCoord {
                region.center = c
            }
        }
        .onAppear {
            if let c = droneCoord { region.center = c }
        }
    }

    private var droneCoord: CLLocationCoordinate2D? {
        if let lat = t.current.latitude, let lon = t.current.longitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return nil
    }

    private var droneCoordKey: String {
        "\(t.current.latitude ?? 0),\(t.current.longitude ?? 0)"
    }

    private var gpsFooter: some View {
        HStack(spacing: 18) {
            Label(fixName, systemImage: "location.fill")
                .foregroundStyle(fixColor)
            Label("\(t.current.gpsSats ?? 0) sats", systemImage: "antenna.radiowaves.left.and.right")
            if let h = t.current.gpsHDOP {
                Label(String(format: "HDOP %.2f", h), systemImage: "scope")
            }
            Spacer()
            Toggle("Follow", isOn: $followDrone).toggleStyle(.switch)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var fixName: String {
        switch t.current.gpsFixType ?? 0 {
        case 0: return "no fix"
        case 1: return "no fix"
        case 2: return "2D fix"
        case 3: return "3D fix"
        case 4: return "DGPS"
        case 5: return "RTK float"
        case 6: return "RTK fixed"
        default: return "fix \(t.current.gpsFixType ?? 0)"
        }
    }

    private var fixColor: Color {
        switch t.current.gpsFixType ?? 0 {
        case 0, 1: return .red
        case 2:    return .orange
        case 3:    return .green
        case 4, 5, 6: return .blue
        default:   return .secondary
        }
    }
}

// MARK: - NSViewRepresentable for MKMapView (needed for overlay support on macOS)

private struct MapRepresentable: NSViewRepresentable {
    @Binding var region: MKCoordinateRegion
    var trail: [CLLocationCoordinate2D]
    var drone: CLLocationCoordinate2D?

    func makeNSView(context: Context) -> MKMapView {
        let v = MKMapView()
        v.delegate = context.coordinator
        v.showsCompass = true
        v.showsScale = true
        return v
    }

    func updateNSView(_ v: MKMapView, context: Context) {
        v.setRegion(region, animated: false)

        v.removeOverlays(v.overlays)
        if trail.count >= 2 {
            let poly = MKPolyline(coordinates: trail, count: trail.count)
            v.addOverlay(poly)
        }

        v.removeAnnotations(v.annotations)
        if let d = drone {
            let a = MKPointAnnotation()
            a.coordinate = d
            a.title = "drone"
            v.addAnnotation(a)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let poly = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: poly)
                r.strokeColor = NSColor.systemBlue
                r.lineWidth = 3
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
