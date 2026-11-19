import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Companion for YourPHR. Pair only when you want to sync Apple Health — nothing is required at install.")
                        .foregroundStyle(.secondary)

                    Button {
                        model.requestSync()
                    } label: {
                        Text("Sync health with YourPHR")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Reads Apple Health and uploads samples. You will pair if this phone is not linked yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("YourPHR Companion")
        }
    }
}
