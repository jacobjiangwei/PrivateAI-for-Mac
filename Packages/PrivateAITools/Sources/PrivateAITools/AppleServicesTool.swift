import AppKit
import Contacts
import CoreLocation
import EventKit
import Foundation
import LLMCore
import MapKit
import Network
import UserNotifications

public enum AppleServicesToolError: Error, Equatable, LocalizedError, Sendable {
    case authorizationRequired(service: String, status: String)
    case locationUnavailable
    case locationTimedOut
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .authorizationRequired(let service, let status):
            "Authorization for \(service) is required; current status is \(status)."
        case .locationUnavailable:
            "The current location is not available."
        case .locationTimedOut:
            "Timed out while waiting for the current location."
        case .operationFailed(let message):
            message
        }
    }
}

public actor AppleServicesTool: LLMTool {
    public nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: PrivateAIToolPrompts.AppleServices.name,
            description: PrivateAIToolPrompts.AppleServices.tool,
            parameters: objectSchema(
                properties: [
                    "action": stringSchema(
                        description: PrivateAIToolPrompts.AppleServices.action,
                        values: [
                            "device_info", "locale_info", "time_zone", "storage_info",
                            "power_status", "network_status", "authorization_status",
                            "current_location", "search_places", "list_calendars",
                            "list_reminder_lists", "search_contacts",
                            "notification_status", "open_url"
                        ]
                    ),
                    "query": stringSchema(description: PrivateAIToolPrompts.AppleServices.query),
                    "latitude": numberSchema(description: PrivateAIToolPrompts.AppleServices.latitude, range: -90...90),
                    "longitude": numberSchema(description: PrivateAIToolPrompts.AppleServices.longitude, range: -180...180),
                    "radius_meters": integerSchema(description: PrivateAIToolPrompts.AppleServices.radiusMeters, range: 100...50_000),
                    "limit": integerSchema(description: PrivateAIToolPrompts.AppleServices.limit, range: 1...50),
                    "url": stringSchema(description: PrivateAIToolPrompts.AppleServices.url)
                ],
                required: ["action"]
            )
        )
    )

    private let fileManager = FileManager.default

    public init() {}

    public nonisolated func isConcurrencySafe(arguments: [String: JSONValue]) -> Bool {
        switch arguments["action"]?.stringValue {
        case "device_info", "locale_info", "time_zone", "storage_info", "power_status",
             "network_status", "authorization_status", "search_places", "list_calendars",
             "list_reminder_lists", "search_contacts", "notification_status":
            true
        default:
            false
        }
    }

    public func execute(arguments: [String: JSONValue]) async throws -> String {
        let values = CapabilityArguments(values: arguments)
        let action = try values.requiredString("action", maximumBytes: 64)
        let result: JSONValue

        switch action {
        case "device_info":
            try values.requireOnly(["action"])
            result = deviceInfo()
        case "locale_info":
            try values.requireOnly(["action"])
            result = localeInfo()
        case "time_zone":
            try values.requireOnly(["action"])
            result = timeZoneInfo()
        case "storage_info":
            try values.requireOnly(["action"])
            result = try storageInfo()
        case "power_status":
            try values.requireOnly(["action"])
            result = powerStatus()
        case "network_status":
            try values.requireOnly(["action"])
            result = await networkStatus()
        case "authorization_status":
            try values.requireOnly(["action"])
            result = authorizationStatus()
        case "current_location":
            try values.requireOnly(["action"])
            result = try await currentLocation()
        case "search_places":
            try values.requireOnly([
                "action", "query", "latitude", "longitude", "radius_meters", "limit"
            ])
            result = try await searchPlaces(values)
        case "list_calendars":
            try values.requireOnly(["action", "limit"])
            result = try await listCalendars(limit: try values.optionalInteger("limit", range: 1...50) ?? 20)
        case "list_reminder_lists":
            try values.requireOnly(["action", "limit"])
            result = try await listReminderLists(limit: try values.optionalInteger("limit", range: 1...50) ?? 20)
        case "search_contacts":
            try values.requireOnly(["action", "query", "limit"])
            result = try await searchContacts(
                query: try values.requiredString("query", maximumBytes: 512),
                limit: try values.optionalInteger("limit", range: 1...50) ?? 10
            )
        case "notification_status":
            try values.requireOnly(["action"])
            result = await notificationStatus()
        case "open_url":
            try values.requireOnly(["action", "url"])
            result = try await openURL(try values.requiredString("url", maximumBytes: 4_096))
        default:
            throw CapabilityToolError.unsupportedAction(action)
        }

        return try encodeToolResult(result)
    }

    private func deviceInfo() -> JSONValue {
        let process = ProcessInfo.processInfo
        return .object([
            "platform": .string("macOS"),
            "host_name": .string(process.hostName),
            "operating_system": .string(process.operatingSystemVersionString),
            "processor_count": .number(Double(process.processorCount)),
            "active_processor_count": .number(Double(process.activeProcessorCount)),
            "physical_memory_bytes": .number(Double(process.physicalMemory)),
            "thermal_state": .string(thermalStateName(process.thermalState)),
            "low_power_mode": .bool(process.isLowPowerModeEnabled)
        ])
    }

    private func localeInfo() -> JSONValue {
        let locale = Locale.current
        return .object([
            "identifier": .string(locale.identifier),
            "language_code": locale.language.languageCode.map { .string($0.identifier) } ?? .null,
            "region_code": locale.region.map { .string($0.identifier) } ?? .null,
            "measurement_system": .string(locale.measurementSystem.identifier),
            "uses_metric_system": .bool(locale.measurementSystem == .metric),
            "preferred_languages": .array(Locale.preferredLanguages.map(JSONValue.string))
        ])
    }

    private func timeZoneInfo() -> JSONValue {
        let zone = TimeZone.current
        let now = Date()
        return .object([
            "identifier": .string(zone.identifier),
            "abbreviation": zone.abbreviation(for: now).map(JSONValue.string) ?? .null,
            "seconds_from_gmt": .number(Double(zone.secondsFromGMT(for: now))),
            "is_daylight_saving_time": .bool(zone.isDaylightSavingTime(for: now))
        ])
    }

    private func storageInfo() throws -> JSONValue {
        let values = try fileManager.attributesOfFileSystem(forPath: NSHomeDirectory())
        let total = (values[.systemSize] as? NSNumber)?.uint64Value ?? 0
        let free = (values[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        return .object([
            "total_bytes": .number(Double(total)),
            "free_bytes": .number(Double(free)),
            "used_bytes": .number(Double(total - free))
        ])
    }

    private func powerStatus() -> JSONValue {
        let process = ProcessInfo.processInfo
        return .object([
            "low_power_mode": .bool(process.isLowPowerModeEnabled),
            "thermal_state": .string(thermalStateName(process.thermalState))
        ])
    }

    private func networkStatus() async -> JSONValue {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "PrivateAI.AppleServices.NetworkStatus")
        let path: NWPath = await withCheckedContinuation { continuation in
            let state = ContinuationState<NWPath>()
            state.install(continuation)
            monitor.pathUpdateHandler = { path in
                if state.resume(path) {
                    monitor.cancel()
                }
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) {
                if state.resume(monitor.currentPath) {
                    monitor.cancel()
                }
            }
        }
        return .object([
            "status": .string(path.status == .satisfied ? "satisfied" : path.status == .requiresConnection ? "requires_connection" : "unsatisfied"),
            "is_expensive": .bool(path.isExpensive),
            "is_constrained": .bool(path.isConstrained),
            "uses_wifi": .bool(path.usesInterfaceType(NWInterface.InterfaceType.wifi)),
            "uses_wired_ethernet": .bool(path.usesInterfaceType(NWInterface.InterfaceType.wiredEthernet)),
            "uses_cellular": .bool(path.usesInterfaceType(NWInterface.InterfaceType.cellular))
        ])
    }

    private func authorizationStatus() -> JSONValue {
        .object([
            "location": .string(locationAuthorizationName(CLLocationManager().authorizationStatus)),
            "calendar": .string(eventAuthorizationName(EKEventStore.authorizationStatus(for: .event))),
            "reminders": .string(eventAuthorizationName(EKEventStore.authorizationStatus(for: .reminder))),
            "contacts": .string(contactAuthorizationName(CNContactStore.authorizationStatus(for: .contacts)))
        ])
    }

    @MainActor
    private func currentLocation() async throws -> JSONValue {
        let location = try await currentLocationFromSystem()
        var result: [String: JSONValue] = [
            "latitude": .number(location.coordinate.latitude),
            "longitude": .number(location.coordinate.longitude),
            "altitude_meters": .number(location.altitude),
            "horizontal_accuracy_meters": .number(location.horizontalAccuracy),
            "timestamp": .string(location.timestamp.ISO8601Format())
        ]

        await ToolDiagnostics.record("apple.location.reverse_geocoding.started")
        do {
            let place = try await reverseGeocodedPlace(for: location)
            result["place"] = .object(place)
            await ToolDiagnostics.record("apple.location.reverse_geocoding.finished", data: [
                "city": place["city"]?.stringValue ?? "",
                "formatted_address": place["formatted_address"]?.stringValue ?? ""
            ])
        } catch {
            result["place"] = .null
            result["geocoding_error"] = .string(error.localizedDescription)
            await ToolDiagnostics.record(
                "apple.location.reverse_geocoding.failed",
                level: "warning",
                data: ["error": error.localizedDescription]
            )
        }
        return .object(result)
    }

    private func searchPlaces(_ values: CapabilityArguments) async throws -> JSONValue {
        let latitude = try values.optionalNumber("latitude", range: -90...90)
        let longitude = try values.optionalNumber("longitude", range: -180...180)
        guard (latitude == nil) == (longitude == nil) else {
            throw CapabilityToolError.invalidArgument("latitude/longitude")
        }
        let query = try values.requiredString("query", maximumBytes: 1_024)
        let region: MKCoordinateRegion? = try {
            guard let latitude, let longitude else { return nil }
            let radius = Double(try values.optionalInteger("radius_meters", range: 100...50_000) ?? 5_000)
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                latitudinalMeters: radius * 2,
                longitudinalMeters: radius * 2
            )
        }()
        await ToolDiagnostics.record("apple.mapkit.search.started")
        let response = try await retryingOnTransientNetworkError(
            deadline: .seconds(30),
            operation: "search_places"
        ) {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            if let region { request.region = region }
            return try await MKLocalSearch(request: request).start()
        }
        let limit = try values.optionalInteger("limit", range: 1...50) ?? 10
        let places = response.mapItems.prefix(limit).map { item in
            JSONValue.object([
                "name": item.name.map(JSONValue.string) ?? .null,
                "address": item.placemark.title.map(JSONValue.string) ?? .null,
                "latitude": .number(item.placemark.coordinate.latitude),
                "longitude": .number(item.placemark.coordinate.longitude),
                "phone": item.phoneNumber.map(JSONValue.string) ?? .null,
                "url": item.url.map { .string($0.absoluteString) } ?? .null
            ])
        }
        await ToolDiagnostics.record("apple.mapkit.search.finished", data: [
            "count": String(places.count)
        ])
        return .object(["places": .array(Array(places))])
    }

    private func listCalendars(limit: Int) async throws -> JSONValue {
        let store = EKEventStore()
        var status = EKEventStore.authorizationStatus(for: .event)
        await ToolDiagnostics.record("apple.calendar.authorization.checked", data: [
            "status": eventAuthorizationName(status)
        ])
        if status == .notDetermined {
            await ToolDiagnostics.record("apple.calendar.authorization.requested")
            let granted = try await store.requestFullAccessToEvents()
            status = EKEventStore.authorizationStatus(for: .event)
            await ToolDiagnostics.record("apple.calendar.authorization.completed", data: [
                "granted": String(granted),
                "status": eventAuthorizationName(status)
            ])
        }
        guard status == .fullAccess else {
            throw AppleServicesToolError.authorizationRequired(service: "calendar", status: eventAuthorizationName(status))
        }
        let calendars = store.calendars(for: .event).prefix(limit).map { calendar in
            JSONValue.object([
                "id": .string(calendar.calendarIdentifier),
                "title": .string(calendar.title),
                "source": .string(calendar.source.title),
                "allows_modifications": .bool(calendar.allowsContentModifications)
            ])
        }
        return .object(["calendars": .array(Array(calendars))])
    }

    private func listReminderLists(limit: Int) async throws -> JSONValue {
        let store = EKEventStore()
        var status = EKEventStore.authorizationStatus(for: .reminder)
        await ToolDiagnostics.record("apple.reminders.authorization.checked", data: [
            "status": eventAuthorizationName(status)
        ])
        if status == .notDetermined {
            await ToolDiagnostics.record("apple.reminders.authorization.requested")
            let granted = try await store.requestFullAccessToReminders()
            status = EKEventStore.authorizationStatus(for: .reminder)
            await ToolDiagnostics.record("apple.reminders.authorization.completed", data: [
                "granted": String(granted),
                "status": eventAuthorizationName(status)
            ])
        }
        guard status == .fullAccess else {
            throw AppleServicesToolError.authorizationRequired(service: "reminders", status: eventAuthorizationName(status))
        }
        let calendars = store.calendars(for: .reminder).prefix(limit).map { calendar in
            JSONValue.object([
                "id": .string(calendar.calendarIdentifier),
                "title": .string(calendar.title),
                "source": .string(calendar.source.title),
                "allows_modifications": .bool(calendar.allowsContentModifications)
            ])
        }
        return .object(["reminder_lists": .array(Array(calendars))])
    }

    private func searchContacts(query: String, limit: Int) async throws -> JSONValue {
        let store = CNContactStore()
        var status = CNContactStore.authorizationStatus(for: .contacts)
        await ToolDiagnostics.record("apple.contacts.authorization.checked", data: [
            "status": contactAuthorizationName(status)
        ])
        if status == .notDetermined {
            await ToolDiagnostics.record("apple.contacts.authorization.requested")
            let granted = try await store.requestAccess(for: .contacts)
            status = CNContactStore.authorizationStatus(for: .contacts)
            await ToolDiagnostics.record("apple.contacts.authorization.completed", data: [
                "granted": String(granted),
                "status": contactAuthorizationName(status)
            ])
        }
        guard status == .authorized else {
            throw AppleServicesToolError.authorizationRequired(service: "contacts", status: contactAuthorizationName(status))
        }
        let request = CNContactFetchRequest(keysToFetch: [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ])
        let normalizedQuery = query.localizedLowercase
        var contacts: [JSONValue] = []
        try store.enumerateContacts(with: request) { contact, stop in
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let searchable = "\(name) \(contact.organizationName)".localizedLowercase
            guard searchable.contains(normalizedQuery) else {
                return
            }
            contacts.append(.object([
                "name": .string(name),
                "organization": .string(contact.organizationName),
                "emails": .array(contact.emailAddresses.map { .string($0.value as String) }),
                "phone_numbers": .array(contact.phoneNumbers.map { .string($0.value.stringValue) })
            ]))
            if contacts.count >= limit {
                stop.pointee = true
            }
        }
        return .object(["contacts": .array(contacts)])
    }

    private func notificationStatus() async -> JSONValue {
        guard Bundle.main.bundleIdentifier != nil else {
            return .object([
                "available": .bool(false),
                "reason": .string("notification status requires an application bundle")
            ])
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return .object([
            "available": .bool(true),
            "authorization": .string(notificationAuthorizationName(settings.authorizationStatus)),
            "alert_setting": .string(notificationSettingName(settings.alertSetting)),
            "badge_setting": .string(notificationSettingName(settings.badgeSetting)),
            "sound_setting": .string(notificationSettingName(settings.soundSetting))
        ])
    }

    @MainActor
    private func openURL(_ rawURL: String) throws -> JSONValue {
        guard let url = URL(string: rawURL), url.scheme?.lowercased() == "https" else {
            throw CapabilityToolError.invalidArgument("url")
        }
        let opened = NSWorkspace.shared.open(url)
        guard opened else {
            throw AppleServicesToolError.operationFailed("macOS could not open the URL.")
        }
        return .object(["opened": .bool(true), "url": .string(url.absoluteString)])
    }
}

private final class ContinuationState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var value: Value?

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if let value {
            self.value = nil
            continuation.resume(returning: value)
        } else {
            self.continuation = continuation
        }
    }

    func resume(_ value: Value) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else {
            if self.value == nil {
                self.value = value
                return true
            }
            return false
        }
        self.continuation = nil
        continuation.resume(returning: value)
        return true
    }
}

private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
}

private func locationAuthorizationName(_ status: CLAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: "not_determined"
    case .restricted: "restricted"
    case .denied: "denied"
    case .authorizedAlways: "authorized_always"
    case .authorized: "authorized"
    @unknown default: "unknown"
    }
}

private func optionalStringValue(_ value: String?) -> JSONValue {
    guard let value, !value.isEmpty else { return .null }
    return .string(value)
}

private func uniqueNonEmpty(_ values: [String?]) -> [String] {
    var seen: Set<String> = []
    return values.compactMap { value in
        guard let value, !value.isEmpty, seen.insert(value).inserted else { return nil }
        return value
    }
}

@MainActor
private func currentLocationFromSystem() async throws -> CLLocation {
    let coordinator = LocationCoordinator()
    defer { coordinator.stop() }
    return try await coordinator.currentLocation(timeout: .seconds(30))
}

/// Bridges CLLocationManager's continuous-update delegate callbacks to async/await.
/// Uses startUpdatingLocation because single-shot requestLocation gives up with the
/// transient kCLErrorLocationUnknown (code 0) when no cached fix exists yet.
@MainActor
private final class LocationCoordinator: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var started = false

    override init() {
        super.init()
        manager.delegate = self
    }

    func currentLocation(timeout: Duration) async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(.failure(AppleServicesToolError.locationTimedOut))
            }
            let status = manager.authorizationStatus
            Task { await ToolDiagnostics.record("apple.location.authorization.checked", data: [
                "status": locationAuthorizationName(status)
            ]) }
            switch status {
            case .denied, .restricted:
                finish(.failure(AppleServicesToolError.authorizationRequired(
                    service: "location",
                    status: locationAuthorizationName(status)
                )))
            case .notDetermined:
                Task { await ToolDiagnostics.record("apple.location.authorization.requested") }
                manager.requestWhenInUseAuthorization()
            case .authorized, .authorizedAlways:
                beginUpdating()
            @unknown default:
                finish(.failure(AppleServicesToolError.authorizationRequired(
                    service: "location",
                    status: locationAuthorizationName(status)
                )))
            }
        }
    }

    func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        manager.stopUpdatingLocation()
        continuation = nil
    }

    private func beginUpdating() {
        guard !started else { return }
        started = true
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        Task { await ToolDiagnostics.record("apple.location.request.started", data: [
            "mode": "continuous_updates"
        ]) }
        manager.startUpdatingLocation()
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        manager.stopUpdatingLocation()
        continuation.resume(with: result)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { await ToolDiagnostics.record("apple.location.authorization.changed", data: [
            "status": locationAuthorizationName(status)
        ]) }
        guard continuation != nil else { return }
        switch status {
        case .authorized, .authorizedAlways:
            beginUpdating()
        case .denied, .restricted:
            finish(.failure(AppleServicesToolError.authorizationRequired(
                service: "location",
                status: locationAuthorizationName(status)
            )))
        case .notDetermined:
            break
        @unknown default:
            finish(.failure(AppleServicesToolError.authorizationRequired(
                service: "location",
                status: locationAuthorizationName(status)
            )))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else {
            Task { await ToolDiagnostics.record(
                "apple.location.request.waiting",
                level: "warning",
                data: ["reason": "invalid_fix"]
            ) }
            return
        }
        Task { await ToolDiagnostics.record("apple.location.locations.received", data: [
            "horizontal_accuracy_meters": String(location.horizontalAccuracy)
        ]) }
        finish(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let nsError = error as NSError
        // kCLErrorLocationUnknown (code 0) is transient: CoreLocation keeps trying,
        // so keep updating instead of failing the request.
        if nsError.domain == kCLErrorDomain, nsError.code == CLError.locationUnknown.rawValue {
            Task { await ToolDiagnostics.record(
                "apple.location.request.waiting",
                level: "warning",
                data: ["reason": "location_unknown_transient"]
            ) }
            return
        }
        Task { await ToolDiagnostics.record(
            "apple.location.request.failed",
            level: "error",
            data: ["domain": nsError.domain, "code": String(nsError.code)]
        ) }
        finish(.failure(AppleServicesToolError.locationUnavailable))
    }
}

// A timed-out MapKit/CoreLocation network request is transient (the link to
// Apple's map service dropped this attempt); like continuous location updates,
// keep issuing fresh requests until one succeeds or the overall deadline passes.
private func isTransientNetworkError(_ error: Error) -> Bool {
    let nsError = error as NSError
    switch nsError.domain {
    case NSURLErrorDomain:
        return nsError.code == NSURLErrorTimedOut
            || nsError.code == NSURLErrorNetworkConnectionLost
            || nsError.code == NSURLErrorNotConnectedToInternet
            || nsError.code == NSURLErrorCannotConnectToHost
    case MKError.errorDomain:
        return nsError.code == MKError.loadingThrottled.rawValue
            || nsError.code == MKError.serverFailure.rawValue
            || nsError.code == MKError.unknown.rawValue
    case kCLErrorDomain:
        return nsError.code == CLError.network.rawValue
    default:
        // "The request timed out." surfaces from lower layers with varying
        // domains; treat any timeout-shaped error as transient.
        return nsError.localizedDescription.localizedCaseInsensitiveContains("timed out")
    }
}

private func retryingOnTransientNetworkError<Result>(
    isolation: isolated (any Actor)? = #isolation,
    deadline: Duration,
    operation: String,
    _ body: () async throws -> Result
) async throws -> Result {
    let start = ContinuousClock.now
    var attempt = 0
    while true {
        attempt += 1
        do {
            return try await body()
        } catch {
            let elapsed = ContinuousClock.now - start
            guard isTransientNetworkError(error), elapsed < deadline else { throw error }
            await ToolDiagnostics.record(
                "apple.mapkit.retrying",
                level: "warning",
                data: [
                    "operation": operation,
                    "attempt": String(attempt),
                    "error": error.localizedDescription
                ]
            )
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}

@MainActor
private func reverseGeocodedPlace(for location: CLLocation) async throws -> [String: JSONValue] {
    if #available(macOS 26.0, *) {
        return try await modernReverseGeocodedPlace(for: location)
    }
    return try await legacyReverseGeocodedPlace(for: location)
}

// `MKReverseGeocodingRequest` and its `[MKMapItem]` result are non-Sendable, and
// `mapItems` is a `nonisolated async` property. Perform the whole request in a
// single nonisolated context so those non-Sendable values never cross an actor
// boundary; only the fully-formed, Sendable dictionary leaves this function.
@available(macOS 26.0, *)
private func modernReverseGeocodedPlace(for location: CLLocation) async throws -> [String: JSONValue] {
    guard let request = MKReverseGeocodingRequest(location: location) else {
        throw AppleServicesToolError.operationFailed(
            "MapKit could not create a reverse-geocoding request."
        )
    }
    request.preferredLocale = Locale.current

    let start = ContinuousClock.now
    let deadline: Duration = .seconds(30)
    var attempt = 0
    while true {
        attempt += 1
        do {
            guard let firstItem = try await request.mapItems.first else {
                throw AppleServicesToolError.operationFailed(
                    "MapKit returned no address for the current coordinate."
                )
            }
            let representations = firstItem.addressRepresentations
            return [
                "city": optionalStringValue(representations?.cityName),
                "city_with_context": optionalStringValue(representations?.cityWithContext),
                "country_or_region": optionalStringValue(representations?.regionName),
                "formatted_address": optionalStringValue(firstItem.address?.fullAddress),
                "short_address": optionalStringValue(firstItem.address?.shortAddress),
                "time_zone": optionalStringValue(firstItem.timeZone?.identifier)
            ]
        } catch {
            let elapsed = ContinuousClock.now - start
            guard isTransientNetworkError(error), elapsed < deadline else { throw error }
            await ToolDiagnostics.record(
                "apple.mapkit.retrying",
                level: "warning",
                data: [
                    "operation": "reverse_geocoding",
                    "attempt": String(attempt),
                    "error": error.localizedDescription
                ]
            )
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}

@available(macOS, introduced: 14.0, obsoleted: 26.0)
@MainActor
private func legacyReverseGeocodedPlace(for location: CLLocation) async throws -> [String: JSONValue] {
    guard let placemark = try await CLGeocoder().reverseGeocodeLocation(
        location,
        preferredLocale: Locale.current
    ).first else {
        throw AppleServicesToolError.operationFailed(
            "Core Location returned no address for the current coordinate."
        )
    }
    let district = placemark.subAdministrativeArea ?? placemark.subLocality
    let formattedAddress = uniqueNonEmpty([
        placemark.country,
        placemark.administrativeArea,
        placemark.locality,
        district,
        placemark.thoroughfare,
        placemark.subThoroughfare
    ]).joined(separator: ", ")
    return [
        "country_or_region": optionalStringValue(placemark.country),
        "province": optionalStringValue(placemark.administrativeArea),
        "city": optionalStringValue(placemark.locality),
        "district": optionalStringValue(district),
        "sub_locality": optionalStringValue(placemark.subLocality),
        "formatted_address": optionalStringValue(formattedAddress),
        "time_zone": optionalStringValue(placemark.timeZone?.identifier)
    ]
}

private func eventAuthorizationName(_ status: EKAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: "not_determined"
    case .restricted: "restricted"
    case .denied: "denied"
    case .fullAccess: "full_access"
    case .writeOnly: "write_only"
    case .authorized: "authorized"
    @unknown default: "unknown"
    }
}

private func contactAuthorizationName(_ status: CNAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: "not_determined"
    case .restricted: "restricted"
    case .denied: "denied"
    case .authorized: "authorized"
    case .limited: "limited"
    @unknown default: "unknown"
    }
}

private func notificationAuthorizationName(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: "not_determined"
    case .denied: "denied"
    case .authorized: "authorized"
    case .provisional: "provisional"
    case .ephemeral: "ephemeral"
    @unknown default: "unknown"
    }
}

private func notificationSettingName(_ setting: UNNotificationSetting) -> String {
    switch setting {
    case .notSupported: "not_supported"
    case .disabled: "disabled"
    case .enabled: "enabled"
    @unknown default: "unknown"
    }
}