import CoreGraphics

extension CGRect {
    /// Kenarlar **dahil** nokta testi (imleç isabeti için).
    ///
    /// `CGRect.contains` yarı açıktır: `maxX` ve `maxY` dışarıda sayılır. Adanın isabet bölgesi ekranın tepesine
    /// kadar uzanır ve imleç ekranın en üst satırındayken `NSEvent.mouseLocation.y` tam `frame.maxY` olur
    /// (ör. 1107,0). `contains` bu noktayı dışarıda sayıyor, hover'da yerleşim değişince yapılan "imleç hâlâ içeride
    /// mi" denetimi sahte bir çıkış üretiyor ve ada açılmıyordu. Ekranın tepesine vurmak (Fitts yasası) en doğal
    /// hareket olduğu için hata "bazen" görünüyordu.
    public func containsInclusive(_ point: CGPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}
