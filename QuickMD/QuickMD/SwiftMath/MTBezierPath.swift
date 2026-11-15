
//
//  Created by Mike Griebling on 2022-12-31.
//  Translated from an Objective-C implementation by 安志钢.
//
//  This software may be modified and distributed under the terms of the
//  MIT license. See the LICENSE file for details.
//

import Foundation

#if os(macOS)

extension MTBezierPath {
    func addLine(to point: CGPoint) {
        self.line(to: point)
    }
}

// QuickMD (#59): upstream declares this on MTView, i.e. on EVERY NSView. A read
// of `textView.backgroundColor` where an optional colour is expected then binds
// to this layer property instead of NSTextView's own (it broke the editor's
// colour tests once the engine was compiled into the test target). The label
// is the only user, so the property lives on the label.
extension MTMathUILabel {
    
    var backgroundColor:MTColor? {
        get {
            MTColor(cgColor: self.layer?.backgroundColor ?? MTColor.clear.cgColor)
        }
        set {
            self.layer?.backgroundColor = MTColor.clear.cgColor
            self.wantsLayer = true
        }
    }
    
}

#endif

