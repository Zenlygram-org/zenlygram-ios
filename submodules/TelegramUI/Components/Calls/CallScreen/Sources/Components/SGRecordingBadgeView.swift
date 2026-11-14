// MARK: Zenlygram — local call recording, the on-screen indicator.
//
// Apple guideline 2.5.14 requires "a clear visual and/or audible indication when recording". The
// system's own orange/red microphone dot is present during any call, recording or not, so it says
// nothing about recording and cannot be the app's answer on its own.
//
// This badge is drawn right under the call timer — the one element of the call screen that is
// present in every layout state, including full-screen video — and the call screen also raises a
// persistent notice above the button row, which is the surface that survives the controls being
// hidden. The minimised call bar carries the marker app-wide, and CallKit carries it on the lock
// screen. Together those are every surface this app is able to draw on.

import Foundation
import UIKit
import Display
import ComponentFlow

final class SGRecordingBadgeView: UIView {
    private let backgroundView: UIView
    private let dotView: UIView
    private let textView: TextView

    override init(frame: CGRect) {
        self.backgroundView = UIView()
        self.backgroundView.backgroundColor = UIColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 0.92)
        self.backgroundView.clipsToBounds = true

        self.dotView = UIView()
        self.dotView.backgroundColor = .white

        self.textView = TextView()

        super.init(frame: frame)

        self.addSubview(self.backgroundView)
        self.addSubview(self.dotView)
        self.addSubview(self.textView)

        self.isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A slow pulse, so the badge reads as live rather than as a static label.
    private func startPulsing() {
        if self.dotView.layer.animation(forKey: "sgRecordingPulse") != nil {
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0 as NSNumber
        animation.toValue = 0.25 as NSNumber
        animation.duration = 0.7
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        self.dotView.layer.add(animation, forKey: "sgRecordingPulse")
    }

    func update(text: String, transition: ComponentTransition) -> CGSize {
        let dotDiameter: CGFloat = 7.0
        let horizontalInset: CGFloat = 8.0
        let dotTextSpacing: CGFloat = 5.0
        let height: CGFloat = 20.0

        let textSize = self.textView.update(string: text, fontSize: 12.0, fontWeight: 0.35, color: .white, constrainedWidth: 220.0, transition: .immediate)

        let width = horizontalInset + dotDiameter + dotTextSpacing + textSize.width + horizontalInset
        let size = CGSize(width: width, height: height)

        transition.setFrame(view: self.backgroundView, frame: CGRect(origin: CGPoint(), size: size))
        self.backgroundView.layer.cornerRadius = height * 0.5

        self.dotView.frame = CGRect(origin: CGPoint(x: horizontalInset, y: floor((height - dotDiameter) * 0.5)), size: CGSize(width: dotDiameter, height: dotDiameter))
        self.dotView.layer.cornerRadius = dotDiameter * 0.5

        self.textView.frame = CGRect(origin: CGPoint(x: horizontalInset + dotDiameter + dotTextSpacing, y: floor((height - textSize.height) * 0.5)), size: textSize)

        // Audit #58: the text is drawn by TextView, invisible to VoiceOver until labelled here.
        self.isAccessibilityElement = true
        self.accessibilityLabel = text
        self.accessibilityTraits = .staticText

        self.startPulsing()

        return size
    }
}
