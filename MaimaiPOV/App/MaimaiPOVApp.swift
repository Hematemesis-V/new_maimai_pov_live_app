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

            let childVC = EdgeProtectChildVC()
            rootVC.addChild(childVC)
            childVC.view.frame = .zero
            childVC.view.isUserInteractionEnabled = false
            rootVC.view.addSubview(childVC.view)
            childVC.didMove(toParent: rootVC)

            let cls: AnyClass = object_getClass(rootVC)!

            let childHomeSel = sel_registerName("childViewControllerForHomeIndicatorAutoHidden")
            let childHomeBlock: @convention(block) (AnyObject) -> AnyObject? = { [weak childVC] _ in childVC }
            class_replaceMethod(cls, childHomeSel, imp_implementationWithBlock(childHomeBlock), "@@:")

            let childDeferSel = sel_registerName("childForScreenEdgesDeferringSystemGestures")
            let childDeferBlock: @convention(block) (AnyObject) -> AnyObject? = { [weak childVC] _ in childVC }
            class_replaceMethod(cls, childDeferSel, imp_implementationWithBlock(childDeferBlock), "@@:")

            rootVC.setNeedsUpdateOfHomeIndicatorAutoHidden()
            rootVC.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        }
    }
}

private class EdgeProtectChildVC: UIViewController {
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .bottom }
}
