//
//  UIScrollView+Extentions.swift
//  Papr
//
//  Created by Joan Disho on 12.02.18.
//  Copyright © 2018 Joan Disho. All rights reserved.
//

import UIKit

extension UIScrollView {
    
    func isNearTheBottomEdge(offset: CGFloat = 100) -> Bool {
        return contentOffset.y + frame.size.height + offset >= contentSize.height
    }
}
