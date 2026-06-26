//
//  DIPULBrokenLayerRegressionTests.swift
//  safeFLYTests
//
//  Regression coverage for the "one broken layer blanks every layer" bug.
//  Historically a single source layer hitting a server-side DB error caused the
//  whole combined WMS request to fail, so no zones rendered at all. The provider
//  must instead drop only the broken layer and keep every other layer working.
//

import XCTest
@testable import safeFLY

final class DIPULBrokenLayerRegressionTests: XCTestCase {

    private let provider = DIPULProvider()

    private let region = MapRegion(
        center: MapCoordinate(latitude: 52.5, longitude: 13.4),
        latitudeDelta: 0.1,
        longitudeDelta: 0.1
    )

    private func renderRequest() -> ProviderRenderRequest {
        ProviderRenderRequest(region: region, viewportSize: MapViewportSize(width: 256, height: 256))
    }

    /// Every dataset reported available, but specific individual layers flagged broken —
    /// the exact shape produced when one layer fails while its siblings keep working.
    private func snapshot(brokenLayerIDs: Set<String>) -> ProviderStatusSnapshot {
        ProviderStatusSnapshot(
            providerStatus: .available,
            datasetStatuses: Dictionary(uniqueKeysWithValues: provider.datasets.map { ($0.id, .available) }),
            brokenLayerIDs: brokenLayerIDs,
            refreshedAt: Date()
        )
    }

    /// Extracts the WMS `layers` parameter from the rendered overlay URL.
    private func requestedLayers(in payloads: [ProviderRenderPayload]) -> Set<String> {
        guard
            case let .wmsImage(payload)? = payloads.first,
            let components = URLComponents(url: payload.imageURL, resolvingAgainstBaseURL: false),
            let layersValue = components.queryItems?.first(where: { $0.name == "layers" })?.value
        else {
            return []
        }

        return Set(layersValue.split(separator: ",").map(String.init))
    }

    // The exact regression: a broken layer inside a multi-layer dataset must not blank
    // out its sibling layers or any other selected dataset.
    func test_renderPayloads_excludesOnlyBrokenLayer_keepingSiblingsAndOtherDatasets() async {
        let payloads = await provider.renderPayloads(
            for: renderRequest(),
            selectedDatasetIDs: ["restricted.government-buildings", "aviation.airports"],
            status: snapshot(brokenLayerIDs: ["dipul:labore"])
        )

        let layers = requestedLayers(in: payloads)

        XCTAssertFalse(payloads.isEmpty, "A single broken layer must not suppress the whole overlay")
        XCTAssertFalse(layers.contains("dipul:labore"), "The broken layer must be excluded")
        XCTAssertTrue(layers.contains("dipul:militaerische_anlagen"), "Sibling layer in the same dataset must still render")
        XCTAssertTrue(layers.contains("dipul:behoerden"), "Sibling layer in the same dataset must still render")
        XCTAssertTrue(layers.contains("dipul:flughaefen"), "An unrelated selected dataset must be unaffected")
    }

    // Sanity check: with nothing broken, all selected layers are present.
    func test_renderPayloads_includesAllLayersWhenNothingBroken() async {
        let payloads = await provider.renderPayloads(
            for: renderRequest(),
            selectedDatasetIDs: ["restricted.government-buildings"],
            status: snapshot(brokenLayerIDs: [])
        )

        let layers = requestedLayers(in: payloads)
        XCTAssertTrue(layers.contains("dipul:labore"))
        XCTAssertTrue(layers.contains("dipul:militaerische_anlagen"))
    }

    // A dataset whose every layer is dead (status == .unavailable) is dropped entirely,
    // while a sibling dataset keeps rendering.
    func test_renderPayloads_dropsFullyUnavailableDataset_keepingOthers() async {
        var datasetStatuses = Dictionary(uniqueKeysWithValues: provider.datasets.map { ($0.id, ProviderAvailabilityStatus.available) })
        datasetStatuses["aviation.airports"] = .unavailable

        let status = ProviderStatusSnapshot(
            providerStatus: .degraded,
            datasetStatuses: datasetStatuses,
            brokenLayerIDs: ["dipul:flughaefen"],
            refreshedAt: Date()
        )

        let payloads = await provider.renderPayloads(
            for: renderRequest(),
            selectedDatasetIDs: ["aviation.airports", "aviation.aerodromes"],
            status: status
        )

        let layers = requestedLayers(in: payloads)
        XCTAssertFalse(layers.contains("dipul:flughaefen"), "Fully-unavailable dataset must be dropped")
        XCTAssertTrue(layers.contains("dipul:flugplaetze"), "Healthy sibling dataset must still render")
    }

    // Snapshots persisted before `brokenLayerIDs` existed must still decode.
    func test_statusSnapshot_decodesLegacyJSONWithoutBrokenLayerIDs() throws {
        let legacyJSON = Data("""
        {
            "providerStatus": "available",
            "datasetStatuses": { "aviation.airports": "available" }
        }
        """.utf8)

        let snapshot = try JSONDecoder().decode(ProviderStatusSnapshot.self, from: legacyJSON)

        XCTAssertEqual(snapshot.brokenLayerIDs, [])
        XCTAssertEqual(snapshot.status(for: "aviation.airports"), .available)
    }

    // The cooldown gate: a fresh snapshot is trusted (broken layers stay hidden, no
    // reprobe), an expired one triggers a background refresh, and providers without
    // status support keep their first snapshot.
    func test_shouldRefreshStatus_respectsCooldown() {
        let now = Date()
        let cooldown: TimeInterval = 12 * 3600

        XCTAssertTrue(
            ProviderSession.shouldRefreshStatus(supportsStatusRefresh: true, refreshedAt: nil, now: now, cooldown: cooldown),
            "A never-probed provider should refresh"
        )
        XCTAssertFalse(
            ProviderSession.shouldRefreshStatus(supportsStatusRefresh: true, refreshedAt: now.addingTimeInterval(-3600), now: now, cooldown: cooldown),
            "A snapshot within the cooldown window should be trusted (broken layers stay hidden)"
        )
        XCTAssertTrue(
            ProviderSession.shouldRefreshStatus(supportsStatusRefresh: true, refreshedAt: now.addingTimeInterval(-13 * 3600), now: now, cooldown: cooldown),
            "A snapshot past the cooldown should refresh in the background"
        )
        XCTAssertFalse(
            ProviderSession.shouldRefreshStatus(supportsStatusRefresh: false, refreshedAt: now.addingTimeInterval(-13 * 3600), now: now, cooldown: cooldown),
            "A provider without status refresh keeps its first snapshot"
        )
    }
}
