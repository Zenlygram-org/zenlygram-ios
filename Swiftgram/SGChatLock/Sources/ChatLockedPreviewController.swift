import Foundation
import UIKit
import Display
import AsyncDisplayKit

// A minimal preview shown INSTEAD of a locked chat's content in the chat-list
// long-press peek. Renders just a lock glyph on the themed background — never any
// messages or shared media of the locked chat.
public final class ChatLockedPreviewController: ViewController {
    private let bgColor: UIColor
    private let tintColor: UIColor

    public init(backgroundColor: UIColor, tintColor: UIColor) {
        self.bgColor = backgroundColor
        self.tintColor = tintColor
        super.init(navigationBarPresentationData: nil)
        self.preferredContentSize = CGSize(width: 260.0, height: 260.0)
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    public override func loadDisplayNode() {
        self.displayNode = ChatLockedPreviewControllerNode(backgroundColor: self.bgColor, tintColor: self.tintColor)
        self.displayNodeDidLoad()
    }

    public override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        (self.displayNode as? ChatLockedPreviewControllerNode)?.updateLayout(size: layout.size)
    }
}

private final class ChatLockedPreviewControllerNode: ViewControllerTracingNode {
    private let iconNode: ASImageNode

    init(backgroundColor: UIColor, tintColor: UIColor) {
        self.iconNode = ASImageNode()
        self.iconNode.displaysAsynchronously = false
        self.iconNode.contentMode = .center
        if #available(iOS 13.0, *) {
            let cfg = UIImage.SymbolConfiguration(pointSize: 64.0, weight: .regular)
            self.iconNode.image = UIImage(systemName: "lock.fill", withConfiguration: cfg)?.withTintColor(tintColor, renderingMode: .alwaysOriginal)
        }
        super.init()
        self.backgroundColor = backgroundColor
        self.addSubnode(self.iconNode)
    }

    func updateLayout(size: CGSize) {
        let iconSize = self.iconNode.image?.size ?? CGSize(width: 64.0, height: 64.0)
        self.iconNode.frame = CGRect(origin: CGPoint(x: floor((size.width - iconSize.width) / 2.0), y: floor((size.height - iconSize.height) / 2.0)), size: iconSize)
    }
}
