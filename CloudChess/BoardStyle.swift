import SwiftUI
import UIKit

/// Shared colors for the real board and its icon-only palette previews.
enum BoardStyle:String,CaseIterable,Identifiable {
    case ocean,sage,lavender,rose,sand,slate
    var id:String {rawValue}
    var accessibilityName:String {rawValue.capitalized}
    var dark:UIColor {
        switch self {
        case .ocean:return UIColor(red:0.31,green:0.46,blue:0.58,alpha:1)
        case .sage:return UIColor(red:0.34,green:0.48,blue:0.39,alpha:1)
        case .lavender:return UIColor(red:0.46,green:0.39,blue:0.58,alpha:1)
        case .rose:return UIColor(red:0.58,green:0.37,blue:0.40,alpha:1)
        case .sand:return UIColor(red:0.57,green:0.45,blue:0.32,alpha:1)
        case .slate:return UIColor(red:0.38,green:0.43,blue:0.48,alpha:1)
        }
    }
    var light:UIColor {
        switch self {
        case .ocean:return UIColor(red:0.86,green:0.87,blue:0.84,alpha:1)
        case .sage:return UIColor(red:0.85,green:0.89,blue:0.81,alpha:1)
        case .lavender:return UIColor(red:0.88,green:0.85,blue:0.92,alpha:1)
        case .rose:return UIColor(red:0.92,green:0.85,blue:0.82,alpha:1)
        case .sand:return UIColor(red:0.90,green:0.87,blue:0.79,alpha:1)
        case .slate:return UIColor(red:0.83,green:0.87,blue:0.90,alpha:1)
        }
    }
    var side:UIColor {
        if self == .ocean {return UIColor(red:0.13,green:0.28,blue:0.39,alpha:1)}
        return mix(dark,with:.black,amount:0.25)
    }
    var rim:UIColor {
        if self == .ocean {return UIColor(red:0.85,green:0.91,blue:0.94,alpha:1)}
        return mix(light,with:dark,amount:0.12)
    }
    private func mix(_ a:UIColor,with b:UIColor,amount:CGFloat)->UIColor {
        var ar:CGFloat=0,ag:CGFloat=0,ab:CGFloat=0,br:CGFloat=0,bg:CGFloat=0,bb:CGFloat=0
        a.getRed(&ar,green:&ag,blue:&ab,alpha:nil);b.getRed(&br,green:&bg,blue:&bb,alpha:nil)
        return UIColor(red:ar+(br-ar)*amount,green:ag+(bg-ag)*amount,blue:ab+(bb-ab)*amount,alpha:1)
    }
}

struct BoardStyleSwatch:View {
    let style:BoardStyle
    var body:some View {
        Canvas {context,size in
            for row in 0..<2 {for column in 0..<2 {
                let rect=CGRect(x:CGFloat(column)*size.width/2,y:CGFloat(row)*size.height/2,width:size.width/2,height:size.height/2)
                context.fill(Path(rect),with:.color(Color((row+column)%2==0 ? style.light:style.dark)))
            }}
        }.clipShape(RoundedRectangle(cornerRadius:7))
    }
}
