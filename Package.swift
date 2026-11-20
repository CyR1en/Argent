// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Argent",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "argent-spike", targets: ["ArgentSpike"]),
        .executable(name: "Argent", targets: ["ArgentApp"]),
        .executable(name: "argent-remove", targets: ["ArgentRemoveHelper"]),
    ],
    targets: [
        .target(
            name: "ArgentCore",
            resources: [.copy("Resources")]
        ),
        // ArgentRoll for `--auto`: the frame's automatic aim, measured and resolved as the app does.
        .executableTarget(
            name: "ArgentSpike",
            dependencies: ["ArgentCore", "ArgentRoll"]
        ),
        // A roll on disk: its raw files in capture order and their contact-sheet thumbnails.
        .target(
            name: "ArgentRoll",
            dependencies: ["ArgentCore"]
        ),
        // The Mac app. scripts/build-app.sh wraps the binary into a signed, sandboxed Argent.app.
        .executableTarget(
            name: "ArgentApp",
            dependencies: ["ArgentCore", "ArgentRoll"],
            // The display face.
            resources: [.copy("Resources")]
        ),
        // The process that holds the model Remove runs, so its memory goes back the moment it exits and a develop's gate never
        // counts it (docs/remove-plan.md, section 4.5). scripts/build-app.sh places and signs it beside the app's binary.
        .executableTarget(
            name: "ArgentRemoveHelper",
            dependencies: ["ArgentCore"]
        ),
        // The helper's own suites: its scheduler, loop and fusion against the tensors the conversion recorded, and the folder it
        // serves driven by the app's client.
        .testTarget(
            name: "ArgentRemoveHelperTests",
            dependencies: ["ArgentRemoveHelper", "ArgentRoll"]
        ),
        .testTarget(
            name: "ArgentCoreTests",
            dependencies: ["ArgentCore"],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "ArgentRollTests",
            dependencies: ["ArgentRoll"]
        ),
        .testTarget(
            name: "ArgentAppTests",
            dependencies: ["ArgentApp"]
        ),
        // The Remove tab's suites, in a bundle of their own: every app suite runs on the main actor, and these, which host the
        // inspector and trace selections, moved the moments the older suites wait on a clock for (the clipboard's notice, Option
        // over a canvas) when they ran beside them. The model's Remove suites stay with the app's, whose fixtures they share.
        .testTarget(
            name: "ArgentRemoveTests",
            dependencies: ["ArgentApp"]
        ),
    ]
)
