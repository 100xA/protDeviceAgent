import SwiftUI
import MapKit

struct LocationMapView: View {
    let latitude: Double
    let longitude: Double
    @State private var region: MKCoordinateRegion
    @Environment(\.dismiss) private var dismiss

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
        let coord = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        _region = State(initialValue: MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
    }

    var body: some View {
        ZStack {
            Map(position: .constant(.region(region))) {
                Annotation("You", coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) {
                    ZStack {
                        Circle().fill(.red).frame(width: 10, height: 10)
                        Circle().stroke(.white, lineWidth: 2).frame(width: 14, height: 14)
                    }
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.primary)
                            .padding(8)
                            .background(.thinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Close")
                }
                .padding()
                Spacer()
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }
}


