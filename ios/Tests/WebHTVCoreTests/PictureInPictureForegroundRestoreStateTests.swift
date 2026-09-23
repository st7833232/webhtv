import Testing
@testable import WebHTVCore

@Test func foregroundWithoutPictureInPictureDoesNothing() {
    var state = PictureInPictureForegroundRestoreState()

    let requested = state.consumeForegroundRequest(isPictureInPictureActive: false)
    #expect(!requested)
}

@Test func activePictureInPictureConsumesOneForegroundRestoreRequest() {
    var state = PictureInPictureForegroundRestoreState()
    state.pictureInPictureWillStart()

    let firstRequest = state.consumeForegroundRequest(isPictureInPictureActive: true)
    let repeatedRequest = state.consumeForegroundRequest(isPictureInPictureActive: true)
    #expect(firstRequest)
    #expect(!repeatedRequest)
}

@Test func repeatedPictureInPictureCyclesDoNotAccumulateRestoreState() {
    var state = PictureInPictureForegroundRestoreState()

    for _ in 0..<2 {
        state.pictureInPictureWillStart()
        let firstRequest = state.consumeForegroundRequest(isPictureInPictureActive: true)
        let repeatedRequest = state.consumeForegroundRequest(isPictureInPictureActive: true)
        #expect(firstRequest)
        #expect(!repeatedRequest)
        state.pictureInPictureDidStop()
        let requestAfterStop = state.consumeForegroundRequest(isPictureInPictureActive: false)
        #expect(!requestAfterStop)
    }
}
