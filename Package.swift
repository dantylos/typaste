// swift-tools-version: 6.2
import PackageDescription

// Зависимости закреплены точными версиями (SPEC §1: не main, не диапазоны).
// Транзитивные (mlx-swift и др.) фиксируются Package.resolved — он обязателен в git.
let package = Package(
    name: "LocalType",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ModelSpike", targets: ["ModelSpike"]),
        .executable(name: "AXProbe", targets: ["AXProbe"]),
        .executable(name: "LocalType", targets: ["LocalType"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5"),
    ],
    targets: [
        // Этап 0 (SPEC §13): проверка загрузки Qwen3-1.7B-Base 4-bit через MLX Swift.
        .executableTarget(
            name: "ModelSpike",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/ModelSpike"
        ),
        // Этап 0, шаг 0.3: проба AX (чтение, диапазоны UTF-16, caretRect, вставка, Undo).
        .executableTarget(
            name: "AXProbe",
            path: "Sources/AXProbe",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
            ]
        ),
        // Фаза 1: вертикальный срез LocalType (Menu Bar + AX NativeAdapter + Qwen3 Metal + Floating Overlay + EventTap).
        .executableTarget(
            name: "LocalType",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/LocalType",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
            ]
        ),
        // Юнит-тесты логики подсказок + интеграционные проверки модели (Metal).
        .testTarget(
            name: "LocalTypeTests",
            dependencies: ["LocalType"],
            path: "Tests/LocalTypeTests"
        ),
    ]
)
