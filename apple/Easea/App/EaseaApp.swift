import SwiftUI
import UserNotifications
import Observation

@main
struct EaseaApp: App {
    @State private var store: ProjectStore
    @State private var settings: AppSettings
    @State private var queue: CutQueue
    @State private var router = Router()
    private static let notificationRouter = NotificationRouter()

    init() {
        let store = ProjectStore()
        let settings = AppSettings()
        _store = State(initialValue: store)
        _settings = State(initialValue: settings)
        _queue = State(initialValue: CutQueue(store: store, settings: settings))
        UNUserNotificationCenter.current().delegate = Self.notificationRouter
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(settings)
                .environment(queue)
                .environment(router)
                .onAppear {
                    Self.notificationRouter.onOpenProject = { router.open($0) }
                }
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 640)
                #endif
        }
        #if os(macOS)
        .windowToolbarStyle(.unified)
        #endif
    }
}

/// App-wide navigation state, so notifications can deep-link to a cut.
@MainActor
@Observable
final class Router {
    enum Tab: Hashable { case create, cuts, you }
    var tab: Tab = .create
    var cutsPath: [UUID] = []

    func open(_ projectID: UUID) {
        tab = .cuts
        cutsPath = [projectID]
    }
}

struct RootView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            CreateView()
                .tabItem { Label("Create", systemImage: "camera.fill") }
                .tag(Router.Tab.create)
            CutsView()
                .tabItem { Label("Cuts", systemImage: "square.stack.fill") }
                .tag(Router.Tab.cuts)
            YouView()
                .tabItem { Label("You", systemImage: "person.fill") }
                .tag(Router.Tab.you)
        }
    }
}
