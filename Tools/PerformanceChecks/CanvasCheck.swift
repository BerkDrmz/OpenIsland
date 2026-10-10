import AppKit
import IslandCore
import SwiftUI

// Value used by the shared environment; the shape and surface implementation are compiled unchanged.
enum MotionStyle { case expressive, natural, reduced }

@main
struct CanvasCheck {
    @MainActor static func main() {
        for style in [IslandStyle.notch, .pill] {
            for size in [CGSize(width: 185, height: 33.4), CGSize(width: 290, height: 33.4),
                         CGSize(width: 384, height: 59.5), CGSize(width: 635, height: 129.5)] {
                let canvas = CGSize(width: 758, height: 240)
                let original = IslandShape(style: style, topRadius: 12, bottomRadius: 16)
                let fixed = IslandCanvasShape(surfaceSize: size, shape: original)
                let expected = original.path(in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
                    .offsetBy(dx: (canvas.width - size.width) / 2, dy: 0)
                let actual = fixed.path(in: CGRect(origin: .zero, size: canvas))
                precondition(actual.boundingRect == expected.boundingRect, "surface bounds changed")
                for y in stride(from: 0.0, through: Double(size.height + 5), by: 2.5) {
                    for x in stride(from: 0.0, through: Double(canvas.width), by: 2.5) {
                        let point = CGPoint(x: x, y: y)
                        precondition(actual.contains(point) == expected.contains(point), "hit-testing changed")
                    }
                }
                let renderer = ImageRenderer(content: fixed.fill(.black).frame(width: canvas.width, height: canvas.height))
                renderer.scale = 2
                let reference = ImageRenderer(content: expected.fill(.black).frame(width: canvas.width, height: canvas.height))
                reference.scale = 2
                let actualPixels = renderer.cgImage!.dataProvider!.data! as Data
                let expectedPixels = reference.cgImage!.dataProvider!.data! as Data
                precondition(actualPixels == expectedPixels, "rendered contour differs from the original surface")
            }
        }
        var shape = IslandCanvasShape(surfaceSize: CGSize(width: 200, height: 34),
                                      shape: IslandShape(style: .notch, topRadius: 4, bottomRadius: 12))
        shape.animatableData = .init(.init(400, 100), .init(14, 20))
        precondition(shape.surfaceSize == CGSize(width: 400, height: 100))
        precondition(shape.shape.topRadius == 14 && shape.shape.bottomRadius == 20)
        print("PASS: fixed canvas paths/hit regions match original notch and pill geometry; intermediate morph values preserve corners/size")
    }
}
