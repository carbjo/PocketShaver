//
//  PreferencesAdvancedViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

import UIKit
import Combine

class PreferencesAdvancedViewController: UITableViewController {
	enum SectionType: CaseIterable {
		case bootstrap
		case hapticFeedback
		case advancedOptions
		case setupInstructions
		case resources
	}

	private let model: PreferencesAdvancedModel

	init(changeSubject: PassthroughSubject<PreferencesChange, Never>) {
		model = .init(changeSubject: changeSubject)

		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) { fatalError() }

	override func viewDidLoad() {
		super.viewDidLoad()

		view.translatesAutoresizingMaskIntoConstraints = false
		view.backgroundColor = .white
	}

	private func displayRomPicker() {
		let pickerVC = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
		pickerVC.delegate = self

		present(pickerVC, animated: true)
	}

	private func displaySuccesfulBoostrapDialogue() {
		let alertVC = UIAlertController(
			title: "Success",
			message: "PocketShaver is bootstrapped again with your new file.",
			preferredStyle: .alert
		)

		alertVC.addAction(.init(title: "Ok", style: .default))

		present(alertVC, animated: true)
	}

	private func displayNoRomFoundDialogue() {
		let alertVC = UIAlertController(
			title: "Mac OS install disc image not compatible",
			message: "The provided file is not a compatible Mac OS install disc image for bootstrapping PocketShaver. Check 'Compatibility list' for guidence.",
			preferredStyle: .alert
		)

		alertVC.addAction(.init(title: "Ok", style: .default))

		present(alertVC, animated: true)
	}

	private func displayIncompatibleRomFoundDialogue(_ romType: NewWorldRomVersion) {
		let alertVC = UIAlertController(
			title: "Mac OS install disc image not compatible",
			message: "The provided file is a Mac OS disk install image, but is not compatible for bootstrapping PocketShaver. The file is identified as category '\(romType.description)'. Check 'Compatibility list' for guidence.",
			preferredStyle: .alert
		)

		alertVC.addAction(.init(title: "Ok", style: .default))

		present(alertVC, animated: true)
	}

	private func updateBootstrapCell() {
		guard model.hasRomFile else {
			return
		}

		let sectionIndex = SectionType.bootstrap.sectionIndex(model: model)
		let indexPath = IndexPath(row: 0, section: sectionIndex)

		guard let cell = tableView.cellForRow(at: indexPath) as? PreferencesAdvancedBootstrapCell else {
			return
		}

		cell.configure(with: model.currentRomFileDescription!)

		tableView.beginUpdates()
		tableView.endUpdates()
	}
}

extension PreferencesAdvancedViewController { // UITableViewDataSource, UITableViewDelegate

	override func numberOfSections(in tableView: UITableView) -> Int {
		SectionType.count(model: model)
	}

	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		let sectionType = SectionType(sectionIndex: section, model: model)
		switch sectionType {
		case .bootstrap:
			return 1
		case .hapticFeedback:
			return 3
		case .advancedOptions:
			return model.optionsInitialStates.count
		case .setupInstructions:
			return 1
		case .resources:
			return 2
		}
	}

	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		let sectionType = SectionType(sectionIndex: indexPath.section, model: model)
		switch sectionType {
		case .bootstrap:
			return PreferencesAdvancedBootstrapCell(
				romDescription: model.currentRomFileDescription!,
				didTapSelectInstallDiskButton: { [weak self] in
					self?.displayRomPicker()
				}
			)
		case .hapticFeedback:
			switch indexPath.row {
			case 0:
				return PreferencesAdvancedOptionCell(
					title: "Three / two finger swipe gestures",
					isOn: model.isGestureHapticFeedbackOn
				) { [weak self] isOn in
					self?.model.isGestureHapticFeedbackOn = isOn
				}
			case 1:
				return PreferencesAdvancedOptionCell(
					title: "Mouse clicks",
					isOn: model.isMouseHapticFeedbackOn
				) { [weak self] isOn in
					self?.model.isMouseHapticFeedbackOn = isOn
				}
			case 2:
				return PreferencesAdvancedOptionCell(
					title: "Gamepad key strokes",
					isOn: model.isKeyHapticFeedbackOn
				) { [weak self] isOn in
					self?.model.isKeyHapticFeedbackOn = isOn
				}
			default:
				fatalError()
			}
		case .advancedOptions:
			let optionInitialState = model.optionsInitialStates[indexPath.row]

			return PreferencesAdvancedOptionCell(
				title: optionInitialState.option.title,
				isOn: optionInitialState.isOn
			) { [weak self] isOn in
				guard let self else { return }
				model.didSet(option: optionInitialState.option, isOn: isOn)
			}
		case .setupInstructions:
			return PreferencesGeneralSetupInstructionsCell(
				mode: .advanced,
				didTapReadButton: { [weak self] in
					guard let self else { return }
					let vc = PreferencesSetupInstructionsViewController()
					let navVC = UINavigationController()
					navVC.viewControllers = [vc]

					present(navVC, animated: true)
				},
				didTapCloseButton: {
				}
			)
		case .resources:
			switch indexPath.row {
			case 0:
				return PreferencesAdvancedMiscellaneousCell(
					title: "Bootstrap compatibility list"
				)
			case 1:
				return PreferencesAdvancedMiscellaneousCell(
					title: "Licenses"
				)
			default: fatalError()
			}
		}
	}

	override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
		let sectionType = SectionType(sectionIndex: section, model: model)
		switch sectionType {
		case .bootstrap:
			return "Bootstrap"
		case .hapticFeedback:
			return "Haptic feedback"
		case .advancedOptions:
			return "Advanced options"
		case .setupInstructions:
			return "Setup instructions"
		case .resources:
			return "Resources"
		}
	}

	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		let sectionType = SectionType(sectionIndex: indexPath.section, model: model)
		return sectionType == .resources
	}

	override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		tableView.deselectRow(at: indexPath, animated: true)

		let sectionType = SectionType(sectionIndex: indexPath.section, model: model)
		switch sectionType {
		case .resources:
			switch indexPath.row {
			case 0:
				let vc = PreferencesCompatibilityListViewController()
				let navVC = UINavigationController()
				navVC.viewControllers = [vc]

				present(navVC, animated: true)
			case 1:
				let vc = PreferencesLicensesViewController()
				let navVC = UINavigationController()
				navVC.viewControllers = [vc]

				present(navVC, animated: true)
			default: fatalError()
			}
		default: fatalError()
		}
	}
}

extension PreferencesAdvancedViewController: UIDocumentPickerDelegate {
	func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
		guard let url = urls.first else {
			return
		}

		Task { [weak self, model] in
			guard let self else { return }
			let validationResult = await model.didSelectMacOsInstallDiskCandidate(url: url)
			switch validationResult {
			case .success:
				displaySuccesfulBoostrapDialogue()
				updateBootstrapCell()
			case .incompatibleRom(let newWorldRomVersion):
				displayIncompatibleRomFoundDialogue(newWorldRomVersion)
			case .invalidFile:
				displayNoRomFoundDialogue()
			case .error(let error):
				let errorVC = UIAlertController.withError(error)
				present(errorVC, animated: true)
			}
		}
	}
}

extension PreferencesAdvancedViewController.SectionType {
	@MainActor
	init(sectionIndex: Int, model: PreferencesAdvancedModel) {
		let sections = Self.availableSections(with: model)
		self = sections[sectionIndex]
	}

	@MainActor
	static func count(model: PreferencesAdvancedModel) -> Int {
		let sections = Self.availableSections(with: model)
		return sections.count
	}

	@MainActor
	func sectionIndex(model: PreferencesAdvancedModel) -> Int {
		let sections = Self.availableSections(with: model)
		return sections.firstIndex(of: self)!
	}

	@MainActor
	private static func availableSections(with model: PreferencesAdvancedModel) -> [Self] {
		var sections = allCases
		if !model.hasRomFile,
		   let romSectionIndex = sections.firstIndex(of: .bootstrap) {
			sections.remove(at: romSectionIndex)
		}
		if !model.hasDismissedSetupInstructions,
		   let setupInstructionsSectionIndex = sections.firstIndex(of: .setupInstructions) {
			sections.remove(at: setupInstructionsSectionIndex)
		}
		if !model.supportsHaptics,
		   let hapticsFeedbackSectionIndex = sections.firstIndex(of: .hapticFeedback) {
			sections.remove(at: hapticsFeedbackSectionIndex)
		}

		return sections
	}
}
