import AppKit
let size=NSSize(width:1024,height:1024)
let image=NSImage(size:size)
image.lockFocus()
let background=NSBezierPath(rect:NSRect(origin:.zero,size:size))
NSGradient(colors:[NSColor(red:0.63,green:0.76,blue:0.91,alpha:1),NSColor(red:0.87,green:0.92,blue:0.98,alpha:1)])!.draw(in:background,angle:90)
for (x,y,r) in [(80.0,120.0,180.0),(270,70,230),(690,75,230),(920,130,220),(800,310,135),(200,290,135)] {
 let path=NSBezierPath(ovalIn:NSRect(x:x-r,y:y-r*0.7,width:r*2,height:r*1.4))
 NSGradient(colors:[NSColor(red:0.74,green:0.81,blue:0.93,alpha:1),.white])!.draw(in:path,angle:70)
}
let shadow=NSShadow();shadow.shadowColor=NSColor(red:0.10,green:0.19,blue:0.34,alpha:0.26);shadow.shadowBlurRadius=45;shadow.shadowOffset=NSSize(width:0,height:-35);shadow.set()
NSColor(red:0.09,green:0.17,blue:0.29,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:186,y:267,width:652,height:545),xRadius:75,yRadius:75).fill()
NSShadow().set()
NSColor(red:0.97,green:0.95,blue:0.87,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:202,y:291,width:620,height:510),xRadius:62,yRadius:62).fill()
for rank in 0..<4 {for file in 0..<4 {
 let color=(rank+file)%2==0 ? NSColor(red:0.13,green:0.24,blue:0.39,alpha:1):NSColor(red:0.94,green:0.95,blue:0.92,alpha:1)
 color.setFill();NSBezierPath(rect:NSRect(x:240+file*136,y:330+rank*106,width:136,height:106)).fill()
}}
let piece=NSBezierPath();piece.move(to:NSPoint(x:420,y:416));piece.curve(to:NSPoint(x:408,y:654),controlPoint1:NSPoint(x:380,y:490),controlPoint2:NSPoint(x:370,y:590));piece.line(to:NSPoint(x:449,y:734));piece.line(to:NSPoint(x:478,y:701));piece.line(to:NSPoint(x:501,y:768));piece.curve(to:NSPoint(x:542,y:686),controlPoint1:NSPoint(x:535,y:745),controlPoint2:NSPoint(x:538,y:716));piece.curve(to:NSPoint(x:631,y:624),controlPoint1:NSPoint(x:570,y:670),controlPoint2:NSPoint(x:596,y:639));piece.line(to:NSPoint(x:642,y:571));piece.curve(to:NSPoint(x:585,y:548),controlPoint1:NSPoint(x:641,y:543),controlPoint2:NSPoint(x:612,y:539));piece.line(to:NSPoint(x:534,y:571));piece.curve(to:NSPoint(x:573,y:416),controlPoint1:NSPoint(x:480,y:510),controlPoint2:NSPoint(x:553,y:481));piece.close()
let pieceShadow=NSShadow();pieceShadow.shadowColor=NSColor.black.withAlphaComponent(0.25);pieceShadow.shadowBlurRadius=19;pieceShadow.shadowOffset=NSSize(width:12,height:-16);pieceShadow.set()
NSGradient(colors:[NSColor(red:0.80,green:0.77,blue:0.67,alpha:1),NSColor(red:1,green:0.97,blue:0.85,alpha:1),.white])!.draw(in:piece,angle:55)
NSShadow().set();NSColor(red:0.66,green:0.48,blue:0.25,alpha:1).setFill();NSBezierPath(ovalIn:NSRect(x:544,y:639,width:15,height:15)).fill()
NSColor(red:0.99,green:0.96,blue:0.86,alpha:1).setFill();NSBezierPath(roundedRect:NSRect(x:390,y:369,width:213,height:51),xRadius:22,yRadius:22).fill()
NSColor(red:0.76,green:0.59,blue:0.34,alpha:1).setFill();NSBezierPath(roundedRect:NSRect(x:394,y:372,width:204,height:9),xRadius:4,yRadius:4).fill()
image.unlockFocus()
let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
