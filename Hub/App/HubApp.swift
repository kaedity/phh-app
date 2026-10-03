import SwiftUI
import GoogleSignIn
@main struct HubApp: App {
    @UIApplicationDelegateAdaptor(HealthAppDelegate.self) private var appDelegate
    init() {
        let preview=ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--p") && $0.hasSuffix("-preview") }
        HealthAppDelegate.makeRuntime = preview ? nil : { HubModel.shared.healthRuntime }
    }
    var body: some Scene { WindowGroup {
        #if DEBUG
        Group {
            if ProcessInfo.processInfo.arguments.contains("--p8-patterns-preview") { MotionPatternsPreviewRoot() }
            else if ProcessInfo.processInfo.arguments.contains("--p8-motion-preview") { MotionPreviewRoot() }
            else if ProcessInfo.processInfo.arguments.contains("--p7-preview") { HubPreviewRoot() }
            else if ProcessInfo.processInfo.arguments.contains("--p3-preview") { TrainingPreviewRoot() }
            else if ProcessInfo.processInfo.arguments.contains("--p4-preview") { FoodPreviewRoot() }
            else if ProcessInfo.processInfo.arguments.contains("--p5-preview") { PlanningPreviewRoot() }
            else if ProcessInfo.processInfo.arguments.contains("--p6-preview") { HealthPreviewRoot() }
            else { HubLiveRoot() }
        }.modifier(PreviewDisplay()).toggleStyle(MotionToggleStyle())
        #else
        HubLiveRoot().toggleStyle(MotionToggleStyle())
        #endif
    } }
}
private struct HubLiveRoot: View {
    @State private var model = HubModel.shared
    var body: some View { HubRoot(model:model).modifier(SharedPlateLifetime()).onOpenURL { _ = GIDSignIn.sharedInstance.handle($0) } }
}
