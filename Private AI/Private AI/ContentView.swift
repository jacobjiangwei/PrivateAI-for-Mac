//
//  ContentView.swift
//  Private AI
//
//  Created by jacob on 2026/8/29.
//

import SwiftUI

struct ContentView: View {
    @Bindable var coordinator: ChatCoordinator

    var body: some View {
        NavigationSplitView {
            ConversationSidebar(coordinator: coordinator)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            ChatDetailView(coordinator: coordinator)
        }
        .frame(minWidth: 1_100, minHeight: 680)
    }
}
