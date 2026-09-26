import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-29. The viewer watches everything at 2× and asked for it to be the starting speed of a new
// title. Each test is one reason a stored value must or must not become that speed.

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "PlaybackSpeedPreferenceTests-\(UUID().uuidString)")!
}

@Test func nothingStoredStartsAtOneTimesAsBefore() {
    // Without a choice the app must behave exactly as 0.1.25 did: a new title at 1×.
    #expect(PlaybackSpeedPreference(defaults: freshDefaults()).defaultSpeed == 1)
}

@Test func everySpeedTheMenuOffersIsKept() {
    let defaults = freshDefaults()
    let preference = PlaybackSpeedPreference(defaults: defaults)
    for speed in PlaybackSpeedPreference.choices {
        preference.setDefaultSpeed(speed)
        // Read through a new value, as the next launch would.
        #expect(PlaybackSpeedPreference(defaults: defaults).defaultSpeed == speed, "\(speed)×")
    }
}

@Test func aSpeedTheMenuDoesNotOfferIsNeverStored() {
    let defaults = freshDefaults()
    let preference = PlaybackSpeedPreference(defaults: defaults)
    preference.setDefaultSpeed(2)
    for speed: Float in [0, -1, 4, 1.75, .nan, .infinity] {
        preference.setDefaultSpeed(speed)
        #expect(preference.defaultSpeed == 2, "\(speed) must not replace the viewer's 2×")
    }
}

@Test func aStoredValueTheMenuDoesNotOfferStartsAtOneTimes() {
    // A hand-edited or future value must not start a title at a speed the player cannot show: a
    // number the menu does not offer, or something that is not a stored speed at all (the reader
    // takes only a number, so the text "2" is not read as 2×).
    let defaults = freshDefaults()
    for stored: Any in [0.0, 7.0, 1.75, 4, "2", Data()] {
        defaults.set(stored, forKey: PlaybackSpeedPreference.key)
        #expect(PlaybackSpeedPreference(defaults: defaults).defaultSpeed == 1, "\(stored)")
    }
}
