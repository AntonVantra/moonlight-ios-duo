// SPDX-License-Identifier: GPL-3.0-only

import UIKit

/// Uses the hinge associated with this window. Non-foldables keep the manual layout control.
@MainActor
@objcMembers
final class DesktopPoseObserver: NSObject {
    private weak var view: UIView?
    private var partiallyOpen = false

    init(view: UIView, onChange: @escaping () -> Void) {
        self.view = view
        super.init()
        if #available(iOS 27.1, *) {
            view.addInteraction(UIHingeInteraction { [weak self] _, update in
                self?.partiallyOpen = update.hinge?.status == .partiallyOpen
                onChange()
            })
        }
    }

    var horizontalDivision: CGRect {
        guard #available(iOS 27.1, *), let view else { return .zero }
        return view.reservedRegions(kind: .division).map(\.frame)
            .first { $0.width >= view.bounds.width * 0.75 && $0.height < view.bounds.height * 0.25 }
            ?? .zero
    }

    var isLaptopPose: Bool {
        partiallyOpen && horizontalDivision.height > 0
    }
}
