import XCTest

@MainActor
final class MeshPlannerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchDemoApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-uitest-demo"] + extraArguments
        app.launch()
        return app
    }

    private func roomLabelFrames(in app: XCUIApplication) -> [String: CGRect] {
        let query = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'roomLabel-'"))
        var result: [String: CGRect] = [:]
        for element in query.allElementsBoundByIndex where element.exists {
            result[element.identifier] = element.frame
        }
        return result
    }

    private func assertFramesUnchanged(
        expected: [String: CGRect],
        actual: [String: CGRect],
        context: String,
        tolerance: CGFloat = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(Set(expected.keys), Set(actual.keys), "Room label set changed (\(context))", file: file, line: line)
        for (id, exp) in expected {
            guard let act = actual[id] else { continue }
            XCTAssertEqual(act.origin.x, exp.origin.x, accuracy: tolerance, "\(id) minX changed (\(context))", file: file, line: line)
            XCTAssertEqual(act.origin.y, exp.origin.y, accuracy: tolerance, "\(id) minY changed (\(context))", file: file, line: line)
            XCTAssertEqual(act.size.width, exp.size.width, accuracy: tolerance, "\(id) width changed (\(context))", file: file, line: line)
            XCTAssertEqual(act.size.height, exp.size.height, accuracy: tolerance, "\(id) height changed (\(context))", file: file, line: line)
        }
    }

    // (a) Room label frames unchanged while dragging the probe and while dragging a router.
    func testRoomLabelFramesUnchangedDuringProbeAndRouterDrag() throws {
        let app = launchDemoApp()

        let livingRoomLabel = app.buttons["roomLabel-Living room"]
        XCTAssertTrue(livingRoomLabel.waitForExistence(timeout: 10), "Demo map room labels should appear")

        let probe = app.buttons["probe"]
        let router = app.buttons["router"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        XCTAssertTrue(router.waitForExistence(timeout: 5))

        let baseline = roomLabelFrames(in: app)
        XCTAssertGreaterThanOrEqual(baseline.count, 4, "Expected multiple room labels on the demo map")

        // Drag probe in two steps, checking frames immediately during/between drags and after.
        let probeStartFrame = probe.frame
        let probeCoord1 = probe.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        probeCoord1.press(forDuration: 0.1, thenDragTo: probeCoord1.withOffset(CGVector(dx: 45, dy: -35)))
        assertFramesUnchanged(expected: baseline, actual: roomLabelFrames(in: app), context: "during probe drag step 1")

        let probeCoord2 = probe.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        probeCoord2.press(forDuration: 0.1, thenDragTo: probeCoord2.withOffset(CGVector(dx: 35, dy: -25)))
        assertFramesUnchanged(expected: baseline, actual: roomLabelFrames(in: app), context: "after probe drag")

        let probeMoved = hypot(probe.frame.midX - probeStartFrame.midX, probe.frame.midY - probeStartFrame.midY)
        XCTAssertGreaterThan(probeMoved, 15, "Probe should have moved after drag")

        // Drag router in two steps, checking frames immediately during live recompute and after settling.
        let routerStartFrame = router.frame
        let routerCoord1 = router.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        routerCoord1.press(forDuration: 0.1, thenDragTo: routerCoord1.withOffset(CGVector(dx: -45, dy: -25)))
        assertFramesUnchanged(expected: baseline, actual: roomLabelFrames(in: app), context: "during router drag step 1")

        let routerCoord2 = router.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        routerCoord2.press(forDuration: 0.1, thenDragTo: routerCoord2.withOffset(CGVector(dx: -25, dy: 20)))
        assertFramesUnchanged(expected: baseline, actual: roomLabelFrames(in: app), context: "after router drag")

        let routerMoved = hypot(router.frame.midX - routerStartFrame.midX, router.frame.midY - routerStartFrame.midY)
        XCTAssertGreaterThan(routerMoved, 15, "Router should have moved after drag")
    }

    // (b) Fake scan failure while room warning or cancel confirmation dialog is open shows 'Couldn't finish' alert, and Cancel stays tappable/usable.
    func testFakeScanFailureWhileWarningOrCancelDialogOpen() throws {
        let app = launchDemoApp(extraArguments: ["-uitest-fake-scan-failure"])

        let backButton = app.buttons["backToProjects"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 10))
        backButton.tap()

        let scanButton = app.buttons["scan"]
        XCTAssertTrue(scanButton.waitForExistence(timeout: 5))

        // Path 1: Fake scan failure while cancel confirmation dialog ("Discard this scan?") is open.
        scanButton.tap()
        let cancelScanButton = app.buttons["scanCancel"]
        XCTAssertTrue(cancelScanButton.waitForExistence(timeout: 5))
        XCTAssertTrue(cancelScanButton.isHittable)
        cancelScanButton.tap()

        let discardDialogButton = app.buttons["Discard"]
        XCTAssertTrue(discardDialogButton.waitForExistence(timeout: 3), "Cancel confirmation dialog should appear")

        let couldntFinishAlert = app.alerts["Couldn't finish"]
        XCTAssertTrue(couldntFinishAlert.waitForExistence(timeout: 5), "'Couldn't finish' alert should replace cancel confirmation dialog")
        couldntFinishAlert.buttons["OK"].tap()

        XCTAssertTrue(scanButton.waitForExistence(timeout: 5), "Should return to home after dismissing 'Couldn't finish' alert")

        // Path 2: Fake scan failure while room warning alert ("Room couldn't be processed") is open.
        scanButton.tap()
        let nextRoomButton = app.buttons["scanNextRoom"]
        XCTAssertTrue(nextRoomButton.waitForExistence(timeout: 5))
        nextRoomButton.tap()

        let roomWarningAlert = app.alerts["Room couldn't be processed"]
        XCTAssertTrue(roomWarningAlert.waitForExistence(timeout: 3), "Room warning alert should appear")

        XCTAssertTrue(couldntFinishAlert.waitForExistence(timeout: 5), "'Couldn't finish' alert should replace room warning alert")
        couldntFinishAlert.buttons["OK"].tap()

        XCTAssertTrue(scanButton.waitForExistence(timeout: 5))

        // Path 3: Verify Cancel button stays tappable and usable to discard scan.
        scanButton.tap()
        XCTAssertTrue(cancelScanButton.waitForExistence(timeout: 5))
        XCTAssertTrue(cancelScanButton.isHittable)
        cancelScanButton.tap()
        let discardButton = app.buttons["Discard"]
        XCTAssertTrue(discardButton.waitForExistence(timeout: 3))
        discardButton.tap()
        XCTAssertTrue(scanButton.waitForExistence(timeout: 5), "Discard should close scan screen")
    }

    // (c) Inspector name edits: editing name then switching selection doesn't rename the wrong item; edit saved on focus loss.
    func testInspectorNameEditsSavedOnFocusLossWithoutRenamingOtherSelection() throws {
        let app = launchDemoApp()

        let livingRoomLabel = app.buttons["roomLabel-Living room"]
        XCTAssertTrue(livingRoomLabel.waitForExistence(timeout: 10))
        livingRoomLabel.tap()

        let nameField = app.textFields["inspectorNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        XCTAssertEqual(nameField.value as? String, "Living room")

        nameField.tap()
        let currentText = (nameField.value as? String) ?? ""
        let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentText.count)
        nameField.typeText(deleteString + "Main Lounge")

        // Switch selection directly to Kitchen without pressing Return.
        let kitchenRow = app.buttons["inspectorRoom-Kitchen"]
        XCTAssertTrue(kitchenRow.waitForExistence(timeout: 5))
        kitchenRow.tap()

        if !nameField.exists {
            app.collectionViews.firstMatch.swipeDown()
        }
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))

        // Kitchen must still be named "Kitchen", and "Main Lounge" must be saved.
        XCTAssertEqual(nameField.value as? String, "Kitchen", "Switching selection must not rename the newly selected room")
        XCTAssertFalse(app.buttons["inspectorRoom-Living room"].exists)

        // Edit Kitchen name and dismiss inspector (focus loss) without pressing Return.
        nameField.tap()
        let kitchenText = (nameField.value as? String) ?? ""
        let deleteKitchen = String(repeating: XCUIKeyboardKey.delete.rawValue, count: kitchenText.count)
        nameField.typeText(deleteKitchen + "Chef Kitchen")

        app.buttons["OK"].tap()

        XCTAssertTrue(app.buttons["roomLabel-Main Lounge"].waitForExistence(timeout: 5), "Previous room edit should be saved on selection change / focus loss")
        XCTAssertTrue(app.buttons["roomLabel-Chef Kitchen"].waitForExistence(timeout: 5))
    }

    // (d) Importing a renamed .signalsim duplicate.
    func testImportRenamedSignalsimDuplicate() throws {
        let app = launchDemoApp()

        let backButton = app.buttons["backToProjects"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 10))
        backButton.tap()

        let importButton = app.buttons["importProject"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        XCTAssertTrue(importButton.isEnabled)

        throw XCTSkip("Importing a renamed .signalsim duplicate via the UI requires driving the out-of-process UIDocumentPickerViewController against the app's sandboxed Projects folder; this behavior is covered by ReviewRegressionTests.openingExistingProjectFileInPlacePreservesIDAndWorldMap in MeshPlannerCoreTests.")
    }

    // (e) Smoke: project list, open map, 2.4/5 GHz toggle, optimize sheet opens.
    func testSmokeProjectListOpenMapBandToggleAndOptimizeSheet() throws {
        let app = launchDemoApp()

        // Navigate back to project list.
        let backButton = app.buttons["backToProjects"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 10))
        backButton.tap()

        // Verify project list rows and demo button.
        XCTAssertTrue(app.navigationBars["Mesh Planner"].waitForExistence(timeout: 5))
        let savedRow = app.buttons["projectRow-uitest-saved"]
        let openDemoButton = app.buttons["openDemo"]
        XCTAssertTrue(savedRow.waitForExistence(timeout: 5))
        XCTAssertTrue(openDemoButton.exists)

        // Open map.
        openDemoButton.tap()
        XCTAssertTrue(app.buttons["probe"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["router"].waitForExistence(timeout: 5))

        // 2.4 / 5 GHz band toggle.
        let band24 = app.buttons["band-2.4"]
        let band5 = app.buttons["band-5"]
        XCTAssertTrue(band24.waitForExistence(timeout: 5))
        XCTAssertTrue(band5.exists)
        XCTAssertTrue(band5.isSelected)
        XCTAssertFalse(band24.isSelected)

        band24.tap()
        XCTAssertTrue(band24.isSelected)
        XCTAssertFalse(band5.isSelected)

        band5.tap()
        XCTAssertTrue(band5.isSelected)
        XCTAssertFalse(band24.isSelected)

        // Optimize sheet opens.
        let optimizeButton = app.buttons["optimize"]
        XCTAssertTrue(optimizeButton.exists)
        optimizeButton.tap()

        XCTAssertTrue(app.navigationBars["Best placement"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Calculate"].exists)
        app.buttons["Close"].tap()
    }

    // Optional: undo after floor switch; exposes the known bug where undo restores previous probeFloor without syncing the active floor.
    func testUndoAfterFloorSwitch() throws {
        let app = launchDemoApp()

        let backButton = app.buttons["backToProjects"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 10))
        backButton.tap()

        let savedRow = app.buttons["projectRow-uitest-saved"]
        XCTAssertTrue(savedRow.waitForExistence(timeout: 5))
        savedRow.tap()

        let addSatellite = app.buttons["addSatellite"]
        XCTAssertTrue(addSatellite.waitForExistence(timeout: 5))
        addSatellite.tap()

        let okButton = app.buttons["OK"]
        if okButton.waitForExistence(timeout: 5) {
            okButton.tap()
        }

        let undoButton = app.buttons["undo"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5))

        let layersMenu = app.buttons["mapLayers"]
        XCTAssertTrue(layersMenu.exists)
        layersMenu.tap()

        let floor1Button = app.buttons["Floor 1"]
        XCTAssertTrue(floor1Button.waitForExistence(timeout: 5))
        floor1Button.tap()

        XCTAssertTrue(app.buttons["roomLabel-Upstairs bedroom"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["probe"].exists)

        undoButton.tap()

        XCTExpectFailure("Known bug: undo restores the snapshot's probeFloor (0) while keeping model.floor at 1, so the probe pin disappears on the active floor.") {
            XCTAssertTrue(app.buttons["probe"].exists, "Probe pin should remain visible on the active floor after undoing an edit")
        }
    }

    /// Opens the optimizer sheet, picks "None (router only)" and calculates.
    private func calculateRouterOnly(in app: XCUIApplication) {
        let optimizeButton = app.buttons["optimize"]
        XCTAssertTrue(optimizeButton.waitForExistence(timeout: 5))
        optimizeButton.tap()
        XCTAssertTrue(app.navigationBars["Best placement"].waitForExistence(timeout: 5))

        let picker = app.buttons["satelliteCountPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let routerOnly = app.buttons["None (router only)"]
        XCTAssertTrue(routerOnly.waitForExistence(timeout: 5))
        routerOnly.tap()

        app.buttons["Calculate"].tap()
    }

    private func waitForLabel(_ element: XCUIElement, toEqual expected: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { _, _ in element.exists && element.label == expected }
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout) == .completed
    }

    // (f) Router-only Optimize: the sheet's Before/After match the map, and optimizing again after Apply reports the
    // placement as already the best (it used to offer 93% → 96% on a second run).
    func testRouterOnlyOptimizeMatchesMapAndIsAlreadyBestAfterApply() throws {
        let app = launchDemoApp()

        let heatmap = app.descendants(matching: .any)["heatmap"]
        XCTAssertTrue(heatmap.waitForExistence(timeout: 10))
        let fullHeatmap = NSPredicate { _, _ in (self.parseHeatmapCounts(heatmap.value as? String)?.generation ?? 0) >= 1 }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: fullHeatmap, object: nil)], timeout: 10), .completed)
        // The summary card combines its children into one element that inherits the identifier; take the bare "81%".
        let mapCoverage = app.staticTexts
            .matching(NSPredicate(format: "identifier == 'mapCoveragePercent' AND NOT (label CONTAINS ',')"))
            .firstMatch
        XCTAssertTrue(mapCoverage.waitForExistence(timeout: 5))
        let mapBefore = mapCoverage.label

        calculateRouterOnly(in: app)
        let change = app.descendants(matching: .any)["optimizerCoverageChange"]
        XCTAssertTrue(change.waitForExistence(timeout: 30), "The demo's default router spot should get a better proposal")
        let prefix = "Coverage from \(mapBefore) to "
        XCTAssertTrue(change.label.hasPrefix(prefix), "Sheet '\(change.label)' must start from the map's \(mapBefore)")
        let proposed = String(change.label.dropFirst(prefix.count))

        app.buttons["applyPlacement"].tap()
        XCTAssertTrue(waitForLabel(mapCoverage, toEqual: proposed, timeout: 15), "Map shows \(mapCoverage.label) after Apply; the sheet promised \(proposed)")

        calculateRouterOnly(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["optimizerAlreadyOptimal"].waitForExistence(timeout: 30),
            "Optimizing right after Apply must report the placement as already the best"
        )
        XCTAssertFalse(app.descendants(matching: .any)["optimizerCoverageChange"].exists)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertEqual(mapCoverage.label, proposed)
    }

    private func parseHeatmapCounts(_ value: String?) -> (generation: Int, live: Int)? {
        guard let value else { return nil }
        var gen: Int?
        var live: Int?
        for part in value.split(separator: ",") {
            let kv = part.split(separator: "=")
            guard kv.count == 2, let n = Int(kv[1]) else { continue }
            if kv[0] == "generation" { gen = n }
            else if kv[0] == "live" { live = n }
        }
        guard let g = gen, let l = live else { return nil }
        return (g, l)
    }

    func testHeatmapUpdatesMidDragDuringRouterDrag() throws {
        let app = launchDemoApp()

        let router = app.buttons["router"]
        let heatmap = app.descendants(matching: .any)["heatmap"]
        XCTAssertTrue(router.waitForExistence(timeout: 10))
        XCTAssertTrue(heatmap.waitForExistence(timeout: 5))

        let initialReady = NSPredicate { _, _ in
            guard let counts = self.parseHeatmapCounts(heatmap.value as? String) else { return false }
            return counts.generation >= 1
        }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: initialReady, object: nil)], timeout: 5), .completed)
        let baseline = try XCTUnwrap(parseHeatmapCounts(heatmap.value as? String))
        XCTAssertEqual(baseline.live, 0)

        let routerStartFrame = router.frame
        let startCoord = router.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let endCoord = startCoord.withOffset(CGVector(dx: -55, dy: -30))
        startCoord.press(forDuration: 0.1, thenDragTo: endCoord, withVelocity: .slow, thenHoldForDuration: 0.4)

        let postDragReady = NSPredicate { _, _ in
            guard let counts = self.parseHeatmapCounts(heatmap.value as? String) else { return false }
            return counts.live > baseline.live && counts.generation >= baseline.generation + 2
        }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: postDragReady, object: nil)], timeout: 5), .completed)
        let afterDrag = try XCTUnwrap(parseHeatmapCounts(heatmap.value as? String))
        XCTAssertGreaterThan(afterDrag.live, baseline.live, "Heatmap should publish at least one .live update mid-drag")
        XCTAssertGreaterThanOrEqual(afterDrag.generation, baseline.generation + 2, "Heatmap should publish mid-drag .live update(s) and final .full drop update")
        XCTAssertGreaterThan(hypot(router.frame.midX - routerStartFrame.midX, router.frame.midY - routerStartFrame.midY), 15)
    }
}
