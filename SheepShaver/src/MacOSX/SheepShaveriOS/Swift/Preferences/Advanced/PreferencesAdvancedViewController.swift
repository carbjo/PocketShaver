//
//  PreferencesAdvancedViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

import UIKit

class PreferencesAdvancedViewController: UITableViewController {
	enum SectionType: CaseIterable {
		case romSelection
		case options
		case setupInstructions
	}

	private let model = PreferencesAdvancedModel()

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
		case .options:
			return model.optionsInitialStates.count
		case .setupInstructions:
			return 1
		}
	}

	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		let sectionType = SectionType(sectionIndex: indexPath.section, model: model)
		switch sectionType {
		case .romSelection:
			return PreferencesAdvancedRomCell(
				romType: model.currentRomFileType,
				didTapSelectRomButton: { [weak self] in
					self?.displayRomPicker()
				}
			)
		case .options:
			let optionInitialState = model.optionsInitialStates[indexPath.row]

			return PreferencesAdvancedOptionCell(optionInitialState: optionInitialState) { [weak self] isOn in
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
		}
	}

	override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
		let sectionType = SectionType(sectionIndex: section, model: model)
		switch sectionType {
		case .romSelection:
			return "ROM selection"
		case .options:
			return "Advanced options"
		case .setupInstructions:
			return "Setup instructions"
		}
	}

	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		false
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
				try await model.didSelectRomCandidate(url: url)
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

		return sections
	}
}
