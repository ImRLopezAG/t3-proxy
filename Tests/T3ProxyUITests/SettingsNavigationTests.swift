import Testing
@testable import T3ProxyUI

@Suite @MainActor struct SettingsNavigationTests {
    @Test func connectorLinksOpenInsidePlugins() {
        let router = SettingsRouter()
        router.pane = .connectors
        #expect(router.destination == .plugins)
        #expect(router.pane == .connectors)
        #expect(router.pluginsTab == .connectors)
        router.pane = .plugins
        #expect(router.destination == .plugins)
        for tab in PluginsTab.allCases {
            router.pane = tab.landing
            #expect(router.destination == .plugins)
            #expect(router.pluginsTab == tab)
        }
    }

    @Test func monitoringAndAddAccountRoutesStayReachable() {
        let router = SettingsRouter()
        #expect(router.destination == .dashboard)
        for pane in [SettingsPane.quota, .usage] {
            router.pane = pane
            #expect(router.destination == .dashboard)
        }
        router.pane = .addAccount
        #expect(router.destination == .accounts)
        #expect(router.addingAccount)
        router.addingAccount = false
        #expect(router.pane == .accounts)
    }

    @Test func legacyLinksChooseTheCorrectSettingsTab() {
        let router = SettingsRouter()
        for pane in [SettingsPane.connection, .config, .logs, .system] {
            router.pane = pane
            #expect(router.destination == .settings)
            #expect(router.tab == .hub)
            #expect(router.pane == pane)
        }
        for pane in [SettingsPane.preferences, .notifications, .gettingStarted, .recording] {
            router.pane = pane
            #expect(router.destination == .settings)
            #expect(router.tab == .app)
        }
        router.pane = .t3code
        #expect(router.tab == .t3code)
        router.pane = .routing
        #expect(router.tab == .routing)
        router.pane = .proxyDeck
        #expect(router.tab == .deck)
    }
}
