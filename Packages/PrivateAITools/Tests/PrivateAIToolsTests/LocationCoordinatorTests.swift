import CoreLocation
import Foundation
import LLMCore
import Testing
@testable import PrivateAITools

@MainActor
@Suite("Location Coordinator State Contracts")
struct LocationCoordinatorTests {
    @Test("delegate diagnostics retain the originating request outside task-local scope")
    func delegateDiagnostics() async {
        let manager = LocationManagerStub(status: .notDetermined)
        let events = AsyncStream<String>.makeStream()
        let coordinator = ToolDiagnostics.$handler.withValue({ event in
            events.continuation.yield(event.event)
            events.continuation.finish()
        }) {
            LocationCoordinator(manager: manager)
        }
        #expect(ToolDiagnostics.handler == nil)
        coordinator.authorizationChanged(to: .authorizedAlways)
        var iterator = events.stream.makeAsyncIterator()
        #expect(await iterator.next() == "apple.location.authorization.changed")
        #expect(manager.starts == 0)
    }

    @Test("an unanswered authorization request is not reported as a location fix timeout")
    func authorizationTimeout() async {
        let manager = LocationManagerStub(status: .notDetermined)
        let coordinator = LocationCoordinator(manager: manager)
        await #expect(throws: AppleServicesToolError.locationAuthorizationTimedOut) {
            _ = try await coordinator.currentLocation(timeout: .milliseconds(20))
        }
        #expect(manager.authorizationRequests == 1)
        #expect(manager.starts == 0)
        #expect(manager.stops == 1)
    }

    @Test("an authorized request with no coordinates reports a location fix timeout")
    func fixTimeout() async {
        let manager = LocationManagerStub(status: .authorizedAlways)
        let coordinator = LocationCoordinator(manager: manager)
        await #expect(throws: AppleServicesToolError.locationTimedOut) {
            _ = try await coordinator.currentLocation(timeout: .milliseconds(20))
        }
        #expect(manager.authorizationRequests == 0)
        #expect(manager.starts == 1)
        #expect(manager.stops == 1)
    }

    @Test("authorization starts updates and valid coordinates finish exactly once")
    func authorizedFix() async throws {
        let manager = LocationManagerStub(status: .notDetermined)
        let coordinator = LocationCoordinator(manager: manager)
        let location = CLLocation(latitude: 0, longitude: 0)
        manager.onAuthorization = {
            coordinator.authorizationChanged(to: .authorizedAlways)
            coordinator.authorizationChanged(to: .authorizedAlways)
            coordinator.receive([location])
            coordinator.receive([location])
        }
        let result = try await coordinator.currentLocation(timeout: .seconds(1))
        #expect(result === location)
        #expect(manager.starts == 1)
        #expect(manager.stops == 1)
    }

    @Test("denied and restricted requests never start location updates")
    func denied() async {
        for status in [CLAuthorizationStatus.denied, .restricted] {
            let manager = LocationManagerStub(status: status)
            let coordinator = LocationCoordinator(manager: manager)
            await #expect(throws: AppleServicesToolError.self) {
                _ = try await coordinator.currentLocation(timeout: .seconds(1))
            }
            #expect(manager.starts == 0)
            #expect(manager.authorizationRequests == 0)
        }
    }

    @Test("cancellation stops an active request without waiting for the timeout")
    func cancellation() async {
        let manager = LocationManagerStub(status: .authorizedAlways)
        let coordinator = LocationCoordinator(manager: manager)
        let task = Task { try await coordinator.currentLocation(timeout: .seconds(30)) }
        await withCheckedContinuation { continuation in
            manager.onStart = { continuation.resume() }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(manager.stops == 1)
    }
}

@MainActor
private final class LocationManagerStub: LocationManaging {
    weak var delegate: (any CLLocationManagerDelegate)?
    let authorizationStatus: CLAuthorizationStatus
    var desiredAccuracy: CLLocationAccuracy = 0
    var authorizationRequests = 0
    var starts = 0
    var stops = 0
    var onAuthorization: (() -> Void)?
    var onStart: (() -> Void)?

    init(status: CLAuthorizationStatus) { authorizationStatus = status }
    func requestWhenInUseAuthorization() {
        authorizationRequests += 1
        onAuthorization?()
    }
    func startUpdatingLocation() {
        starts += 1
        onStart?()
    }
    func stopUpdatingLocation() { stops += 1 }
}