import SwiftUI

struct PermissionView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Text("Apple Health access")
                .font(.title2.bold())
            Text("YourPHR Companion needs read access to heart rate, blood pressure, sleep, steps, weight, and a few related types so it can send them to YourPHR. Nothing is written back to Apple Health.")
                .foregroundStyle(.secondary)

            Button {
                Task { await model.requestHealthAccess() }
            } label: {
                Text(model.isBusy ? "Requesting…" : "Allow Health access")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy)

            if !HealthKitAuthorizer.isAvailable {
                Text("HealthKit is not available in the Simulator. You can skip this step to inspect pairing, but samples will not upload until you run on a phone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Continue without HealthKit") {
                    model.skipHealthOnSimulator()
                }
            }

            if let error = model.lastError {
                Text(error).foregroundStyle(.red)
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Health")
    }
}
