//
//  StikDebugJitManager.swift
//  PocketShaver
//
//  Obtains PowerPC JIT code memory on iOS devices through StikDebug, following
//  https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md
//
//  The emulated CPU picks up the code arena once, when it is created at boot,
//  so the handshake runs before booting. When StikDebug launched the app (with
//  universal.js assigned to it), the arena is requested right at launch while
//  the script is waiting; otherwise Boot opens StikDebug to attach. Without an
//  arena the core keeps the interpreter in charge.
//

import UIKit
import Combine

enum StikDebugJitStatus {
	case enabled
	case notEnabled
	case unknown
}

@MainActor
class StikDebugJitManager {
	enum Change {
		case statusChanged(StikDebugJitStatus)
	}

	enum HandshakeResult {
		case ready
		case stikDebugMissing
		case timedOut
		case failed
		case cancelled
	}

	static let shared = StikDebugJitManager()

	private(set) var status: StikDebugJitStatus = .unknown {
		didSet {
			changeSubject.send(.statusChanged(status))
		}
	}

	let changeSubject = PassthroughSubject<Change, Never>()

	// Covers the trip through StikDebug (and LocalDevVPN) and back
	private let attachTimeout: TimeInterval = 120
	private let pollIntervalNanoseconds: UInt64 = 500_000_000

	// Single in-flight acquisition: jit_ios_acquire must not run concurrently
	private var acquireTask: Task<Bool, Never>?

	var isSupported: Bool {
		jit_ios_supported()
	}

	var isReady: Bool {
		jit_ios_ready()
	}

	var isDebuggerAttached: Bool {
		jit_ios_debugger_attached()
	}

	// Booting with the JIT setting on must first go through the handshake
	var needsHandshake: Bool {
		isSupported && !isReady
	}

	// A debugger attached before launch (StikDebug's app list) is serviced
	// right away, while its script is still waiting for the request
	func acquireIfLaunchedByDebugger() {
		jit_ios_note("launch: supported=\(isSupported) debuggerAttached=\(isDebuggerAttached)")
		guard isSupported, isDebuggerAttached else {
			status = .notEnabled
			return
		}

		Task {
			let wasSuccesful = await acquire()
			self.status = wasSuccesful ? .enabled : .notEnabled
		}
	}

	// Reserves the arena once a debugger is attached, asking StikDebug to
	// attach first when none is
	func enableJit() async -> HandshakeResult {
		let result = await performHandshake()
		jit_ios_note("boot handshake result: \(result)")
		return result
	}

	private func performHandshake() async -> HandshakeResult {
		if !isDebuggerAttached {
			guard let url = stikDebugUrl(withPid: true),
				  await UIApplication.shared.open(url) else {
				return .stikDebugMissing
			}
			jit_ios_note("opened \(url.absoluteString)")

			let deadline = Date().addingTimeInterval(attachTimeout)
			while !isDebuggerAttached {
				if Task.isCancelled {
					return .cancelled
				}
				if Date() > deadline {
					return .timedOut
				}
				try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
			}
		}

		let wasSuccesful = await acquire()
		status = wasSuccesful ? .enabled : .notEnabled

		return wasSuccesful ? .ready : .failed
	}

	private func acquire() async -> Bool {
		if let acquireTask {
			return await acquireTask.value
		}

		// Blocks while the debugger services the prepare request
		let task = Task.detached(priority: .userInitiated) {
			jit_ios_acquire()
		}
		acquireTask = task
		return await task.value
	}

	func stikDebugUrl(withPid: Bool) -> URL? {
		var components = URLComponents()
		components.scheme = "stikdebug"
		components.host = "enable-jit"
		var queryItems: [URLQueryItem] = [
			.init(name: "bundle-id", value: Bundle.main.bundleIdentifier)
		]
		if withPid {
			queryItems.append(.init(name: "pid", value: String(getpid())))
		}
		// TXM devices need StikDebug's script to service the region
		// preparation; without it the prepare request would crash the app
		if jit_ios_needs_prepare_script() {
			queryItems.append(.init(name: "script-name", value: "universal.js"))
		}
		components.queryItems = queryItems
		return components.url
	}
}
