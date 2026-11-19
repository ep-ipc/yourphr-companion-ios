import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.route {
            case .home:
                HomeView()
            case .pair:
                PairView()
            case .sync:
                StatusView()
            }
        }
        .animation(.default, value: model.route)
    }
}
