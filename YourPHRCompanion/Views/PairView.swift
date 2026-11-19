import SwiftUI

struct PairView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showScanner: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }()
    @State private var baseURL = ""
    @State private var setupCode = ""
    @State private var parseError: String?

    private var reason: String {
        switch model.pairingIntent {
        case .sync: return "Pair to sync health samples."
        case .none: return "Pair this phone with YourPHR."
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Pair with YourPHR")
                        .font(.title2.bold())
                    Text("\(reason) Scan the QR from YourPHR Settings → Connected devices, or paste the API address and the setup code. The phone stores the keys in the Keychain. Both Connected devices and Health have to be turned on for the claim to exist.")
                        .foregroundStyle(.secondary)

                    if showScanner {
                        QRScannerView { code in
                            Task { await pairQR(code) }
                        }
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button(showScanner ? "Enter the setup code instead" : "Scan QR code") {
                        showScanner.toggle()
                    }
                    .frame(minHeight: 44)

                    if !showScanner {
                        TextField("https://phr.example.org", text: $baseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textFieldStyle(.roundedBorder)
                        TextField("Setup code", text: $setupCode, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(2...6)
                            .textFieldStyle(.roundedBorder)
                        Button("Pair") {
                            Task { await pairManual() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || baseURL.isEmpty || setupCode.isEmpty)
                        .frame(minHeight: 44)
                    }

                    if let error = parseError ?? model.pairingError {
                        Text(error)
                            .foregroundStyle(.red)
                    }

                    if model.isBusy {
                        ProgressView("Contacting YourPHR…")
                        Text("If iOS asks to find devices on your local network, tap Allow.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("YourPHR Companion")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { model.dismissPair() }
                        .frame(minHeight: 44)
                }
            }
        }
    }

    private func pairQR(_ raw: String) async {
        do {
            let payload = try PairingPayload.parseQR(raw)
            parseError = nil
            await model.pair(payload: payload)
        } catch {
            parseError = error.localizedDescription
        }
    }

    private func pairManual() async {
        do {
            let payload = try PairingPayload.parseManual(baseURL: baseURL, code: setupCode)
            parseError = nil
            await model.pair(payload: payload)
        } catch {
            parseError = error.localizedDescription
        }
    }
}
