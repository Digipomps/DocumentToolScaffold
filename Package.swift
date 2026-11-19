// swift-tools-version:5.9
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import PackageDescription

// DocumentToolScaffold (PDD_dokumentverktoy_2026-11-18).
// `DocumentTools` leser docx, pdf, md, rtf og txt til ett felles avsnittsformat, nummererer avsnittene
// stabilt mellom versjoner og lager modellklar tekst. Biblioteket avhenger bare av Foundation, FoundationXML
// og ZIPFoundation. Cellen (`DocumentToolCells`, WP9) kommer som eget produkt senere.
let package = Package(
    name: "DocumentToolScaffold",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "DocumentTools", targets: ["DocumentTools"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "DocumentTools",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .testTarget(
            name: "DocumentToolsTests",
            dependencies: ["DocumentTools"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
