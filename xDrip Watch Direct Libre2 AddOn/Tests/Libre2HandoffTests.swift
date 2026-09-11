import XCTest

@testable import Libre2ExperimentCore

final class Libre2HandoffTests: XCTestCase {
    func session(counter: UInt16 = 17) -> Libre2WatchSession {
        Libre2WatchSession(
            id: UUID(), createdAt: Date(), sensorUID: Data([1, 2, 3, 4, 5, 6, 7, 8]),
            patchInfo: Data([1, 2, 3, 4, 5, 6]), unlockCode: 42,
            unlockCount: counter, bluetoothName: "ABBOTT123456789", sensorSerial: "123456789",
            calibration: Libre2Calibration(
                slopeSlope: 0, offsetSlope: 0.1, slopeOffset: 0, offsetOffset: 0, extraSlope: 1,
                extraOffset: 0))
    }

    func testSessionRoundTrip() throws {
        let value = session()
        XCTAssertEqual(
            try JSONDecoder().decode(Libre2WatchSession.self, from: JSONEncoder().encode(value)), value)
        try value.validate()
    }

    func testPhoneGuardsEveryNonPhoneState() {
        for owner in [
            Libre2Owner.preparingWatch, .releasingPhone, .watch, .returningToPhone, .releasingWatch,
            .returnRequested, .reclaimingPhone, .verifyingPhone, .failed,
        ] {
            XCTAssertFalse(owner.allowsPhoneConnection)
        }
        XCTAssertTrue(Libre2Owner.phone.allowsPhoneConnection)
        XCTAssertFalse(Libre2Owner.preparingWatch.allowsWatchConnection)
    }

    func testPrepareDoesNotPermitWatchAuthentication() throws {
        let value = session()
        let store = Libre2SessionStore { _ in }
        try store.prepare(value)
        XCTAssertThrowsError(try store.reserveCounter(id: value.id))
        XCTAssertEqual(store.snapshot.session?.unlockCount, 17)
    }

    func testCounterPersistedBeforeWriteAndNeverReusedAfterRestart() throws {
        let value = session()
        var disk = Libre2OwnershipRecord(owner: .watch, session: value)
        var events: [String] = []
        let store = Libre2SessionStore(record: disk) {
            disk = $0
            events.append("persist")
        }
        try store.attemptUnlock(id: value.id) { reserved in
            XCTAssertEqual(disk.session?.unlockCount, 18)
            XCTAssertEqual(reserved.unlockCount, 18)
            events.append("write")
        }
        XCTAssertEqual(events, ["persist", "write"])
        // Connection fails immediately after attempting 18; restart from the saved journal.
        let restarted = Libre2SessionStore(record: disk) { disk = $0 }
        XCTAssertEqual(try restarted.reserveCounter(id: value.id).unlockCount, 19)
    }

    func testFailedPersistencePreventsPayloadWrite() {
        let value = session()
        let store = Libre2SessionStore(record: Libre2OwnershipRecord(owner: .watch, session: value)) {
            _ in
            throw Libre2HandoffError.persistence
        }
        var wrote = false
        XCTAssertThrowsError(
            try store.attemptUnlock(id: value.id) { _ in
                wrote = true
            })
        XCTAssertFalse(wrote)
        XCTAssertEqual(store.snapshot.owner, .failed)
    }

    func testCounterExhaustionDoesNotWrap() {
        let value = session(counter: .max)
        let store = Libre2SessionStore(record: Libre2OwnershipRecord(owner: .watch, session: value)) {
            _ in
        }
        XCTAssertThrowsError(try store.reserveCounter(id: value.id))
        XCTAssertEqual(store.snapshot.session?.unlockCount, .max)
    }

    func testStaleIDsAndRetiredPrepareRejected() throws {
        let value = session()
        let store = Libre2SessionStore { _ in }
        try store.prepare(value)
        XCTAssertThrowsError(try store.activateWatch(id: UUID()))
        try store.activateWatch(id: value.id)
        try store.beginReturnToPhone(id: value.id)
        try store.finishReturnOnPhone(id: value.id)
        XCTAssertThrowsError(try store.prepare(value))
        XCTAssertThrowsError(try store.activateWatch(id: value.id))
    }

    func testReturnCounterCannotRegressAndCommitIsIdempotent() throws {
        let value = session(counter: 24)
        let store = Libre2SessionStore(record: Libre2OwnershipRecord(owner: .watch, session: value)) {
            _ in
        }
        var old = value
        old.unlockCount = 23
        XCTAssertThrowsError(try store.acceptReturn(old))
        var returned = value
        returned.unlockCount = 27
        try store.acceptReturn(returned)
        XCTAssertFalse(store.snapshot.owner.allowsPhoneConnection)
        try store.finishReturnOnPhone(id: value.id)
        try store.finishReturnOnPhone(id: value.id)
        XCTAssertEqual(store.snapshot.session?.unlockCount, 27)
        XCTAssertEqual(Int(store.snapshot.session!.unlockCount) + 1, 28)
    }

    func testCannotCommitBeforeReturnPrepare() {
        let value = session()
        let store = Libre2SessionStore(record: Libre2OwnershipRecord(owner: .watch, session: value)) {
            _ in
        }
        XCTAssertThrowsError(try store.finishReturnOnPhone(id: value.id))
        XCTAssertFalse(store.snapshot.owner.allowsPhoneConnection)
    }

    func testAssemblerRejectsOverflowAndExpiredFragments() {
        var assembler = Libre2FrameAssembler()
        let now = Date()
        XCTAssertNil(assembler.append(Data(repeating: 1, count: 20), now: now))
        XCTAssertNil(assembler.append(Data(repeating: 2, count: 20), now: now))
        XCTAssertEqual(assembler.append(Data(repeating: 3, count: 6), now: now)?.count, 46)
        XCTAssertNil(assembler.append(Data(repeating: 1, count: 40), now: now))
        XCTAssertNil(assembler.append(Data(repeating: 2, count: 20), now: now))
        XCTAssertNil(assembler.append(Data(repeating: 1, count: 20), now: now))
        XCTAssertNil(assembler.append(Data(repeating: 2, count: 26), now: now.addingTimeInterval(4)))
    }

    func testMalformedFramesFailWithoutIndexingCrash() {
        XCTAssertThrowsError(try Libre2Core.decryptBLE(sensorUID: Data(), data: Data()))
        XCTAssertThrowsError(
            try Libre2Core.decryptBLE(sensorUID: session().sensorUID, data: Data(repeating: 0, count: 46))
        )
        var parser = Libre2ParserState()
        XCTAssertTrue(
            Libre2Core.parseBLEData(Data(), libre1DerivedAlgorithmParameters: nil, state: &parser)
                .bleGlucose.isEmpty)
    }

    func testParserConversionAndTimestamp() {
        var data = Data(repeating: 0, count: 44)
        // 1000 raw * 0.1 = 100 mg/dL, first sample; sensor age 60 minutes.
        data[0] = 0xe8
        data[1] = 0x03
        data[40] = 60
        var parser = Libre2ParserState()
        let now = Date(timeIntervalSince1970: 1000)
        let parsed = Libre2Core.parseBLEData(
            data, libre1DerivedAlgorithmParameters: session().calibration, state: &parser, now: now)
        XCTAssertEqual(parsed.bleGlucose.first?.glucoseLevelRaw, 100)
        XCTAssertEqual(parsed.bleGlucose.first?.timeStamp, now)
        XCTAssertEqual(parsed.sensorTimeInMinutes, 60)
    }

    func testExistingRepositoryCryptoFixtureIsUnchanged() throws {
        func data(_ hex: String) -> Data {
            let bytes = Array(hex)
            return Data(
                stride(from: 0, to: bytes.count, by: 2).map {
                    UInt8(String(bytes[$0...$0 + 1]), radix: 16)!
                })
        }
        // Encrypted sample from CGMLibre2Transmitter+TestData.swift. Expected outputs
        // were generated with the unmodified upstream crypto before the refactor.
        let uid = data("e3a18e0100a407e0")
        let frame = data(
            "ebb86eb952942ce055278df46b68ba1eacd3c78c7e800ea3890c61116679c2a3fcc220a95571ff760207682942f0"
        )
        XCTAssertEqual(
            Data(try Libre2Core.decryptBLE(sensorUID: uid, data: frame)),
            data(
                "8802ee85a082f485ab420086bac21786c80217860903e38529c3b78121c3b781e8c2af812643b2851b03168b"))
        XCTAssertEqual(
            Data(
                Libre2Core.streamingUnlockPayload(
                    sensorUID: uid, info: data("9d0830017317"), enableTime: 42, unlockCount: 18)),
            data("3c00000073e808168a009e02"))
    }

    func testWatchParserNeverReturnsRawFallback() {
        var data = Data(repeating: 0, count: 44)
        data[0] = 10
        var parser = Libre2ParserState()
        XCTAssertTrue(
            Libre2Core.parseBLEData(
                data, libre1DerivedAlgorithmParameters: nil, state: &parser, allowsRawFallback: false
            ).bleGlucose
                .isEmpty)
    }

    func testReturnFreezesFurtherCounterReservations() throws {
        let value = session()
        let store = Libre2SessionStore(record: Libre2OwnershipRecord(owner: .watch, session: value)) {
            _ in
        }
        try store.beginReturnToPhone(id: value.id)
        XCTAssertThrowsError(try store.reserveCounter(id: value.id))
    }

    func testWatchPeripheralIdentitySurvivesRestartForDisconnectBarrier() throws {
        let value = session()
        let id = UUID()
        var disk = Libre2OwnershipRecord(owner: .watch, session: value)
        let store = Libre2SessionStore(record: disk) { disk = $0 }
        try store.rememberWatchPeripheral(id, sessionID: value.id)
        let restored = try JSONDecoder().decode(
            Libre2OwnershipRecord.self, from: JSONEncoder().encode(disk))
        XCTAssertEqual(restored.watchPeripheralID, id)
        XCTAssertThrowsError(try store.rememberWatchPeripheral(UUID(), sessionID: UUID()))
    }

    // MARK: - Refactor compatibility

    func testPersistedRecordAndMessagesKeepTheirOriginalFormat() throws {
        // Encoded by the implementation before its models and journal were split into files.
        let fixture = Data(
            """
            {
              "owner": "watch",
              "retiredIDs": [
                "20000000-0000-0000-0000-000000000002"
              ],
              "session": {
                "bluetoothName": "ABBOTT123456789",
                "calibration": {
                  "extraOffset": 0,
                  "extraSlope": 1,
                  "offsetOffset": 0,
                  "offsetSlope": 0.1,
                  "slopeOffset": 0,
                  "slopeSlope": 0
                },
                "createdAt": 805149589,
                "id": "10000000-0000-0000-0000-000000000001",
                "patchInfo": "AQIDBAUG",
                "sensorSerial": "123456789",
                "sensorUID": "AQIDBAUGBwg=",
                "unlockCode": 42,
                "unlockCount": 17
              },
              "watchMayHaveConnected": true,
              "watchPeripheralID": "30000000-0000-0000-0000-000000000003"
            }
            """.utf8)
        let record = try JSONDecoder().decode(Libre2OwnershipRecord.self, from: fixture)
        let restoredSession = try XCTUnwrap(record.session)
        try restoredSession.validate()
        XCTAssertEqual(record.owner, .watch)
        XCTAssertEqual(restoredSession.unlockCount, 17)
        XCTAssertEqual(record.retiredIDs.count, 1)
        XCTAssertTrue(record.watchMayHaveConnected)
        XCTAssertEqual(record.watchPeripheralID?.uuidString, "30000000-0000-0000-0000-000000000003")

        let encodedRecord =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? NSDictionary
        let originalRecord = try JSONSerialization.jsonObject(with: fixture) as? NSDictionary
        XCTAssertEqual(encodedRecord, originalRecord)

        let messageKinds: [(Libre2HandoffMessage.Kind, String)] = [
            (.prepare, "prepare"), (.activate, "activate"),
            (.returnPrepare, "returnPrepare"), (.returnCommit, "returnCommit"),
            (.requestReturn, "requestReturn"),
        ]
        for (kind, encodedKind) in messageKinds {
            let message = Libre2HandoffMessage(kind: kind, session: restoredSession)
            let dictionary = try message.dictionary
            let encodedMessage = try XCTUnwrap(dictionary["phoneControlledLibre2Handoff"] as? Data)
            let messageObject = try JSONSerialization.jsonObject(with: encodedMessage) as? NSDictionary
            let expectedMessage: NSDictionary = [
                "kind": encodedKind, "session": try XCTUnwrap(originalRecord?["session"]),
            ]
            XCTAssertEqual(messageObject, expectedMessage)
            XCTAssertEqual(try Libre2HandoffMessage.decode(dictionary).session, restoredSession)
        }
    }

    func testFullHandoffRoundTripKeepsOnlyOneOwnerAndReturnsLatestCounter() throws {
        let value = session()
        let phone = Libre2SessionStore { _ in }
        let watch = Libre2SessionStore { _ in }

        try phone.prepare(value)
        try watch.prepare(value)
        XCTAssertFalse(phone.snapshot.owner.allowsPhoneConnection)
        XCTAssertFalse(watch.snapshot.owner.allowsWatchConnection)

        // Watch READY permits the phone's disconnect phase, but not Watch authentication.
        try phone.beginPhoneRelease(id: value.id)
        XCTAssertThrowsError(try watch.reserveCounter(id: value.id))

        // ACTIVATE is delivered only after the phone transport confirms its disconnect.
        try watch.activateWatch(id: value.id)
        try phone.confirmWatchOwnership(id: value.id)
        XCTAssertFalse(phone.snapshot.owner.allowsPhoneConnection)
        XCTAssertTrue(watch.snapshot.owner.allowsWatchConnection)
        XCTAssertEqual(try watch.reserveCounter(id: value.id).unlockCount, 18)
        let returningSession = try watch.reserveCounter(id: value.id)
        XCTAssertEqual(returningSession.unlockCount, 19)

        try watch.beginReturnToPhone(id: value.id)
        try phone.acceptReturn(returningSession)
        XCTAssertThrowsError(try watch.reserveCounter(id: value.id))
        XCTAssertFalse(phone.snapshot.owner.allowsPhoneConnection)
        XCTAssertEqual(phone.snapshot.session?.unlockCount, 19)

        // The phone's READY permits Watch disconnect; COMMIT releases the phone guard.
        try watch.beginWatchRelease(id: value.id)
        XCTAssertFalse(watch.snapshot.owner.allowsWatchConnection)
        try phone.finishReturnOnPhone(id: value.id)
        try watch.finishReturnOnWatch(id: value.id)
        XCTAssertTrue(phone.snapshot.owner.allowsPhoneConnection)
        XCTAssertFalse(watch.snapshot.owner.allowsWatchConnection)
        XCTAssertEqual(phone.snapshot.session?.unlockCount, 19)
        XCTAssertEqual(watch.snapshot.session?.unlockCount, 19)
        XCTAssertThrowsError(try watch.activateWatch(id: value.id))
    }

    // MARK: - Cancellation and diagnostic controls

    func testCancelBeforePrepareReachesWatchReturnsWithoutAnyUnlock() throws {
        let value = session()
        let phone = Libre2SessionStore { _ in }
        let watch = Libre2SessionStore { _ in }
        try phone.prepare(value)
        try phone.requestReturnFromWatch(id: value.id)
        XCTAssertFalse(phone.snapshot.owner.allowsPhoneConnection)
        XCTAssertThrowsError(try phone.beginPhoneRelease(id: value.id))  // Late PREPARE reply.

        try watch.prepareRequestedReturn(value)
        XCTAssertFalse(watch.snapshot.watchMayHaveConnected)
        XCTAssertFalse(watch.snapshot.owner.allowsWatchConnection)
        try watch.beginReturnToPhone(id: value.id)
        try phone.acceptReturn(value)
        try watch.beginWatchRelease(id: value.id)
        try phone.finishReturnOnPhone(id: value.id)
        try watch.finishReturnOnWatch(id: value.id)
        XCTAssertTrue(phone.snapshot.owner.allowsPhoneConnection)
        XCTAssertEqual(phone.snapshot.session?.unlockCount, 17)
        XCTAssertThrowsError(try watch.prepare(value))  // Delayed PREPARE cannot revive a cancelled handoff.
        XCTAssertThrowsError(try watch.activateWatch(id: value.id))
        XCTAssertThrowsError(try watch.prepareRequestedReturn(value))
    }

    func testCancelAfterWatchUnlockPreservesLatestCounter() throws {
        let value = session()
        let phone = Libre2SessionStore(
            record: Libre2OwnershipRecord(owner: .releasingPhone, session: value)
        ) { _ in }
        let watch = Libre2SessionStore(
            record: Libre2OwnershipRecord(owner: .watch, session: value, watchMayHaveConnected: true)
        ) { _ in }
        let attempted = try watch.reserveCounter(id: value.id)
        try phone.requestReturnFromWatch(id: value.id)
        XCTAssertThrowsError(try phone.confirmWatchOwnership(id: value.id))  // Late ACTIVATE reply.
        try watch.prepareRequestedReturn(value)  // Phone still knows N; Watch already attempted N+1.
        XCTAssertEqual(watch.snapshot.session?.unlockCount, attempted.unlockCount)
        XCTAssertTrue(watch.snapshot.watchMayHaveConnected)
        try watch.beginReturnToPhone(id: value.id)
        XCTAssertThrowsError(try watch.reserveCounter(id: value.id))
        try phone.acceptReturn(attempted)
        XCTAssertFalse(phone.snapshot.owner.allowsPhoneConnection)
        try watch.beginWatchRelease(id: value.id)
        try phone.finishReturnOnPhone(id: value.id)
        try watch.finishReturnOnWatch(id: value.id)
        XCTAssertEqual(phone.snapshot.session?.unlockCount, 18)
    }

    func testRepeatedCancelDoesNotInvalidateReturnCommit() throws {
        let value = session(counter: 23)
        let phone = Libre2SessionStore(record: Libre2OwnershipRecord(owner: .watch, session: value)) {
            _ in
        }
        try phone.requestReturnFromWatch(id: value.id)
        try phone.requestReturnFromWatch(id: value.id)
        try phone.acceptReturn(value)
        try phone.requestReturnFromWatch(id: value.id)
        XCTAssertEqual(phone.snapshot.owner, .returningToPhone)
        try phone.finishReturnOnPhone(id: value.id)
        XCTAssertTrue(phone.snapshot.owner.allowsPhoneConnection)
        XCTAssertThrowsError(try phone.requestReturnFromWatch(id: value.id))
    }

    func testCancellationRejectsStaleHandoffsAndPersistenceFailure() throws {
        let value = session()
        let watch = Libre2SessionStore(record: Libre2OwnershipRecord(owner: .watch, session: value)) {
            _ in
        }
        XCTAssertThrowsError(try watch.prepareRequestedReturn(session()))
        XCTAssertEqual(watch.snapshot.session, value)
        let phone = Libre2SessionStore(
            record: Libre2OwnershipRecord(owner: .preparingWatch, session: value)
        ) { _ in
            throw Libre2HandoffError.persistence
        }
        XCTAssertThrowsError(try phone.requestReturnFromWatch(id: UUID()))
        XCTAssertThrowsError(try phone.requestReturnFromWatch(id: value.id))
        XCTAssertFalse(phone.snapshot.owner.allowsPhoneConnection)
        XCTAssertEqual(phone.snapshot.owner, .failed)
    }

    func testRequestedReturnSurvivesJournalReload() throws {
        let value = session()
        var disk = Libre2OwnershipRecord(owner: .preparingWatch, session: value)
        let phone = Libre2SessionStore(record: disk) { disk = $0 }
        try phone.requestReturnFromWatch(id: value.id)
        let restored = try JSONDecoder().decode(
            Libre2OwnershipRecord.self, from: JSONEncoder().encode(disk))
        XCTAssertEqual(restored.owner, .returnRequested)
        XCTAssertFalse(restored.owner.allowsPhoneConnection)
        XCTAssertEqual(restored.session, value)
    }

    func testActivityLogIsBoundedPersistsAndDoesNotResetOwnership() throws {
        let suite = "DirectLibreTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let value = session(counter: 31)
        let store = Libre2SessionStore(record: Libre2OwnershipRecord(owner: .watch, session: value)) {
            _ in
        }
        let log = Libre2ActivityLog(defaults: defaults)
        log.record("One event")
        log.record("One event")
        XCTAssertEqual(log.entries.count, 1)
        for index in 0..<100 { log.record("Event \(index)") }
        XCTAssertEqual(log.entries.count, Libre2ActivityLog.maximumEntries)
        let restored = Libre2ActivityLog(defaults: defaults)
        XCTAssertEqual(restored.entries.first?.message, "Event 20")
        XCTAssertEqual(restored.entries.last?.message, "Event 99")
        restored.clear()
        XCTAssertTrue(Libre2ActivityLog(defaults: defaults).entries.isEmpty)
        XCTAssertEqual(store.snapshot.owner, .watch)
        XCTAssertEqual(store.snapshot.session?.unlockCount, 31)
    }

    func testNormalNFCRemainsAvailableButExcludesTransfer() throws {
        let store = Libre2SessionStore { _ in }
        try store.beginPhoneNFC()
        XCTAssertTrue(store.snapshot.owner.allowsPhoneConnection)
        XCTAssertThrowsError(try store.prepare(session()))
        store.endPhoneNFC()
        try store.prepare(session())
        XCTAssertThrowsError(try store.beginPhoneNFC())
    }

    func testLateRevokeCannotStopNewWatchSession() throws {
        let first = session()
        let store = Libre2SessionStore(record: Libre2OwnershipRecord(owner: .watch, session: first)) {
            _ in
        }
        try store.revokeOnWatch(first)
        XCTAssertFalse(store.snapshot.owner.allowsWatchConnection)
        try store.finishReturnOnWatch(id: first.id)
        let next = session()
        try store.prepare(next)
        XCTAssertFalse(try store.revokeOnWatch(first))
        XCTAssertEqual(store.snapshot.session?.id, next.id)
        XCTAssertThrowsError(try store.activateWatch(id: first.id))
    }

    func testUnlockCodeMustAllowCounterAdditionWithoutOverflow() {
        let value = session()
        let invalid = Libre2WatchSession(
            id: value.id, createdAt: value.createdAt, sensorUID: value.sensorUID,
            patchInfo: value.patchInfo, unlockCode: UInt32.max, unlockCount: value.unlockCount,
            bluetoothName: value.bluetoothName, sensorSerial: value.sensorSerial,
            calibration: value.calibration)
        XCTAssertThrowsError(try invalid.validate())
    }

    func testCompletedReturnAcknowledgementSurvivesPhoneCounterAndNFCChanges() throws {
        let value = session()
        let store = Libre2SessionStore(
            record: Libre2OwnershipRecord(owner: .returningToPhone, session: value)
        ) { _ in }
        try store.finishReturnOnPhone(id: value.id)
        try store.recordPhoneCounter(18, sensorUID: value.sensorUID, unlockCode: value.unlockCode)
        try store.finishReturnOnPhone(id: value.id)
        XCTAssertEqual(store.snapshot.session?.unlockCount, 18)
        try store.beginPhoneNFC(resetUnlockCode: 5000)
        try store.confirmPhoneNFCReset(unlockCode: 5000)
        try store.finishPhoneNFCReset(unlockCode: 5000, sensorUID: value.sensorUID)
        try store.finishReturnOnPhone(id: value.id)
        XCTAssertNil(store.snapshot.session)
        XCTAssertEqual(store.snapshot.owner, .phone)
    }

    func testOrdinaryNFCRepairsMalformedSavedSession() throws {
        let value = session()
        let invalid = Libre2WatchSession(
            id: value.id, createdAt: value.createdAt, sensorUID: Data(),
            patchInfo: value.patchInfo, unlockCode: value.unlockCode, unlockCount: 0,
            bluetoothName: value.bluetoothName, sensorSerial: value.sensorSerial,
            calibration: value.calibration)
        let store = Libre2SessionStore(record: Libre2OwnershipRecord(owner: .failed, session: invalid)) { _ in }
        try store.beginPhoneNFC(resetUnlockCode: 5000)
        XCTAssertNil(store.snapshot.session)
        try store.confirmPhoneNFCReset(unlockCode: 5000)
        try store.finishPhoneNFCReset(unlockCode: 5000, sensorUID: value.sensorUID)
        XCTAssertEqual(store.snapshot.reclaim?.sensorUID, value.sensorUID)
    }

    func testOrdinaryNFCDoesNotDependOnExperimentalJournalWrites() throws {
        let store = Libre2SessionStore { _ in throw Libre2HandoffError.persistence }
        try store.beginPhoneNFC()
        store.endPhoneNFC()
        XCTAssertEqual(store.snapshot.owner, .phone)
        XCTAssertTrue(store.snapshot.owner.allowsPhoneConnection)
    }

    func testDiagnosticsStaySilentOutsideExperimentAndPage() throws {
        let suite = "direct-libre-idle-log-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var experimentActive = false
        let log = Libre2ActivityLog(defaults: defaults, shouldRecord: { experimentActive })
        log.record("Phone relay")
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertNil(defaults.data(forKey: "phoneControlledLibreActivityLog"))
        log.isPageVisible = true
        log.record("Watch reachable")
        log.isPageVisible = false
        log.record("Watch unavailable")
        XCTAssertEqual(log.entries.map(\.message), ["Watch reachable"])
        experimentActive = true
        log.record("Returning to phone")
        experimentActive = false
        log.record("Counter exhausted")
        XCTAssertEqual(log.entries.map(\.message), ["Watch reachable", "Returning to phone"])
    }

    func testExperimentalStateIncludesReturnedCredentialsButNotRetiredIDsAlone() throws {
        XCTAssertFalse(Libre2OwnershipRecord().hasExperimentalState)
        XCTAssertFalse(Libre2OwnershipRecord(retiredIDs: [UUID()]).hasExperimentalState)
        XCTAssertTrue(Libre2OwnershipRecord(owner: .failed).hasExperimentalState)
        let value = session()
        let store = Libre2SessionStore(record: Libre2OwnershipRecord(owner: .returningToPhone, session: value)) { _ in }
        try store.finishReturnOnPhone(id: value.id)
        XCTAssertEqual(store.snapshot.owner, .phone)
        XCTAssertTrue(store.snapshot.hasExperimentalState)
        XCTAssertTrue(Libre2OwnershipRecord(phoneNFCResetCode: 1000).hasExperimentalState)
        XCTAssertTrue(Libre2OwnershipRecord(reclaim: Libre2ReclaimState(id: UUID(), sensorUID: value.sensorUID, unlockCode: 1000)).hasExperimentalState)
    }

    // MARK: - Ordinary NFC hard reset

    func testQueuedRevokeOvertakingPrepareRetiresTheUnseenWatchSession() throws {
        let old = session()
        var persisted = Libre2OwnershipRecord()
        let watch = Libre2SessionStore { persisted = $0 }
        XCTAssertFalse(try watch.revokeOnWatch(old))
        XCTAssertEqual(watch.snapshot.owner, .phone)
        let restarted = Libre2SessionStore(record: persisted) { _ in }
        XCTAssertThrowsError(try restarted.prepare(old))
        XCTAssertThrowsError(try restarted.prepareRequestedReturn(old))
        let next = session()
        try restarted.prepare(next)
        try restarted.activateWatch(id: next.id)
        XCTAssertFalse(try restarted.revokeOnWatch(old))
        XCTAssertEqual(restarted.snapshot.owner, .watch)
        XCTAssertEqual(restarted.snapshot.session?.id, next.id)
    }

    func testOrdinaryNFCResetsEveryExperimentalStateWithoutTheDeletedSensor() throws {
        let old = session()
        for owner in [Libre2Owner.phone, .preparingWatch, .releasingPhone, .watch,
                      .returningToPhone, .releasingWatch, .returnRequested,
                      .reclaimingPhone, .verifyingPhone, .failed] {
            var persisted: Libre2OwnershipRecord?
            let store = Libre2SessionStore(record: Libre2OwnershipRecord(owner: owner, session: old)) {
                persisted = $0
            }
            // No old sensor UID, transmitter, or Watch acknowledgement is required.
            try store.beginPhoneNFC(resetUnlockCode: 1000)
            XCTAssertTrue(store.phoneNFCIsActive)
            XCTAssertEqual(persisted?.phoneNFCResetCode, 1000)
            XCTAssertTrue(store.snapshot.retiredIDs.contains(old.id))
            XCTAssertNil(store.snapshot.session)
            XCTAssertNil(store.snapshot.reclaim)
            XCTAssertFalse(store.snapshot.owner.allowsPhoneConnection)
            XCTAssertThrowsError(try store.beginPhoneRelease(id: old.id))
            XCTAssertThrowsError(try store.acceptReturn(old))
            XCTAssertThrowsError(try store.finishReturnOnPhone(id: old.id))
        }
    }

    func testOrdinaryNFCResetRequiresProvisioningBeforeDisconnectCompletion() throws {
        let old = session()
        let newUID = Data([8, 7, 6, 5, 4, 3, 2, 1])
        let store = Libre2SessionStore(record: Libre2OwnershipRecord(owner: .watch, session: old)) { _ in }
        try store.beginPhoneNFC(resetUnlockCode: 1000)
        XCTAssertThrowsError(try store.finishPhoneNFCReset(unlockCode: 1000, sensorUID: newUID))
        try store.confirmPhoneNFCReset(unlockCode: 1000)
        XCTAssertFalse(store.snapshot.owner.allowsPhoneConnection)
        XCTAssertThrowsError(try store.finishPhoneNFCReset(unlockCode: 999, sensorUID: newUID))
        // The disconnect callback is the only application caller of this final transition.
        try store.finishPhoneNFCReset(unlockCode: 1000, sensorUID: newUID)
        XCTAssertTrue(store.snapshot.owner.allowsPhoneConnection)
        XCTAssertFalse(store.phoneNFCIsActive)
        XCTAssertEqual(store.snapshot.reclaim?.sensorUID, newUID)
        XCTAssertEqual(store.snapshot.reclaim?.unlockCount, 0)
        try store.recordPhoneCounter(1, sensorUID: newUID, unlockCode: 1000)
        XCTAssertEqual(store.snapshot.reclaim?.unlockCount, 1)
        XCTAssertThrowsError(try store.prepare(old))
        // Even after recovery, a subsequent scan must not re-use the old credentials.
        try store.beginPhoneNFC(resetUnlockCode: 2000)
        XCTAssertEqual(store.snapshot.phoneNFCResetCode, 2000)
    }

    func testCancelledOrdinaryNFCResetCanRetryAndRejectsOldCompletion() throws {
        let store = Libre2SessionStore(record: Libre2OwnershipRecord(owner: .watch, session: session())) { _ in }
        try store.beginPhoneNFC(resetUnlockCode: 1000)
        try store.confirmPhoneNFCReset(unlockCode: 1000)
        store.endPhoneNFC()
        XCTAssertFalse(store.snapshot.owner.allowsPhoneConnection)
        XCTAssertThrowsError(try store.finishPhoneNFCReset(unlockCode: 1000, sensorUID: session().sensorUID))
        try store.beginPhoneNFC(resetUnlockCode: 2000)
        XCTAssertThrowsError(try store.confirmPhoneNFCReset(unlockCode: 1000))
        XCTAssertThrowsError(try store.finishPhoneNFCReset(unlockCode: 1000, sensorUID: session().sensorUID))
        XCTAssertTrue(store.phoneNFCIsActive)
        try store.confirmPhoneNFCReset(unlockCode: 2000)
        try store.finishPhoneNFCReset(unlockCode: 2000, sensorUID: session().sensorUID)
    }

    func testInterruptedResetSurvivesRestartAndAllowsAnotherSensorScan() throws {
        let store = Libre2SessionStore(record: Libre2OwnershipRecord(owner: .failed)) { _ in }
        try store.beginPhoneNFC(resetUnlockCode: 1000)
        try store.confirmPhoneNFCReset(unlockCode: 1000)
        let decoded = try JSONDecoder().decode(Libre2OwnershipRecord.self, from: JSONEncoder().encode(store.snapshot))
        let restarted = Libre2SessionStore(record: decoded) { _ in }
        XCTAssertFalse(restarted.phoneNFCIsActive)
        XCTAssertFalse(restarted.snapshot.owner.allowsPhoneConnection)
        XCTAssertThrowsError(try restarted.finishPhoneNFCReset(unlockCode: 1000, sensorUID: session().sensorUID))
        try restarted.beginPhoneNFC(resetUnlockCode: 2000)
        try restarted.confirmPhoneNFCReset(unlockCode: 2000)
        try restarted.finishPhoneNFCReset(unlockCode: 2000, sensorUID: session().sensorUID)
    }

    func testResetPersistenceFailureDoesNotStartNFCOrGrantBLE() throws {
        var fail = true
        let store = Libre2SessionStore(record: Libre2OwnershipRecord(owner: .watch, session: session())) { _ in
            if fail { throw Libre2HandoffError.persistence }
        }
        XCTAssertThrowsError(try store.beginPhoneNFC(resetUnlockCode: 1000))
        XCTAssertFalse(store.phoneNFCIsActive)
        XCTAssertFalse(store.snapshot.owner.allowsPhoneConnection)
        fail = false
        try store.beginPhoneNFC(resetUnlockCode: 2000)
        try store.confirmPhoneNFCReset(unlockCode: 2000)
        fail = true
        XCTAssertThrowsError(try store.finishPhoneNFCReset(unlockCode: 2000, sensorUID: session().sensorUID))
        XCTAssertFalse(store.snapshot.owner.allowsPhoneConnection)
    }

    func testLegacyReclaimRecordsRequireOrdinaryNFCRecovery() throws {
        let old = session()
        for phase in [Libre2Owner.reclaimingPhone, .verifyingPhone] {
            let credentials = Libre2ReclaimState(id: UUID(), sensorUID: old.sensorUID,
                                               unlockCode: 5000, nfcConfirmed: true, unlockCount: 19)
            let saved = Libre2OwnershipRecord(owner: phase, session: old, reclaim: credentials)
            let decoded = try JSONDecoder().decode(Libre2OwnershipRecord.self, from: JSONEncoder().encode(saved))
            let store = Libre2SessionStore(record: decoded) { _ in }
            XCTAssertFalse(store.snapshot.owner.allowsPhoneConnection)
            XCTAssertEqual(store.snapshot.phoneSwitchAction, .unavailable)
            XCTAssertEqual(store.snapshot.reclaim?.unlockCount, 19)
            for code: UInt32 in [42, 5000, .max] {
                XCTAssertThrowsError(try store.beginPhoneNFC(resetUnlockCode: code))
            }
            try store.beginPhoneNFC(resetUnlockCode: 6000)
            XCTAssertNil(store.snapshot.reclaim)
            try store.confirmPhoneNFCReset(unlockCode: 6000)
            try store.finishPhoneNFCReset(unlockCode: 6000, sensorUID: old.sensorUID)
            XCTAssertTrue(store.snapshot.owner.allowsPhoneConnection)
            XCTAssertEqual(store.snapshot.reclaim?.unlockCode, 6000)
        }
    }

    // MARK: - Phone reading checklist regressions

    func testPhoneBLEReadingIsRecentWithoutAnObservedLogin() {
        let now = Date(timeIntervalSince1970: 1000)
        var status = Libre2PhoneReadingStatus()
        status.receivedBLEReading(at: now, verifiedUnlockCode: nil)
        XCTAssertTrue(status.hasRecentReading(at: now.addingTimeInterval(30)))
        XCTAssertFalse(status.hasRecentVerifiedReading(at: now.addingTimeInterval(30)))
    }

    func testOnlyFreshVerifiedPhoneReadingsCanStartHandoff() {
        let now = Date(timeIntervalSince1970: 1000)
        var status = Libre2PhoneReadingStatus()
        status.receivedBLEReading(at: now, verifiedUnlockCode: 1234)
        XCTAssertTrue(status.hasRecentVerifiedReading(at: now.addingTimeInterval(179)))
        XCTAssertEqual(status.verifiedUnlockCode, 1234)
        XCTAssertFalse(status.hasRecentVerifiedReading(at: now.addingTimeInterval(180)))
        XCTAssertFalse(status.hasRecentReading(at: now.addingTimeInterval(-1)))
        status.receivedBLEReading(at: now.addingTimeInterval(60), verifiedUnlockCode: nil)
        XCTAssertTrue(status.hasRecentReading(at: now.addingTimeInterval(60)))
        XCTAssertFalse(status.hasRecentVerifiedReading(at: now.addingTimeInterval(60)))
    }

    func testNewPhoneConnectionDoesNotInheritLoginEvidence() {
        let now = Date(timeIntervalSince1970: 1000)
        var status = Libre2PhoneReadingStatus()
        status.receivedBLEReading(at: now, verifiedUnlockCode: 42)
        status = Libre2PhoneReadingStatus()
        XCTAssertFalse(status.hasRecentReading(at: now))
        XCTAssertFalse(status.hasRecentVerifiedReading(at: now))
    }

    func testOlderPhoneObservationCannotReplaceNewerLoginEvidence() {
        let now = Date(timeIntervalSince1970: 1000)
        var status = Libre2PhoneReadingStatus()
        status.receivedBLEReading(at: now, verifiedUnlockCode: 1234)
        status.receivedBLEReading(at: now.addingTimeInterval(-1), verifiedUnlockCode: 42)
        XCTAssertEqual(status.lastReadingAt, now)
        XCTAssertEqual(status.verifiedUnlockCode, 1234)
    }

    // MARK: - Single phone switch button

    func testSwitchButtonFollowsTheSavedDeviceAndPendingReturn() {
        let value = session()
        XCTAssertEqual(Libre2OwnershipRecord().phoneSwitchAction, .switchToWatch)
        for owner in [Libre2Owner.preparingWatch, .releasingPhone, .watch, .returnRequested, .returningToPhone] {
            let record = Libre2OwnershipRecord(owner: owner, session: value)
            XCTAssertEqual(record.phoneSwitchAction, .returnToPhone)
            XCTAssertFalse(record.owner.allowsPhoneConnection)
        }
        XCTAssertEqual(Libre2OwnershipRecord(owner: .watch).phoneSwitchAction, .unavailable)
        XCTAssertEqual(Libre2OwnershipRecord(owner: .failed, session: value).phoneSwitchAction, .unavailable)
    }

    // MARK: - Event-driven checklist refresh

    func testChecklistSchedulesOnlyTheNextFreshnessBoundary() {
        let now = Date(timeIntervalSince1970: 1000)
        var status = Libre2PhoneReadingStatus()
        XCTAssertNil(status.nextFreshnessChange(at: now))
        status.receivedBLEReading(at: now, verifiedUnlockCode: 42)
        let expiry = now.addingTimeInterval(ConstantsLibre2.recentReadingInterval)
        XCTAssertEqual(status.nextFreshnessChange(at: now), expiry)
        XCTAssertEqual(status.nextFreshnessChange(at: expiry.addingTimeInterval(-1)), expiry)
        XCTAssertFalse(status.hasRecentVerifiedReading(at: expiry))
        XCTAssertNil(status.nextFreshnessChange(at: expiry))
        XCTAssertNil(status.nextFreshnessChange(at: expiry.addingTimeInterval(3600)))
    }

    func testNewReadingMovesDeadlineAndConnectionResetRemovesIt() {
        let now = Date(timeIntervalSince1970: 1000)
        var status = Libre2PhoneReadingStatus()
        status.receivedBLEReading(at: now, verifiedUnlockCode: 42)
        let nextReading = now.addingTimeInterval(60)
        status.receivedBLEReading(at: nextReading, verifiedUnlockCode: 42)
        XCTAssertEqual(status.nextFreshnessChange(at: nextReading),
                       nextReading.addingTimeInterval(ConstantsLibre2.recentReadingInterval))
        status = Libre2PhoneReadingStatus()
        XCTAssertNil(status.nextFreshnessChange(at: nextReading))
    }

    func testClockMovingBackSchedulesWhenTheReadingBecomesEligibleAgain() {
        let now = Date(timeIntervalSince1970: 1000)
        var status = Libre2PhoneReadingStatus()
        status.receivedBLEReading(at: now, verifiedUnlockCode: 42)
        XCTAssertEqual(status.nextFreshnessChange(at: now.addingTimeInterval(-60)), now)
        XCTAssertFalse(status.hasRecentReading(at: now.addingTimeInterval(-60)))
        XCTAssertEqual(status.nextFreshnessChange(at: now), now.addingTimeInterval(ConstantsLibre2.recentReadingInterval))
    }

    func testOwnershipNotificationFollowsPersistenceAndSkipsUnchangedState() throws {
        var persisted = Libre2OwnershipRecord()
        let store = Libre2SessionStore { persisted = $0 }
        var observedOwners: [Libre2Owner] = []
        let observer = NotificationCenter.default.addObserver(forName: Libre2SessionStore.didChange, object: store, queue: nil) { _ in
            XCTAssertEqual(store.snapshot, persisted)
            observedOwners.append(store.snapshot.owner)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let value = session()
        try store.prepare(value)
        try store.prepare(value)
        try store.beginPhoneRelease(id: value.id)
        XCTAssertEqual(observedOwners, [.preparingWatch, .releasingPhone])
    }

    func testJournalFailureNotifiesTheChecklistOfBlockedOwnership() {
        let store = Libre2SessionStore { _ in throw Libre2HandoffError.persistence }
        var observedOwners: [Libre2Owner] = []
        let observer = NotificationCenter.default.addObserver(forName: Libre2SessionStore.didChange, object: store, queue: nil) { _ in
            observedOwners.append(store.snapshot.owner)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertThrowsError(try store.prepare(session()))
        XCTAssertEqual(observedOwners, [.failed])
    }

    func testNFCActivityNotifiesTheChecklistWithoutPolling() throws {
        let store = Libre2SessionStore { _ in }
        var observedActivity: [Bool] = []
        let observer = NotificationCenter.default.addObserver(forName: Libre2SessionStore.didChange, object: store, queue: nil) { _ in
            observedActivity.append(store.phoneNFCIsActive)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try store.beginPhoneNFC()
        store.endPhoneNFC()
        store.endPhoneNFC()
        XCTAssertEqual(observedActivity, [true, false])
    }

    func testActivityNotificationsIncludeNewEntriesAndClearButNotDuplicates() throws {
        let suite = "DirectLibreTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = Libre2ActivityLog(defaults: defaults)
        var counts: [Int] = []
        let observer = NotificationCenter.default.addObserver(forName: Libre2ActivityLog.didChange, object: log, queue: nil) { _ in
            counts.append(log.entries.count)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        log.record("Connected")
        log.record("Connected")
        log.record("")
        log.record("Disconnected")
        log.clear()
        log.clear()
        XCTAssertEqual(counts, [1, 2, 0])
    }

}
