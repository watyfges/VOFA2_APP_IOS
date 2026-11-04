//
//  Theme.swift
//  VOFA2Remote
//
//  Shared colours and metrics so the two screens stay visually consistent.
//

import UIKit

enum Theme {
    static let accent = UIColor(red: 0.13, green: 0.55, blue: 0.56, alpha: 1)      // teal
    static let accentSoft = UIColor(red: 0.13, green: 0.55, blue: 0.56, alpha: 0.12)
    static let warning = UIColor(red: 0.85, green: 0.52, blue: 0.10, alpha: 1)
    static let danger = UIColor(red: 0.80, green: 0.25, blue: 0.23, alpha: 1)
    static let success = UIColor(red: 0.20, green: 0.63, blue: 0.38, alpha: 1)

    static let horizontalInset: CGFloat = 16
    static let cardCorner: CGFloat = 12

    static func monoFont(ofSize size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        return base
    }
}
