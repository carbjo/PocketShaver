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

		timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
			Task { @MainActor  [weak self] in
				guard let self else { return }
				let fps = self.internalFpsCounter.reportOneSecondAndFetchFps()
				self.delegate?.fpsCounter(self, didUpdateFramesPerSecond: fps)
			}
		}
	}
}
