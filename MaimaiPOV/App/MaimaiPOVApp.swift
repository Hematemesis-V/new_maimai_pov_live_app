import SwiftUI

@main
struct MaimaiPOVApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            Phase2View()
                .onAppear {
                    patchRootViewControllerForFullScreen()
                }
        }
    }

    private func patchRootViewControllerForFullScreen() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = windowScene.windows.first,
                  let rootVC = window.rootViewController else { return }

            let cls: AnyClass = object_getClass(rootVC)!

            let homeSelector = sel_registerName("prefersHomeIndicatorAutoHidden")
            if let method = class_getInstanceMethod(cls, homeSelector) {
                let block: @convention(block) (AnyObject) -> Bool = { _ in true }
                method_setImplementation(method, imp_implementationWithBlock(block))
            }

            let deferSelector = sel_registerName("preferredScreenEdgesDeferringSystemGestures")
            if let method = class_getInstanceMethod(cls, deferSelector) {
                let block: @convention(block) (AnyObject) -> UInt = { _ in UIRectEdge.bottom.rawValue }
                method_setImplementation(method, imp_implementationWithBlock(block))
            }

            rootVC.setNeedsUpdateOfHomeIndicatorAutoHidden()
            rootVC.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        }
    }
}
