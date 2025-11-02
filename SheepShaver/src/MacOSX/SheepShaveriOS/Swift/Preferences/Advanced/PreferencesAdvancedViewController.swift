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
		case romSelection
		case hapticFeedback
		case advancedOptions
		case setupInstructions
		case miscellaneous
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

	private func displayForceSelectRomDialogue() {
		let alertVC = UIAlertController(
			title: "Could not validate ROM",
			message: "Validation of the ROM file failed. Use this ROM file anyway?",
			preferredStyle: .alert
		)

		alertVC.addAction(.init(title: "Cancel", style: .default))
		alertVC.addAction(.init(title: "Use anyway", style: .destructive, handler: { [weak self] _ in
			guard let self else { return }
			do {
				try model.forceSelectTmpRom()
				updateRomPicker()
			} catch {
				let forceSelectFailedAlertVC = UIAlertController.withError(error)
				present(forceSelectFailedAlertVC, animated: true)
			}
		}))

		present(alertVC, animated: true)
	}

	private func updateRomPicker() {
		guard model.hasRomFile else {
			return
		}

		let sectionIndex = SectionType.romSelection.sectionIndex(model: model)
		let indexPath = IndexPath(row: 0, section: sectionIndex)

		guard let cell = tableView.cellForRow(at: indexPath) as? PreferencesAdvancedRomCell else {
			return
		}

		cell.configure(with: model.currentRomFileType)

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
		case .romSelection:
			return 1
		case .hapticFeedback:
			return 3
		case .advancedOptions:
			return model.optionsInitialStates.count
		case .setupInstructions:
			return 1
		case .miscellaneous:
			return 1
		}
	}

	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		let sectionType = SectionType(sectionIndex: indexPath.section, model: model)
		switch sectionType {
		case .romSelection:
			return PreferencesAdvancedRomCell(
				romType: model.currentRomFileType,
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
		case .miscellaneous:
			return PreferencesAdvancedMiscellaneousCell(
				title: "Licenses"
			)
		}
	}

	override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
		let sectionType = SectionType(sectionIndex: section, model: model)
		switch sectionType {
		case .romSelection:
			return "ROM selection"
		case .hapticFeedback:
			return "Haptic feedback"
		case .advancedOptions:
			return "Advanced options"
		case .setupInstructions:
			return "Setup instructions"
		case .miscellaneous:
			return "Miscellaneous"
		}
	}

	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		let sectionType = SectionType(sectionIndex: indexPath.section, model: model)
		return sectionType == .miscellaneous
	}

	override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		tableView.deselectRow(at: indexPath, animated: true)

		let sectionType = SectionType(sectionIndex: indexPath.section, model: model)
		switch sectionType {
		case .miscellaneous:
			switch indexPath.row {
			case 0:
				let vc = PreferencesLicensesViewController()
				let navVC = UINavigationController()
				navVC.viewControllers = [vc]

				present(navVC, animated: true)
			default:
				break
			}
		default:
			break
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
			do {
				try await model.didSelectMacOsInstallDiskCandidate(url: url)
				updateRomPicker()
			} catch RomError.couldNotValidateRom {
				displayForceSelectRomDialogue()
			} catch {
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
		   let romSectionIndex = sections.firstIndex(of: .romSelection) {
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
