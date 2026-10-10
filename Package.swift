// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenIsland",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenIsland", targets: ["OpenIsland"]),
    ],
    targets: [
        // Saf mantık katmanı: AppKit'e bağımlı değil, birim testleriyle doğrulanır.
        .target(name: "IslandCore"),

        // Uygulama katmanı: pencere yönetimi, SwiftUI, sistem servisleri.
        .executableTarget(
            name: "OpenIsland",
            dependencies: ["IslandCore"],
            linkerSettings: [
                // Info.plist binary'nin __TEXT,__info_plist bölümüne gömülür; böylece `swift run`
                // ile paketlenmemiş çalıştırmada da TCC kullanım açıklamaları okunabilir.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Support/Info.plist",
                ]),
            ]
        ),

        .testTarget(name: "IslandCoreTests", dependencies: ["IslandCore"]),
    ]
)
