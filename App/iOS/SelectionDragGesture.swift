import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import OMKit

/// Where each visible grid cell is, for hit testing while dragging. A class so that
/// updating it while scrolling does not redraw the grid.
final class CellFrames {
    var map: [MediaItem.ID: CGRect] = [:]

    func item(at point: CGPoint) -> MediaItem.ID? {
        map.first { $0.value.contains(point) }?.key
    }
}

/// Starts when a finger rests on the grid for a moment, or moves sideways right away.
/// A vertical move fails it, so scrolling works as usual.
final class SelectionDragRecognizer: UIGestureRecognizer {
    private let holdDelay = Duration.milliseconds(300)
    private let slop: CGFloat = 10
    private var origin = CGPoint.zero
    private var hold: Task<Void, Never>?
    /// How far the finger has travelled since it touched down (screen points).
    private(set) var travel = CGSize.zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard numberOfTouches == 1, let touch = touches.first else {
            if state == .possible { state = .failed }  // two fingers: pinch to zoom
            return
        }
        origin = touch.location(in: nil)
        travel = .zero
        hold = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.holdDelay ?? .zero)
            guard !Task.isCancelled, let self, self.state == .possible else { return }
            self.state = .began
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let point = touches.first?.location(in: nil) else { return }
        travel = CGSize(width: point.x - origin.x, height: point.y - origin.y)
        switch state {
        case .possible:
            let dx = abs(point.x - origin.x), dy = abs(point.y - origin.y)
            guard max(dx, dy) > slop else { return }
            hold?.cancel()
            state = dx > dy * 1.2 ? .began : .failed
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        hold?.cancel()
        state = state == .began || state == .changed ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        hold?.cancel()
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        hold?.cancel()
        hold = nil
    }
}

struct SelectionDragGesture: UIGestureRecognizerRepresentable {
    /// Points are in the coordinate space of the view the gesture is attached to.
    let onBegan: (CGPoint) -> Void
    let onMoved: (CGPoint) -> Void
    let onEnded: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> SelectionDragRecognizer {
        let recognizer = SelectionDragRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: SelectionDragRecognizer, context: Context) {
        let point = context.converter.localLocation
        switch recognizer.state {
        case .began:
            // Anchor on the photo first touched, even if the finger already moved past it.
            onBegan(CGPoint(x: point.x - recognizer.travel.width, y: point.y - recognizer.travel.height))
            onMoved(point)
        case .changed: onMoved(point)
        case .ended, .cancelled, .failed: onEnded()
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Scrolling (and the sidebar swipe) wait until this gesture has given up.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer
        }
    }
}
