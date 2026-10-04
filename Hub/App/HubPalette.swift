import SwiftUI
import UIKit

/// 画面の面だけを揃える。ライトの既存色とシステムの文字色は維持する。
enum HubPalette {
    static var canvas: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 23.0/255, green: 30.0/255, blue: 35.0/255, alpha: 1)
                : UIColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1)
        })
    }
    static var card: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 36.0/255, green: 45.0/255, blue: 52.0/255, alpha: 1)
                : .secondarySystemGroupedBackground
        })
    }
    static var tab: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 27.0/255, green: 35.0/255, blue: 40.0/255, alpha: 1)
                : .systemBackground
        })
    }
}
