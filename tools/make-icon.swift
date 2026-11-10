// Masks the opaque concept icon to a transparent rounded square. Usage: make-icon.swift in.png out.png
import AppKit
let a = CommandLine.arguments
let src = NSImage(contentsOfFile: a[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let s = CGFloat(src.width) / 1024
let crop = src.cropping(to: CGRect(x: 106 * s, y: 104 * s, width: 812 * s, height: 816 * s))!
let n = 824, pad: CGFloat = 0
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let r = CGRect(x: 100 + pad, y: 100, width: CGFloat(n), height: CGFloat(n))
ctx.addPath(CGPath(roundedRect: r, cornerWidth: 185, cornerHeight: 185, transform: nil)); ctx.clip()
ctx.draw(crop, in: r)
try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
