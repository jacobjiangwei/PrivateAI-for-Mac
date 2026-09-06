//
//  Private_AIApp.swift
//  Private AI
//
//  Created by jacob on 2026/8/29.
//

import SwiftUI
import SwiftData

@main
struct Private_AIApp: App {
    private let dependencies: AppDependencies
    @State private var coordinator: ChatCoordinator

    init() {
        do {
            let dependencies = try AppDependencies()
            self.dependencies = dependencies
            _coordinator = State(initialValue: ChatCoordinator(dependencies: dependencies))
        } catch {
            fatalError("Could not initialize PrivateAI: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator)
        }
        .defaultSize(width: 1_440, height: 820)
        .modelContainer(dependencies.container)
    }
}
