import SwiftUI

/// Keep press updates local to the decoration, outside the text/list hierarchy.
enum SearchSurfaceStyle {
    static let cornerRadius: CGFloat = 22
    static let inset: CGFloat = 12
    static let spacing: CGFloat = 6
    static let pressAnimation = Animation.spring(duration: 0.26, bounce: 0.16)
}

struct SearchElasticSurface: View {
    var isField: Bool
    @State private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Color.clear
            .glassEffect(.regular, in: .rect(cornerRadius: SearchSurfaceStyle.cornerRadius))
        .scaleEffect(
            x: isPressed && !reduceMotion ? (isField ? 0.985 : 0.988) : 1,
            y: isPressed && !reduceMotion ? (isField ? 0.96 : 0.988) : 1
        )
        .animation(reduceMotion ? nil : SearchSurfaceStyle.pressAnimation, value: isPressed)
        .modifier(SearchPressFeedback(isPressed: $isPressed))
    }
}

/// Observe a touch without competing with text selection, buttons or scrolling.
/// The caller animates only its decorative surface; text stays untransformed.
struct SearchPressFeedback: ViewModifier {
    @Binding var isPressed: Bool

    func body(content: Content) -> some View {
        content
            .background {
                #if os(iOS)
                SearchTouchObserver { isPressed = $0 }
                    .allowsHitTesting(false)
                #endif
            }
            .onDisappear { isPressed = false }
    }
}

#if os(iOS)
import UIKit

private struct SearchTouchObserver: UIViewRepresentable {
    let onChange: (Bool) -> Void

    func makeUIView(context: Context) -> TouchRegionView {
        TouchRegionView()
    }

    func updateUIView(_ view: TouchRegionView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleUIView(_ view: TouchRegionView, coordinator: ()) {
        view.detach()
    }

    final class TouchRegionView: UIView {
        var onChange: ((Bool) -> Void)?
        private weak var observedWindow: UIWindow?
        private var observer: PassiveTouchRecognizer?
        private var inactiveObserver: NSObjectProtocol?

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            let recognizer = PassiveTouchRecognizer()
            recognizer.region = self
            observer = recognizer
            observedWindow = window
            window.addGestureRecognizer(recognizer)
            inactiveObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak recognizer] _ in
                MainActor.assumeIsolated { recognizer?.cancelObservation() }
            }
        }

        func detach() {
            if let observer { observedWindow?.removeGestureRecognizer(observer) }
            observer = nil
            observedWindow = nil
            if let inactiveObserver { NotificationCenter.default.removeObserver(inactiveObserver) }
            inactiveObserver = nil
            // Dismantling may happen during SwiftUI's update pass.
            let callback = onChange
            DispatchQueue.main.async { callback?(false) }
        }

        func changed(_ value: Bool) { onChange?(value) }
    }

    final class PassiveTouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
        weak var region: TouchRegionView?
        private var origin: CGPoint?

        init() {
            super.init(target: nil, action: nil)
            delegate = self
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let region, region.window != nil else { return false }
            return region.bounds.contains(touch.location(in: region))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard origin == nil, touches.count == 1, let touch = touches.first else {
                cancelObservation()
                return
            }
            origin = touch.location(in: view)
            region?.changed(true)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let origin, let touch = touches.first else { return }
            let point = touch.location(in: view)
            if hypot(point.x - origin.x, point.y - origin.y) > 10 { cancelObservation() }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { cancelObservation() }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { cancelObservation() }

        func cancelObservation() {
            origin = nil
            region?.changed(false)
            // Never recognize: standard input/selection/scroll recognizers
            // remain solely responsible for the user's action.
            state = .failed
        }

        override func reset() {
            super.reset()
            origin = nil
        }
    }
}
#endif
