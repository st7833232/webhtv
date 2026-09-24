import CoreGraphics
import Testing
@testable import WebHTVCore

// MARK: - The bar and its panels (IOS-POC-16B)

@Test func anOpenPanelStopsTheAutoHideAndKeepsTheBar() {
    var chrome = PlayerChrome()
    #expect(chrome.autoHideArmed)

    chrome.toggle(.speed)
    #expect(chrome.panel == .speed)
    #expect(!chrome.autoHideArmed)
    // The device report: the countdown ran out under an open menu and the bar took the menu with it.
    chrome.autoHideFired(isPlaying: true)
    #expect(chrome.controlsVisible)
    #expect(chrome.panel == .speed)

    // Closed, the countdown is allowed again — and hides a playing bar when it fires.
    chrome.dismissPanel()
    #expect(chrome.autoHideArmed)
    chrome.autoHideFired(isPlaying: true)
    #expect(!chrome.controlsVisible)
}

@Test func onlyOnePanelIsOpenAndItsOwnButtonClosesIt() {
    var chrome = PlayerChrome()
    chrome.toggle(.speed)
    chrome.toggle(.quality)
    #expect(chrome.panel == .quality)
    chrome.toggle(.quality)
    #expect(chrome.panel == nil)
    #expect(chrome.controlsVisible)
}

@Test func aTapOnThePictureClosesThePanelBeforeItTogglesTheBar() {
    var chrome = PlayerChrome()
    chrome.toggle(.opening)
    chrome.tapBackground()
    #expect(chrome.panel == nil)
    #expect(chrome.controlsVisible)
    chrome.tapBackground()
    #expect(!chrome.controlsVisible)
    chrome.tapBackground()
    #expect(chrome.controlsVisible)
}

@Test func aPausedPlayerKeepsItsBar() {
    var chrome = PlayerChrome()
    chrome.autoHideFired(isPlaying: false)
    #expect(chrome.controlsVisible)
}

@Test func aPanelIsNeverShownOverAHiddenBar() {
    var chrome = PlayerChrome()
    chrome.tapBackground()
    #expect(!chrome.controlsVisible)
    chrome.toggle(.engine)
    #expect(chrome.controlsVisible)
}

// MARK: - Placement

@Test func portraitGetsASheetNoTallerThanTheLetterboxUnderA16x9Picture() {
    // iPhone 15/16 Pro portrait: 393 × 852 with 59/34 pt insets, so a 393 × 759 safe area.
    let placement = PlayerPanelPlacement.placement(in: CGSize(width: 393, height: 759))
    guard case .bottom(let maxHeight, let clearance) = placement else {
        Issue.record("expected a bottom sheet, got \(placement)")
        return
    }
    #expect(abs(maxHeight - (759 - 393 * 9.0 / 16) / 2) < 0.01)
    #expect(clearance == 0)
    // The sheet's top edge, in screen coordinates, is below the bottom of the picture centred on
    // the whole 852 pt screen — the uneven insets only add clearance.
    let sheetTop = 59 + 759 - maxHeight
    let pictureBottom = (852 + 393 * 9.0 / 16) / 2
    #expect(sheetTop >= pictureBottom)
}

@Test func aTinyLetterboxStillLeavesAUsableSheet() {
    let placement = PlayerPanelPlacement.placement(in: CGSize(width: 393, height: 500))
    #expect(placement == .bottom(maxHeight: PlayerPanelPlacement.minimumSheetHeight, clearance: 0))
}

@Test func landscapeGetsATrailingDrawerBetween260And320() {
    #expect(PlayerPanelPlacement.placement(in: CGSize(width: 852, height: 393))
            == .trailing(width: 852 * 0.34))
    // iPhone SE landscape: 0.34 × 667 is under the floor, and the floor still leaves 61 % visible.
    #expect(PlayerPanelPlacement.placement(in: CGSize(width: 667, height: 375))
            == .trailing(width: 260))
    #expect(PlayerPanelPlacement.placement(in: CGSize(width: 1400, height: 1000))
            == .trailing(width: 320))
}

@Test func aNarrowLandscapeFallsBackToALowPanelAboveTheSubtitles() {
    // iPhone SE with Display Zoom, landscape: a 260 pt drawer would leave only 54 % of the picture.
    let placement = PlayerPanelPlacement.placement(in: CGSize(width: 568, height: 320))
    guard case .bottom(let maxHeight, let clearance) = placement else {
        Issue.record("expected a low bottom panel, got \(placement)")
        return
    }
    #expect(clearance >= 320 * PlayerPanelPlacement.subtitleBand)
    #expect(maxHeight <= 320 * 0.4)
}
