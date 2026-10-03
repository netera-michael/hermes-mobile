import ProjectDescription

// Nonshipping. Generate only inside an isolated, hash-verified candidate.
let project = Project(name: "QueueControlsUI", packages: [.local(path: "../../HermesKit")], targets: [
  .target(name: "QueueControlsUI", destinations: [.iPhone], product: .app,
    bundleId: "local.hermes.queue-controls", deploymentTargets: .iOS("18.0"),
    infoPlist: .extendingDefault(with: ["UILaunchScreen": [:]]),
    sources: ["App.swift",
      "../../HermesMobile/Sources/Features/Chat/QueuedPromptsPanel.swift",
      "../../HermesMobile/Sources/Features/Chat/ComposerView.swift",
      "../../HermesMobile/Sources/Features/Chat/ComposerTextView.swift",
      "../../HermesMobile/Sources/Features/Chat/ContextUsageRing.swift",
      "../../HermesMobile/Sources/Features/Chat/Color+Hermes.swift"],
    dependencies: [.package(product: "HermesKit")]),
  .target(name: "QueueControlsUITests", destinations: [.iPhone], product: .uiTests,
    bundleId: "local.hermes.queue-controls.tests", deploymentTargets: .iOS("18.0"),
    sources: ["Tests.swift"], dependencies: [.target(name: "QueueControlsUI")])
], schemes: [.scheme(name: "QueueControlsUI", shared: true,
  buildAction: .buildAction(targets: ["QueueControlsUI"]),
  testAction: .targets(["QueueControlsUITests"], configuration: "Debug"))])
