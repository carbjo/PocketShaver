//
//  PerformanceCounter.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-11-30.
//

protocol PerformanceCounterDelegate: NSObjectProtocol {
	func performanceCounter(_ counter: PerformanceCounter, didUpdateWithReport report: PerformanceCounterReport)
}

@MainActor
class PerformanceCounter {
	private var timer: Timer!
	private var internalPerformanceCounter: PerformanceCounterObjC

	weak var delegate: PerformanceCounterDelegate?

	init() {
		internalPerformanceCounter = objc_getPerformanceCounter()

		timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
			Task { @MainActor  [weak self] in
				guard let self else { return }
				let report = self.internalPerformanceCounter.reportOneSecondAndFetchReport()
				self.delegate?.performanceCounter(self, didUpdateWithReport: report)
			}
		}
	}
}

@objcMembers
class PerformanceCounterReport: NSObject {
	let framesRendered: Int
	let bytesTransferred: Int

	init(
		framesRendered: Int,
		bytesTransferred: Int
	) {
		self.framesRendered = framesRendered
		self.bytesTransferred = bytesTransferred
	}

	var bytesTransferredString: String {
		if bytesTransferred < (1024) {
			let bps = bytesTransferred
			return "\(bps) B/s"
		} else if bytesTransferred < (1024*1024) {
			let kbps = bytesTransferred / 1024
			return "\(kbps) kB/s"
		} else {
			let mbps = bytesTransferred / (1024*1024)
			return "\(mbps) MB/s"
		}
	}
}
