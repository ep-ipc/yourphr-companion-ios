import SwiftUI

struct StatusView: View {
    @EnvironmentObject private var model: AppModel
    @State private var healthTypesExpanded = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !model.healthAuthorized {
                    healthBanner
                }
                syncList
            }
            .navigationTitle("Sync")
            .sheet(isPresented: $model.showHealthPrompt) {
                NavigationStack {
                    PermissionView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { model.showHealthPrompt = false }
                            }
                        }
                }
                .environmentObject(model)
            }
        }
        .onChange(of: model.healthAuthorized) { authorized in
            if authorized { model.showHealthPrompt = false }
        }
        .task(id: model.healthAuthorized) {
            await model.loadLatestReadings()
        }
    }

    private var syncList: some View {
        List {
            Section("YourPHR") {
                LabeledContent("Server", value: model.baseURL ?? "—")
                if let user = model.username {
                    LabeledContent("User", value: user)
                }
            }

            Section("Last sync") {
                LabeledContent("When") {
                    Text(model.lastSyncAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                }
                LabeledContent("Received", value: "\(model.lastReceived)")
                LabeledContent("Stored", value: "\(model.lastStored)")
                if model.pendingUnlock {
                    Text("Waiting for unlock — HealthKit is encrypted while the phone is locked. Sync will retry when you open the app.")
                        .foregroundStyle(.orange)
                } else if let error = model.lastError {
                    Text(error).foregroundStyle(.red)
                }
                if let progress = model.progress {
                    Text(progress).foregroundStyle(.secondary)
                }
                Button {
                    Task { await model.syncNow(budget: .foreground) }
                } label: {
                    Text(model.isBusy ? "Syncing…" : "Sync now")
                }
                .disabled(model.isBusy || !HealthKitAuthorizer.isAvailable)
            }

            Section {
                DisclosureGroup(isExpanded: $healthTypesExpanded) {
                    ForEach(SyncedMetric.allCases, id: \.rawValue) { metric in
                        LabeledContent(metric.displayName, value: model.readingText(for: metric))
                    }
                } label: {
                    Text("Health types")
                }
            }

            Section {
                Button("Unpair this phone", role: .destructive) {
                    model.unpair()
                }
            } footer: {
                Text("Foreground sync runs every 5 minutes while the app is open. In the background, new HealthKit samples wake the app. iOS will not honor a 5-minute timer once the app is suspended. Unpair here to disconnect this phone.")
            }
        }
        .refreshable {
            await model.syncNow(budget: .foreground)
        }
    }

    private var healthBanner: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Apple Health is not connected, so readings are not syncing.")
                .font(.footnote)
            Spacer(minLength: 8)
            Button("Allow") { model.showHealthPrompt = true }
                .font(.footnote.bold())
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15))
    }
}
