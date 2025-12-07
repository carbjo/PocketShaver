//
//  FPSCounter.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-11-30.
//

protocol FPSCounterDelegate: NSObjectProtocol {
	func fpsCounter(_ counter: FPSCounter, didUpdateFramesPerSecond fps: Int)
}

@MainActor
class FPSCounter {
	private var timer: Timer!
	private var internalFpsCounter: FPSCounterObjC

	weak var delegate: FPSCounterDelegate?

	init() {
		internalFpsCounter = objc_getFpsCounter()

		timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
			guard let self else { return }

			Task { @MainActor in
				let fps = internalFpsCounter.reportOneSecondAndFetchFps()
				delegate?.fpsCounter(self, didUpdateFramesPerSecond: fps)
			}
		}
	}
}
