import XCTest
@testable import LootDomain

final class PersonIDTests: XCTestCase {

    func testRawValueInit() {
        let id = PersonID(rawValue: "abc-123")
        XCTAssertEqual(id.rawValue, "abc-123")
    }

    func testShorthandInit() {
        let id = PersonID("xyz-789")
        XCTAssertEqual(id.rawValue, "xyz-789")
    }

    func testNewGuestUnique() {
        let a = PersonID.newGuest()
        let b = PersonID.newGuest()
        XCTAssertNotEqual(a.rawValue, b.rawValue)
        XCTAssertFalse(a.rawValue.isEmpty)
    }

    func testEqualityByRawValue() {
        XCTAssertEqual(PersonID("foo"), PersonID("foo"))
        XCTAssertNotEqual(PersonID("foo"), PersonID("bar"))
    }

    func testHashable() {
        let set: Set<PersonID> = [PersonID("a"), PersonID("a"), PersonID("b")]
        XCTAssertEqual(set.count, 2)
    }

    func testCodableEncodesAsString() throws {
        let id = PersonID("hello")
        let data = try JSONEncoder().encode(id)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"hello\"")
    }

    func testCodableDecodesFromString() throws {
        let data = "\"hello\"".data(using: .utf8)!
        let id = try JSONDecoder().decode(PersonID.self, from: data)
        XCTAssertEqual(id.rawValue, "hello")
    }
}

final class PersonTests: XCTestCase {

    func testBasicConstruction() {
        let p = Person(id: PersonID("u1"), displayName: "Alice", userId: "key-123")
        XCTAssertEqual(p.id.rawValue, "u1")
        XCTAssertEqual(p.displayName, "Alice")
        XCTAssertEqual(p.userId, "key-123")
    }

    func testGuestHasNoUserId() {
        let p = Person(id: PersonID("g1"), displayName: "Bob")
        XCTAssertNil(p.userId)
    }

    func testNewGuestHelper() {
        let p = Person.newGuest(displayName: "Charlie")
        XCTAssertEqual(p.displayName, "Charlie")
        XCTAssertNil(p.userId)
        XCTAssertFalse(p.id.rawValue.isEmpty)
    }

    func testIsMeMatchesLocalUserId() {
        let p = Person(id: PersonID("p1"), displayName: "Me", userId: "local-uid")
        XCTAssertTrue(p.isMe(localUserId: "local-uid"))
        XCTAssertFalse(p.isMe(localUserId: "other-uid"))
    }

    func testIsMeFalseForGuest() {
        let p = Person(id: PersonID("p1"), displayName: "Stranger", userId: nil)
        XCTAssertFalse(p.isMe(localUserId: "any-uid"))
    }

    func testIsMeFalseForEmptyUserId() {
        let p = Person(id: PersonID("p1"), displayName: "Empty", userId: "")
        XCTAssertFalse(p.isMe(localUserId: ""))
    }

    func testResolvedDisplayNameTrimsWhitespace() {
        let p = Person(id: PersonID("p1"), displayName: "   Alice   ")
        XCTAssertEqual(p.resolvedDisplayName(), "Alice")
    }

    func testResolvedDisplayNameMeFallbackForKnownUser() {
        let p = Person(id: PersonID("p1"), displayName: "", userId: "keychain-id")
        XCTAssertEqual(p.resolvedDisplayName(), "Me")
    }

    func testResolvedDisplayNameGuestFallback() {
        let p = Person(id: PersonID("p1"), displayName: "", userId: nil)
        XCTAssertEqual(p.resolvedDisplayName(guestIndex: 2), "Guest 3")
    }

    func testCodableRoundTrip() throws {
        let original = Person(id: PersonID("u1"), displayName: "Alice", userId: "kc-1")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Person.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCodableNilUserIdOmitted() throws {
        // userId: nil should round-trip cleanly
        let original = Person.newGuest(displayName: "Guest")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Person.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.displayName, "Guest")
        XCTAssertNil(decoded.userId)
    }

    func testIdentifiedDerivesPersonIDFromUserId() {
        let p = Person.identified(userId: "keychain-abc", displayName: "Alice")
        XCTAssertEqual(p.id.rawValue, "keychain-abc")
        XCTAssertEqual(p.userId, "keychain-abc")
        XCTAssertEqual(p.displayName, "Alice")
    }

    func testIdentifiedRoundTripsToSamePersonID() {
        let a = Person.identified(userId: "kc-1", displayName: "Alice")
        let b = Person.identified(userId: "kc-1", displayName: "Alice (renamed)")
        XCTAssertEqual(a.id, b.id, "PersonID should be stable across separate identified() calls with the same userId")
    }

    func testFromWireSlotWithNonNilUidIsStable() {
        let p = Person.fromWireSlot(uid: "kc-2", displayName: "Bob")
        XCTAssertEqual(p.id.rawValue, "kc-2")
        XCTAssertEqual(p.userId, "kc-2")
    }

    func testFromWireSlotWithNilUidGeneratesFreshAnonymousID() {
        let a = Person.fromWireSlot(uid: nil, displayName: "Anon")
        let b = Person.fromWireSlot(uid: nil, displayName: "Anon")
        XCTAssertNotEqual(a.id, b.id, "Anonymous slots should get fresh PersonIDs per call")
        XCTAssertNil(a.userId)
        XCTAssertNil(b.userId)
    }

    func testFromWireSlotWithEmptyUidGeneratesFreshAnonymousID() {
        let p = Person.fromWireSlot(uid: "", displayName: "Empty")
        XCTAssertNil(p.userId)
        XCTAssertFalse(p.id.rawValue.isEmpty)
    }

    func testEqualityRequiresAllFieldsMatch() {
        let a = Person(id: PersonID("u1"), displayName: "Alice", userId: "kc")
        let b = Person(id: PersonID("u1"), displayName: "Alice", userId: "kc")
        XCTAssertEqual(a, b)

        // Different userId
        let c = Person(id: PersonID("u1"), displayName: "Alice", userId: "kc-different")
        XCTAssertNotEqual(a, c)

        // Different name
        let d = Person(id: PersonID("u1"), displayName: "Bob", userId: "kc")
        XCTAssertNotEqual(a, d)

        // Different id
        let e = Person(id: PersonID("u2"), displayName: "Alice", userId: "kc")
        XCTAssertNotEqual(a, e)
    }
}
