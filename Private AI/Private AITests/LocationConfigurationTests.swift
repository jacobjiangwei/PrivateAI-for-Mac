import Foundation
import Testing

@Suite("Location Authorization Configuration")
struct LocationConfigurationTests {
    @Test("host App declares both macOS and when-in-use location purposes")
    func usageDescriptions() {
        for key in ["NSLocationUsageDescription", "NSLocationWhenInUseUsageDescription"] {
            let description = Bundle.main.object(forInfoDictionaryKey: key) as? String
            #expect(description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
    }
}