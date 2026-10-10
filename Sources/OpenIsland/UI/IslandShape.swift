import Foundation
import IslandCore
import SwiftUI

/// Donanım çentiğinin sıvı gibi uzayan devamı.
///
/// - Gövdenin alt köşeleri Apple'ın **sürekli eğrilik** (squircle) köşeleridir
///   (`UnevenRoundedRectangle(style: .continuous)`); dairesel yay değil.
/// - `notch` stilinde üstteki içbükey "kulaklar" gövdeyle aynı yönde çizilip tek yola alt yol olarak eklenir:
///   dolgu ve kırpma aynı kesintisiz alanı kullanır, dikiş çizgisi oluşmaz (bkz. `path(in:)`).
/// - Boyut ve iki yarıçap aynı yay ile animasyonlanır; köşeler hiçbir karede kopmaz.
struct IslandShape: InsettableShape {
    var style: IslandStyle
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var insetAmount: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func inset(by amount: CGFloat) -> IslandShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard rect.width > 0, rect.height > 0 else { return Path() }

        switch style {
        case .pill:
            let radius = max(min(bottomRadius - insetAmount, rect.height / 2), 0)
            return Path(roundedRect: rect, cornerRadius: radius, style: .continuous)

        case .notch:
            let flare = max(min(topRadius, rect.width / 4), 0)
            let body = CGRect(x: rect.minX + flare, y: rect.minY, width: rect.width - flare * 2, height: rect.height)
            let radius = max(min(bottomRadius - insetAmount, body.height, body.width / 2), 0)
            let bodyPath = UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: radius,
                bottomTrailingRadius: radius, topTrailingRadius: 0,
                style: .continuous
            ).path(in: body)

            // İç (inset) yol yalnızca kenar ışığı içindir; kulaklar menü çubuğunda kalır ve parlamaz.
            guard insetAmount == 0, flare > 0.5 else { return bodyPath }
            let flares = Self.flares(in: rect, radius: flare)
            // Kulaklar gövdeyle aynı yönde çizilir: tek yolun alt yolları olarak eklenince sıfırdan farklı (nonzero)
            // dolgu ve kırpma birleşimle aynı alanı verir. Yön, dikdörtgen boyutundan bağımsızdır; animasyonun her
            // karesinde yolu dolaşmak yerine tek bir örnek için statik olarak belirlenir. `Path.union`
            // (CoreGraphics ClipperLib) her karede ~14 µs, ekleme ~0,9 µs (ölçüm, 175 boyut/yarıçap; piksel farkı
            // yalnızca birleşimin eğrileri çokgene çevirdiği kenar yumuşatmasında, en çok 12/255).
            guard Self.bodyPathUsesPositiveWinding else { return bodyPath.union(flares) }
            var path = bodyPath
            path.addPath(flares)
            return path
        }
    }

    /// UnevenRoundedRectangle'ın kontur yönü boyut ve yarıçaptan bağımsızdır; morf sırasında tekrar hesaplama.
    private static let bodyPathUsesPositiveWinding: Bool = {
        let sample = UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: 16,
            bottomTrailingRadius: 16, topTrailingRadius: 0,
            style: .continuous
        ).path(in: CGRect(x: 0, y: 0, width: 80, height: 60))
        return isPositivelyOriented(sample)
    }()

    /// Yolun uç noktalarından yönü (y aşağı koordinatta saat yönü = pozitif alan). Örnek yol başına bir kez çalışır.
    private static func isPositivelyOriented(_ path: Path) -> Bool {
        var area: CGFloat = 0
        var first: CGPoint?
        var last: CGPoint?
        func step(to point: CGPoint) {
            if let last { area += last.x * point.y - point.x * last.y }
            last = point
        }
        path.forEach { element in
            switch element {
            case .move(let point): first = point; last = point
            case .line(let point): step(to: point)
            case .quadCurve(let point, _): step(to: point)
            case .curve(let point, _, _): step(to: point)
            case .closeSubpath: if let first { step(to: first) }
            }
        }
        return area > 0
    }

    /// Üst köşelerdeki içbükey geçişler. Kübik kontrol noktaları (0,45/0,55) çembersel yaydan
    /// daha yumuşak bir eğrilik geçişi verir; gövdeye 1 pt taşarak birleşimi garanti eder.
    private static func flares(in rect: CGRect, radius r: CGFloat) -> Path {
        var path = Path()
        // Sol
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + r + 1, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + r + 1, y: rect.minY + r))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY + r))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY),
            control1: CGPoint(x: rect.minX + r, y: rect.minY + r * 0.45),
            control2: CGPoint(x: rect.minX + r * 0.55, y: rect.minY)
        )
        path.closeSubpath()
        // Sağ (ayna)
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.minY + r),
            control1: CGPoint(x: rect.maxX - r * 0.55, y: rect.minY),
            control2: CGPoint(x: rect.maxX - r, y: rect.minY + r * 0.45)
        )
        path.addLine(to: CGPoint(x: rect.maxX - r - 1, y: rect.minY + r))
        path.addLine(to: CGPoint(x: rect.maxX - r - 1, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Adanın fiziksel gövdesi: opak #000000 dolgu + yalnızca yükseldiğinde görünen iki katmanlı gölge.
///
/// Notch stilinde hiçbir görünüm yükseltilmez (Revizyon 18): açık ada da çentiğin gölgesiz devamıdır. Gölge
/// yalnızca pill (yüzen kapsül) içindir; notch'ta bir gün kullanılırsa diye **fiziksel çentik bandına** (menü
/// çubuğu yüksekliği) düşmeyecek şekilde maskelenir. Siyah dolgunun kendisi maskelenmez ve opaklığı hiçbir
/// geçişte değişmez.
struct IslandSurface<Surface: InsettableShape>: View {
    let shape: Surface
    let elevation: Double
    /// Notch stilinde çentik yüksekliği; pill stilinde 0 (yüzen kapsül her yönde ayrışabilir).
    var shadowClearance: CGFloat = 0

    /// Gölgenin çizilebildiği pay (ortam gölgesi yarıçapı + ofset).
    private static var bleed: CGFloat { 40 }

    var body: some View {
        ZStack {
            // Yükseltilmeyen notch'ta bu gölge alt ağacı görünmez; shape yolunu her kare yeniden üretme.
            if elevation > 0 {
                shape
                    .fill(IslandPalette.surface)
                    .shadow(color: .black.opacity(IslandElevation.contactOpacity * elevation),
                            radius: IslandElevation.contactRadius, y: IslandElevation.contactOffset)
                    .shadow(color: .black.opacity(IslandElevation.ambientOpacity * elevation),
                            radius: IslandElevation.ambientRadius, y: IslandElevation.ambientOffset)
                    .padding(Self.bleed)
                    .mask {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: Self.bleed + shadowClearance)
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: shadowClearance > 0 ? 8 : 0)
                            Color.black
                        }
                    }
                    .padding(-Self.bleed)
            }
            shape.fill(IslandPalette.surface)
        }
    }
}

/// Cam kenarında kırılan ışık: 0,5 pt, alta doğru belirginleşen gradyan kontur.
/// Üst kenar ekranın kenarına yapıştığı için orada ışık yok; bu yüzden düz bir "border" gibi görünmez.
struct IslandEdgeHighlight<Surface: InsettableShape>: View {
    let shape: Surface
    let intensity: Double


    var body: some View {
        // Sıfır yoğunlukta konturun görünümü yok; gereksiz stroke/path çizimini atla.
        if intensity > 0 {
            shape
                .strokeBorder(IslandEdgeStyle.gradient, lineWidth: 0.5)
                .opacity(intensity)
                .allowsHitTesting(false)
        }
    }
}

/// Morph the path on a fixed canvas instead of proposing a different size to the content every frame.
/// The underlying path, corner physics and center/top anchor are identical to IslandShape.
struct IslandCanvasShape: InsettableShape {
    var surfaceSize: CGSize
    var shape: IslandShape
    var geometryRecorder: SurfaceGeometryRecorder?
    var recordingTopInset: CGFloat = 0

    func recordingGeometry(_ recorder: SurfaceGeometryRecorder?, topInset: CGFloat) -> Self {
        var result = self
        result.geometryRecorder = recorder
        result.recordingTopInset = topInset
        return result
    }

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(surfaceSize.width, surfaceSize.height), shape.animatableData) }
        set {
            surfaceSize = CGSize(width: newValue.first.first, height: newValue.first.second)
            shape.animatableData = newValue.second
        }
    }

    func inset(by amount: CGFloat) -> Self {
        var result = self
        result.shape = shape.inset(by: amount)
        return result
    }

    func path(in rect: CGRect) -> Path {
        let path = shape.path(in: CGRect(x: rect.midX - surfaceSize.width / 2, y: rect.minY,
                                        width: surfaceSize.width, height: surfaceSize.height))
        // Only the filled surface records its actually evaluated contour. Normal rendering has no sink.
        geometryRecorder?.record(path.boundingRect.offsetBy(dx: 0, dy: recordingTopInset))
        return path
    }
}

private enum IslandEdgeStyle {
    static let gradient = LinearGradient(
        stops: [
            .init(color: .white.opacity(0), location: 0),
            .init(color: .white.opacity(0.05), location: 0.45),
            .init(color: .white.opacity(0.15), location: 1),
        ],
        startPoint: .top, endPoint: .bottom
    )

}

/// Diagnostic-only mailbox: Shape evaluation may run off the main thread; no UI invalidation or task.
final class SurfaceGeometryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var rect: CGRect?

    func record(_ value: CGRect) {
        lock.lock()
        rect = value
        lock.unlock()
    }

    func latest() -> CGRect? {
        lock.lock()
        defer { lock.unlock() }
        return rect
    }
}
