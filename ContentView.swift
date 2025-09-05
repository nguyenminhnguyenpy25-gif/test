import SwiftUI

struct ContentView: View {
    @EnvironmentObject var nav: NavController
    @State private var destinationText: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("ESP (WebSocket)")) {
                    HStack {
                        TextField("ESP IP:port", text: $nav.espAddress)
                            .keyboardType(.URL)
                            .disableAutocorrection(true)
                        Button(nav.websocketConnected ? "Disconnect" : "Connect") {
                            if nav.websocketConnected { nav.disconnectESP() } else { nav.connectESP() }
                        }
                    }
                }

                Section(header: Text("Navigation")) {
                    Button("Start Location Services") {
                        nav.startLocationServices()
                    }
                    TextField("Destination (address OR lat,lon)", text: $destinationText)
                        .focused($focused)
                    HStack {
                        Button("Start Nav") {
                            focused = false
                            nav.startNavigation(to: destinationText)
                        }
                        Button("Stop Nav") {
                            nav.stopNavigation()
                        }
                        .foregroundColor(.red)
                    }
                }

                Section(header: Text("Current Step")) {
                    Text("Index: \(nav.currentIndex >= 0 ? String(nav.currentIndex) : "-")")
                    Text("Instruction: \(nav.currentStepText)")
                    Text("Distance: \(nav.currentStepDistanceText)")
                    Text("Status: \(nav.status)")
                }

                Section(header: Text("Notes")) {
                    Text("Make sure iPhone and ESP are on the same Wi‑Fi. App must be allowed Always location (Settings -> App -> Allow Always) to continue sending updates while backgrounded.")
                        .font(.footnote)
                }
            }
            .navigationTitle("NavBridge")
        }
    }
}