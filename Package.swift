// swift-tools-version:5.9
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import PackageDescription

// DocumentToolScaffold (PDD_dokumentverktoy_2026-11-18).
// `DocumentTools` reads docx, pdf, md, rtf and txt into one paragraph format, numbers paragraphs stably across versions
// and prepares model-ready text. It depends only on Foundation, FoundationXML and ZIPFoundation.
// `DocumentToolCells` puts the library behind the CellProtocol cell `cell:///DocumentTools`. CellProtocol is pinned to the
// same revision as CellScaffold, so CellScaffold can register the cell without moving its own pin.
let package = Package(
    name: "DocumentToolScaffold",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "DocumentTools", targets: ["DocumentTools"]),
        .library(name: "DocumentToolCells", targets: ["DocumentToolCells"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/Digipomps/CellProtocol.git", revision: "1632ed65d5e4aaf663b26cee1cdddfdcdd5e4412"),
        // Test support only: the copied MockIdentityVault signs with Crypto on Linux, and flows use OpenCombine there.
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0" ..< "4.0.0"),
        .package(url: "https://github.com/OpenCombine/OpenCombine.git", from: "0.13.0"),
        // swift-nio-ssl 2.37.6 dropped the CNIOBoringSSL_ prefix header from its umbrella header, and random-swift 1.0.0
        // (used by CellBase) calls CNIOBoringSSL_RAND_bytes. Held below 2.37.6, the same as CellScaffold (2.37.5).
        .package(url: "https://github.com/apple/swift-nio-ssl.git", "2.37.2" ..< "2.37.6"),
    ],
    targets: [
        .target(
            name: "DocumentTools",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .target(
            name: "DocumentToolCells",
            dependencies: [
                "DocumentTools",
                .product(name: "CellBase", package: "CellProtocol"),
            ]
        ),
        .testTarget(
            name: "DocumentToolsTests",
            dependencies: ["DocumentTools"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "DocumentToolCellsTests",
            dependencies: [
                "DocumentToolCells",
                "DocumentTools",
                .product(name: "CellBase", package: "CellProtocol"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
                .product(name: "OpenCombine", package: "OpenCombine", condition: .when(platforms: [.linux])),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
    ]
)
