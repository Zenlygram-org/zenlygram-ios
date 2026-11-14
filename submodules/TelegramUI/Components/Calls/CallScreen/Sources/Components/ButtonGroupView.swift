import Foundation
import UIKit
import Display
import ComponentFlow
import AppBundle
import TelegramPresentationData

// MARK: Zenlygram — the record button's glyph.
//
// Drawn rather than shipped as an asset: the content button uses the image purely as an alpha mask
// (ContentOverlayButton.updateContent), so a filled circle is all that is needed and adding an
// entry to the asset catalogue for it would be noise.
private let sgRecordButtonImage: UIImage? = {
    return generateImage(CGSize(width: 44.0, height: 44.0), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.setFillColor(UIColor.white.cgColor)
        let diameter: CGFloat = 22.0
        context.fillEllipse(in: CGRect(origin: CGPoint(x: (size.width - diameter) * 0.5, y: (size.height - diameter) * 0.5), size: CGSize(width: diameter, height: diameter)))
    })
}()

// MARK: Zenlygram — the "Recording this call" notice glyph (audit #114): a dot in a ring, the
// conventional record mark, on the same 24 pt canvas as the other call toast icons. It used to
// borrow the crossed-out microphone, which said "your microphone is off" next to the one notice
// whose job is to say the opposite is being captured.
let sgRecordingNoticeIconImage: UIImage? = {
    return generateImage(CGSize(width: 24.0, height: 24.0), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.setFillColor(UIColor.white.cgColor)
        context.setStrokeColor(UIColor.white.cgColor)
        let ringDiameter: CGFloat = 14.0
        let ringLineWidth: CGFloat = 1.66
        let dotDiameter: CGFloat = 7.0
        context.setLineWidth(ringLineWidth)
        context.strokeEllipse(in: CGRect(origin: CGPoint(x: (size.width - ringDiameter) * 0.5, y: (size.height - ringDiameter) * 0.5), size: CGSize(width: ringDiameter, height: ringDiameter)))
        context.fillEllipse(in: CGRect(origin: CGPoint(x: (size.width - dotDiameter) * 0.5, y: (size.height - dotDiameter) * 0.5), size: CGSize(width: dotDiameter, height: dotDiameter)))
    })
}()

final class ButtonGroupView: OverlayMaskContainerView {
    final class Button {
        enum Content: Equatable {
            enum Key: Hashable {
                case speaker
                case flipCamera
                case video
                case microphone
                case record
                case end
            }
            
            case speaker(audioOutput: PrivateCallScreen.State.AudioOutput)
            case flipCamera
            case video(isActive: Bool)
            case microphone(isMuted: Bool)
            // MARK: Zenlygram — local call recording. The title is passed in because this module has
            // no access to SGStrings.
            case record(isRecording: Bool, title: String)
            case end
            
            var key: Key {
                switch self {
                case .speaker:
                    return .speaker
                case .flipCamera:
                    return .flipCamera
                case .video:
                    return .video
                case .microphone:
                    return .microphone
                case .record:
                    return .record
                case .end:
                    return .end
                }
            }
        }
        
        let content: Content
        let isEnabled: Bool
        let action: () -> Void
        
        init(content: Content, isEnabled: Bool, action: @escaping () -> Void) {
            self.content = content
            self.isEnabled = isEnabled
            self.action = action
        }
    }
    
    final class Notice {
        let id: AnyHashable
        let icon: String
        /// Zenlygram — a drawn glyph for a notice that has no asset; used instead of `icon`.
        let iconImage: UIImage?
        let text: String
        
        init(id: AnyHashable, icon: String, text: String) {
            self.id = id
            self.icon = icon
            self.iconImage = nil
            self.text = text
        }
        
        init(id: AnyHashable, iconImage: UIImage?, text: String) {
            self.id = id
            self.icon = ""
            self.iconImage = iconImage
            self.text = text
        }
    }
    
    private var buttons: [Button]?
    private var buttonViews: [Button.Content.Key: ContentOverlayButton] = [:]
    private var noticeViews: [AnyHashable: NoticeView] = [:]
    private var closeButtonView: CloseButtonView?
    
    var closePressed: (() -> Void)?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let result = super.hitTest(point, with: event) else {
            return nil
        }
        if result === self {
            return nil
        }
        return result
    }
    
    func update(size: CGSize, insets: UIEdgeInsets, minWidth: CGFloat, controlsHidden: Bool, displayClose: Bool, strings: PresentationStrings, buttons: [Button], notices: [Notice], isAnimatedOutToGroupCall: Bool, transition: ComponentTransition) -> CGFloat {
        self.buttons = buttons
        
        let buttonSize: CGFloat = 56.0
        // MARK: Zenlygram — the spacing is derived, not fixed.
        //
        // A fixed 36 pt was fine while this row never held more than four buttons (4 × 56 + 3 × 36
        // = 332 pt, comfortable on every iPhone). The record button makes five: 5 × 56 + 4 × 36 =
        // 424 pt, which overflows every model except the Plus/Max — on a 393 pt iPhone 16 the row
        // starts at x = −16 and ends 15 pt past the right edge, putting part of the speaker button
        // and part of the destructive End button outside the screen, untappable. Nothing here
        // clips or scrolls, so the row has to fit. Spacing shrinks toward a floor before the row
        // can go off-edge; with four buttons the arithmetic still lands on 36 pt, so existing
        // layouts are unchanged.
        let maximumButtonSpacing: CGFloat = 36.0
        let minimumButtonSpacing: CGFloat = 10.0
        let buttonRowSideInset: CGFloat = 16.0
        var buttonSpacing: CGFloat = maximumButtonSpacing
        if buttons.count > 1 {
            let gapCount = CGFloat(buttons.count - 1)
            let availableForGaps = size.width - buttonRowSideInset * 2.0 - buttonSize * CGFloat(buttons.count)
            buttonSpacing = max(minimumButtonSpacing, min(maximumButtonSpacing, floor(availableForGaps / gapCount)))
        }

        let buttonNoticeSpacing: CGFloat = 16.0
        let controlsHiddenNoticeSpacing: CGFloat = 0.0
        var nextNoticeY: CGFloat
        if isAnimatedOutToGroupCall {
            nextNoticeY = size.height + 4.0
        } else if controlsHidden {
            nextNoticeY = size.height - insets.bottom - 4.0
        } else {
            nextNoticeY = size.height - insets.bottom - 52.0 - buttonSize - buttonNoticeSpacing
        }
        let noticeSpacing: CGFloat = 8.0
        
        var validNoticeIds: [AnyHashable] = []
        var noticesHeight: CGFloat = 0.0
        for notice in notices {
            validNoticeIds.append(notice.id)
            
            let noticeView: NoticeView
            var noticeTransition = transition
            var animateIn = false
            if let current = self.noticeViews[notice.id] {
                noticeView = current
            } else {
                noticeTransition = noticeTransition.withAnimation(.none)
                animateIn = true
                noticeView = NoticeView()
                self.noticeViews[notice.id] = noticeView
                self.addSubview(noticeView)
            }
            
            if noticesHeight != 0.0 {
                noticesHeight += noticeSpacing
            } else {
                if controlsHidden {
                    noticesHeight += controlsHiddenNoticeSpacing
                } else {
                    noticesHeight += buttonNoticeSpacing
                }
            }
            let noticeSize = noticeView.update(icon: notice.icon, iconImage: notice.iconImage, text: notice.text, constrainedWidth: size.width - insets.left * 2.0 - 16.0 * 2.0, transition: noticeTransition)
            let noticeFrame = CGRect(origin: CGPoint(x: floor((size.width - noticeSize.width) * 0.5), y: isAnimatedOutToGroupCall ? nextNoticeY : (nextNoticeY - noticeSize.height)), size: noticeSize)
            noticesHeight += noticeSize.height
            if !isAnimatedOutToGroupCall {
                nextNoticeY -= noticeSize.height + noticeSpacing
            }
            
            noticeTransition.setFrame(view: noticeView, frame: noticeFrame)
            if animateIn, !transition.animation.isImmediate {
                noticeView.animateIn()
            }
        }
        if noticesHeight != 0.0 {
            noticesHeight += 5.0
        }
        if isAnimatedOutToGroupCall {
            noticesHeight = 0.0
        }
        var removedNoticeIds: [AnyHashable] = []
        for (id, noticeView) in self.noticeViews {
            if !validNoticeIds.contains(id) {
                removedNoticeIds.append(id)
                if !transition.animation.isImmediate {
                    noticeView.animateOut(completion: { [weak noticeView] in
                        noticeView?.removeFromSuperview()
                    })
                } else {
                    noticeView.removeFromSuperview()
                }
            }
        }
        for id in removedNoticeIds {
            self.noticeViews.removeValue(forKey: id)
        }
        
        let buttonY: CGFloat
        let resultHeight: CGFloat
        if controlsHidden || isAnimatedOutToGroupCall {
            buttonY = size.height + 12.0
            resultHeight = insets.bottom + 4.0 + noticesHeight
        } else {
            buttonY = size.height - insets.bottom - 52.0 - buttonSize
            resultHeight = size.height - buttonY + noticesHeight
        }
        var buttonX: CGFloat = floor((size.width - buttonSize * CGFloat(buttons.count) - buttonSpacing * CGFloat(buttons.count - 1)) * 0.5)
        
        if displayClose {
            let closeButtonView: CloseButtonView
            var closeButtonTransition = transition
            var animateIn = false
            if let current = self.closeButtonView {
                closeButtonView = current
            } else {
                closeButtonTransition = closeButtonTransition.withAnimation(.none)
                animateIn = true
                
                closeButtonView = CloseButtonView()
                self.closeButtonView = closeButtonView
                self.addSubview(closeButtonView)
                closeButtonView.pressAction = { [weak self] in
                    guard let self else {
                        return
                    }
                    self.closePressed?()
                }
            }
            let closeButtonSize = CGSize(width: minWidth, height: buttonSize)
            closeButtonView.update(text: strings.Common_Close, size: closeButtonSize, transition: closeButtonTransition)
            closeButtonTransition.setFrame(view: closeButtonView, frame: CGRect(origin: CGPoint(x: floor((size.width - closeButtonSize.width) * 0.5), y: buttonY), size: closeButtonSize))
            
            if animateIn && !transition.animation.isImmediate {
                closeButtonView.animateIn()
            }
        } else {
            if let closeButtonView = self.closeButtonView {
                self.closeButtonView = nil
                if !transition.animation.isImmediate {
                    closeButtonView.animateOut(completion: { [weak closeButtonView] in
                        closeButtonView?.removeFromSuperview()
                    })
                } else {
                    closeButtonView.removeFromSuperview()
                }
            }
        }
        
        for button in buttons {
            let title: String
            let image: UIImage?
            let isActive: Bool
            var isDestructive: Bool = false
            switch button.content {
            case let .speaker(audioOutput):
                switch audioOutput {
                case .internalSpeaker, .speaker:
                    title = strings.Call_Speaker
                default:
                    title = strings.Call_Audio
                }
                
                switch audioOutput {
                case .internalSpeaker:
                    image = UIImage(bundleImageName: "Call/Speaker")
                    isActive = false
                case .speaker:
                    image = UIImage(bundleImageName: "Call/Speaker")
                    isActive = true
                case .airpods:
                    image = UIImage(bundleImageName: "Call/CallAirpodsButton")
                    isActive = true
                case .airpodsPro:
                    image = UIImage(bundleImageName: "Call/CallAirpodsProButton")
                    isActive = true
                case .airpodsMax:
                    image = UIImage(bundleImageName: "Call/CallAirpodsMaxButton")
                    isActive = true
                case .headphones:
                    image = UIImage(bundleImageName: "Call/CallHeadphonesButton")
                    isActive = true
                case .bluetooth:
                    image = UIImage(bundleImageName: "Call/CallBluetoothButton")
                    isActive = true
                }
            case .flipCamera:
                title = strings.Call_Flip
                image = UIImage(bundleImageName: "Call/Flip")
                isActive = false
            case let .video(isActiveValue):
                title = strings.Call_Video
                image = UIImage(bundleImageName: "Call/Video")
                isActive = isActiveValue
            case let .microphone(isActiveValue):
                title = strings.Call_Mute
                image = UIImage(bundleImageName: "Call/Mute")
                isActive = isActiveValue
            // MARK: Zenlygram — local call recording.
            case let .record(isRecordingValue, recordTitle):
                title = recordTitle
                image = sgRecordButtonImage
                isActive = isRecordingValue
            case .end:
                title = strings.Call_End
                image = UIImage(bundleImageName: "Call/End")
                isActive = false
                isDestructive = true
            }
            
            var buttonTransition = transition
            let buttonView: ContentOverlayButton
            if let current = self.buttonViews[button.content.key] {
                buttonView = current
            } else {
                buttonTransition = transition.withAnimation(.none)
                buttonView = ContentOverlayButton(frame: CGRect())
                self.addSubview(buttonView)
                self.buttonViews[button.content.key] = buttonView
                
                let key = button.content.key
                buttonView.action = { [weak self] in
                    guard let self, let button = self.buttons?.first(where: { $0.content.key == key }) else {
                        return
                    }
                    button.action()
                }
                
                ComponentTransition.immediate.setScale(view: buttonView, scale: 0.001)
                buttonView.alpha = 0.0
                transition.setScale(view: buttonView, scale: 1.0)
            }
            
            transition.setAlpha(view: buttonView, alpha: displayClose ? 0.0 : 1.0)
            
            buttonTransition.setFrame(view: buttonView, frame: CGRect(origin: CGPoint(x: buttonX, y: buttonY), size: CGSize(width: buttonSize, height: buttonSize)))
            buttonView.update(size: CGSize(width: buttonSize, height: buttonSize), image: image, isSelected: isActive, isDestructive: isDestructive, isEnabled: button.isEnabled, title: title, transition: buttonTransition)
            buttonX += buttonSize + buttonSpacing
        }
        
        var removeKeys: [Button.Content.Key] = []
        for (key, buttonView) in self.buttonViews {
            if !buttons.contains(where: { $0.content.key == key }) {
                removeKeys.append(key)
                transition.setScale(view: buttonView, scale: 0.001)
                transition.setAlpha(view: buttonView, alpha: 0.0, completion: { [weak buttonView] _ in
                    buttonView?.removeFromSuperview()
                })
            }
        }
        for key in removeKeys {
            self.buttonViews.removeValue(forKey: key)
        }
        
        return resultHeight
    }
}
