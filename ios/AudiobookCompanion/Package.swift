// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudiobookPlaybackPolicy",
    products: [
        .library(name: "AudiobookPlaybackPolicy", targets: ["AudiobookPlaybackPolicy"]),
    ],
    targets: [
        .target(
            name: "AudiobookPlaybackPolicy",
            path: "AudiobookCompanion",
            exclude: [
                "AudiobookAPI.swift", "AudiobookCompanionApp.swift", "BookDetailView.swift",
                "CreateBookView.swift", "FixtureCover.png", "Info.plist",
                "KillersWifeCover.png", "LibraryView.swift", "Models.swift", "PlayerModel.swift",
            ],
            sources: ["PlaybackPolicy.swift"]
        ),
        .testTarget(name: "AudiobookPlaybackPolicyTests", dependencies: ["AudiobookPlaybackPolicy"],
                    path: "Tests"),
    ]
)
