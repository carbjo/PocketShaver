//
//  PreferencesGeneralViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

import UIKit
import Combine

class PreferencesGeneralViewController: UITableViewController {
	enum SectionType: Int, CaseIterable {
		case rom
		case disks
		case ramStepper
		case iPadMouse
	}

	enum CreateDiskFieldIndex: Int {
		case name
		case size
	}

	enum FilePickerSource: Int {
		case romSelection
		case fileImport
	}

	private let model: PreferencesGeneralModel

	private var createDiskDialogueNamePhantomLabel: UILabel?
	private var createDiskDialogueNameSuffixLabel: UILabel?
	private var createDiskDialogueSizePhantomLabel: UILabel?
	private var createDiskDialogueSizeUnitLabel: UILabel?

	init(changeSubject: PassthroughSubject<PreferencesChange, Never>) {
		model = .init(changeSubject: changeSubject)

		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) { fatalError() }

	override func viewDidLoad() {
		super.viewDidLoad()

		view.translatesAutoresizingMaskIntoConstraints = false
		view.backgroundColor = .white

		tableView.showsVerticalScrollIndicator = false
		tableView.delaysContentTouches = false
	}

	func presentRomFileMissingError() {
		let sectionIndex = SectionType.rom.sectionIndex(model: model)
		let romCellIndexPath = IndexPath(row: 0, section: sectionIndex)

		let shouldAddRow = !model.isDisplayingRomFileMissingError

		model.isDisplayingRomFileMissingError = true

		let romErrorCellIndexPath = IndexPath(row: 1, section: sectionIndex)

		tableView.performBatchUpdates {
			tableView.scrollToRow(at: romCellIndexPath, at: .top, animated: true)
			if shouldAddRow {
				tableView.insertRows(at: [romErrorCellIndexPath], with: .fade)
			}
		}
	}

	func presentNoDiskFilesError() {
		let sectionIndex = SectionType.disks.sectionIndex(model: model)
		let diskCellsIndexPath = IndexPath(row: 0, section: sectionIndex)

		let shouldAddRow = !model.isDisplayingNoDiskFilesError

		model.isDisplayingNoDiskFilesError = true

		tableView.performBatchUpdates {
			tableView.scrollToRow(at: diskCellsIndexPath, at: .top, animated: true)
			if shouldAddRow {
				let disksMissingErrorIndexPath = IndexPath(row: 2, section: sectionIndex)
				tableView.insertRows(at: [disksMissingErrorIndexPath], with: .fade)
			}
		}
	}

	// MARK: - ROM picker

	private func displayRomPicker() {
		let pickerVC = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
		pickerVC.delegate = self
		pickerVC.view.tag = FilePickerSource.romSelection.rawValue

		present(pickerVC, animated: true)
	}

	private func animateRomFound() {
		guard let cell = tableView.cellForRow(at: IndexPath(row: 0, section: 0)) as? PreferencesGeneralRomCell else {
			return
		}

		cell.displayCheckmark()

		DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
			self.tableView.deleteSections(IndexSet([0]), with: .fade)
		}
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
				animateRomFound()
			} catch {
				let forceSelectFailedAlertVC = UIAlertController.withError(error)
				present(forceSelectFailedAlertVC, animated: true)
			}
		}))

		present(alertVC, animated: true)
	}

	// MARK: - Create disk

	private func displayCreateDiskDialogue() {
		let alertVC = UIAlertController(
			title: "Create new disk",
			message: "Choose name and size",
			preferredStyle: .alert
		)
		alertVC.addTextField { [weak self] textField in
			guard let self else { return }

			textField.tag = CreateDiskFieldIndex.name.rawValue
			textField.placeholder = "DiskName.dsk"
			textField.autocapitalizationType = .sentences

			let phantomLabel = UILabel.withoutConstraints()
			phantomLabel.font = textField.font
			phantomLabel.isHidden = true

			let suffixLabel = UILabel.withoutConstraints()
			suffixLabel.font = textField.font
			suffixLabel.text = ".dsk"
			suffixLabel.isHidden = true

			textField.addSubview(phantomLabel)
			textField.addSubview(suffixLabel)

			NSLayoutConstraint.activate([
				phantomLabel.leadingAnchor.constraint(equalTo: textField.leadingAnchor),
				phantomLabel.centerYAnchor.constraint(equalTo: textField.centerYAnchor),

				suffixLabel.leadingAnchor.constraint(equalTo: phantomLabel.trailingAnchor),
				suffixLabel.centerYAnchor.constraint(equalTo: textField.centerYAnchor)
			])

			textField.delegate = self

			self.createDiskDialogueNamePhantomLabel = phantomLabel
			self.createDiskDialogueNameSuffixLabel = suffixLabel
		}

		alertVC.addTextField { [weak self] textField in
			guard let self else { return }

			textField.tag = CreateDiskFieldIndex.size.rawValue
			textField.placeholder = "0"
			textField.keyboardType = .numberPad

			let phantomLabel = UILabel.withoutConstraints()
			phantomLabel.text = "0"
			phantomLabel.font = textField.font
			phantomLabel.isHidden = true

			let unitLabel = UILabel.withoutConstraints()
			unitLabel.text = "MB"
			unitLabel.font = textField.font
			unitLabel.textColor = .gray

			textField.addSubview(phantomLabel)
			textField.addSubview(unitLabel)

			NSLayoutConstraint.activate([
				phantomLabel.leadingAnchor.constraint(equalTo: textField.leadingAnchor),
				phantomLabel.centerYAnchor.constraint(equalTo: textField.centerYAnchor),

				unitLabel.leadingAnchor.constraint(equalTo: phantomLabel.trailingAnchor, constant: 4),
				unitLabel.centerYAnchor.constraint(equalTo: textField.centerYAnchor)
			])

			textField.delegate = self

			self.createDiskDialogueSizePhantomLabel = phantomLabel
			self.createDiskDialogueSizeUnitLabel = unitLabel
		}

		alertVC.addAction(.init(title: "Cancel", style: .cancel, handler: { [weak self] _ in
			guard let self else { return }

			createDiskDialogueNamePhantomLabel = nil
			createDiskDialogueNameSuffixLabel = nil
		}))
		alertVC.addAction(.init(title: "Create", style: .default, handler: { [weak self] action in
			guard let self else { return }

			createDiskDialogueNamePhantomLabel = nil
			createDiskDialogueNameSuffixLabel = nil

			let name = alertVC.textFields?[0].text ?? ""
			let sizeString = alertVC.textFields?[1].text ?? ""
			let size = Int(sizeString) ?? 0
			do {
				let diskDataChange = try model.createNewDisk(name: name, sizeInMb: size)
				animateDiskDataChange(diskDataChange)
			} catch PreferencesGeneralError.fileCreationInvalidSize {
				let invalidSizeAlertVC = UIAlertController.withMessage("An invalid file size was given")
				present(invalidSizeAlertVC, animated: true)
			} catch PreferencesGeneralError.fileWithFilenameAleadyExists {
				let fileExistsAlertVC = UIAlertController.withMessage("A file with that name already exists")
				present(fileExistsAlertVC, animated: true)
			} catch {
				let otherErrorAlertVC = UIAlertController.withMessage("Something went wrong when trying to create the file")
				present(otherErrorAlertVC, animated: true)
			}
		}))

		present(alertVC, animated: true)
	}

	private func animateDiskDataChange(_ diskDataChange: DiskDataChange) {
		let sectionIndex = SectionType.disks.sectionIndex(model: model)

		let startsDisplayingEmptyState = model.numberOfDisks == 0
		let stopsDisplayingEmptyState = model.numberOfDisks == diskDataChange.inserted.count

		tableView.performBatchUpdates {
			if startsDisplayingEmptyState || stopsDisplayingEmptyState {
				// Replace the empty state cell
				let columnsDescriptionIndexPath = IndexPath(row: 0, section: sectionIndex)
				tableView.reloadRows(at: [columnsDescriptionIndexPath], with: .fade)
			}

			tableView.insertRows(at: diskDataChange.inserted.map({ IndexPath(row: 1 + $0, section: sectionIndex) }), with: .fade)
			tableView.reloadRows(at: diskDataChange.updated.map({ IndexPath(row: 1 + $0, section: sectionIndex) }), with: .fade)
			tableView.deleteRows(at: diskDataChange.removed.map({ IndexPath(row: 1 + $0, section: sectionIndex) }), with: .fade)
		}

		let diskActionsRowIndex = model.numberOfDisks + 1
		let diskActionsIndexPath = IndexPath(row: diskActionsRowIndex, section: sectionIndex)
		if let cell = tableView.cellForRow(at: diskActionsIndexPath) as? PreferencesGeneralDiskSectionActionsCell {
			cell.setupForHasDskFile(model.hasDskFile, animated: true)
		}
 	}

	private func reloadFileList() {
		Task { [weak self] in
			guard let self else { return }
			let diskDataChange = try await model.didSelectReload()
			animateDiskDataChange(diskDataChange)
		}
	}

	// MARK: - File import

	private func displayFileImport() {
		let pickerVC = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
		pickerVC.delegate = self
		pickerVC.view.tag = FilePickerSource.fileImport.rawValue

		present(pickerVC, animated: true)
	}
}

// MARK: - UITextFieldDelegate

extension PreferencesGeneralViewController: UITextFieldDelegate {
	func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
		let currentString = (textField.text ?? "") as NSString
		let newString = currentString.replacingCharacters(in: range, with: string)

		switch CreateDiskFieldIndex(rawValue: textField.tag)! {
		case .name:
			createDiskDialogueNamePhantomLabel?.text = newString
			createDiskDialogueNameSuffixLabel?.isHidden = newString.isEmpty
		case .size:
			createDiskDialogueSizePhantomLabel?.text = newString.isEmpty ? "0" : newString
		}

		return true
	}
}

// MARK: - UITableViewDataSource

extension PreferencesGeneralViewController {
	override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
		let sectionType = SectionType(sectionIndex: section, model: model)
		switch sectionType {
		case .rom:
			return "ROM selection"
		case .disks:
			return "Disks"
		case .ramStepper:
			return "RAM setting"
		case .iPadMouse:
			return "Input mode"
		}
	}

	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		let sectionType = SectionType(sectionIndex: section, model: model)
		switch sectionType {
		case .rom:
			return 1 + (model.isDisplayingRomFileMissingError ? 1 : 0)
		case .disks:
			return model.numberOfDisks + 2 + (model.isDisplayingNoDiskFilesError ? 1 : 0)
		case .ramStepper:
			return 1
		case .iPadMouse:
			return 1
		}
	}

	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		let sectionType = SectionType(sectionIndex: indexPath.section, model: model)
		switch sectionType {
		case .rom:
			if indexPath.row == 0 {
				return PreferencesGeneralRomCell(
					didTapSelectRomButton: { [weak self] in
						self?.displayRomPicker()
					}
				)
			} else {
				return PreferencesGeneralErrorCell(title: "You need to select a ROM file")
			}
		case .disks:
			if indexPath.row == 0, model.numberOfDisks == 0 {
				return PreferencesGeneralDiskEmptyStateCell()
			} else if indexPath.row == 0 {
				return PreferencesGeneralDiskColumnsDescriptionCell()
			} else if indexPath.row <= model.numberOfDisks {
				let index = indexPath.row - 1
				let disk = model.disk(forIndex: index)
				return PreferencesGeneralDiskCell(
					disk: disk,
					didSetIsEnabled: { [weak self] filename, isOn in
						self?.model.setDiskEnabled(filename: filename, isEnabled: isOn)
					},
					didSetIsCdRom: { [weak self] filename, isOn in
						self?.model.setDiskAsCdRom(filename: filename, isCdRom: isOn)
					}
				)
			} else if indexPath.row == model.numberOfDisks + 1 {
				return PreferencesGeneralDiskSectionActionsCell(
					hasDskFile: model.hasDskFile,
					didTapCreateDiskButton: { [weak self] in
						self?.displayCreateDiskDialogue()
					},
					didTapReloadDisksButton: { [weak self] in
						self?.reloadFileList()
					},
					didTapImportDiskButton: { [weak self] in
						self?.displayFileImport()
					}
				)
			} else {
				return PreferencesGeneralErrorCell(title: "Must select to mount at least one disk file")
			}
		case .ramStepper:
			return PreferencesGeneralRamStepperCell(
				initialRamSettting: .current
			) { [weak self] newValue in
				self?.model.ramSetting = newValue
			}
		case .iPadMouse:
			return PreferencesGeneralIPadMouseCell(
				initialIPadMouseSetting: model.isIPadMouseEnabled
			) { [weak self] newValue in
				self?.model.isIPadMouseEnabled = newValue
			}
		}
	}

	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		false
	}

	override func numberOfSections(in tableView: UITableView) -> Int {
		let res = SectionType.count(model: model)
		return res
	}
}

// MARK: - UIDocumentPickerDelegate

extension PreferencesGeneralViewController: UIDocumentPickerDelegate {
	func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
		guard let url = urls.first else {
			return
		}

		switch FilePickerSource(rawValue: controller.view.tag)! {
		case .romSelection:
			Task { [weak self, model] in
				guard let self else { return }
				do {
					try await model.didSelectRomCandidate(url: url)
					animateRomFound()
				} catch PreferencesGeneralError.couldNotValidateRom {
					displayForceSelectRomDialogue()
				} catch {
					let errorVC = UIAlertController.withError(error)
					present(errorVC, animated: true)
				}
			}
		case .fileImport:
			Task { [weak self, model] in
				guard let self else { return }
				do {
					let diskDataChange = try await model.didSelectFileImport(url: url)
					animateDiskDataChange(diskDataChange)
				} catch PreferencesGeneralError.fileImportWrongSuffix {
					let supportedFormatsString = DiskManager.supportedFileExtensions.map({ ".\($0)" }).joined(separator: ", ")
					let wrongSuffixAlertVC = UIAlertController.withMessage("The file has an unsupported suffix. The supported suffixes are \(supportedFormatsString).")
					present(wrongSuffixAlertVC, animated: true)
				} catch PreferencesGeneralError.fileWithFilenameAleadyExists {
					let fileExistsAlertVC = UIAlertController.withMessage("A file with that name already exists")
					present(fileExistsAlertVC, animated: true)
				} catch {
					let errorVC = UIAlertController.withError(error)
					present(errorVC, animated: true)
				}
			}
		}
	}
}

extension PreferencesGeneralViewController.SectionType {
	@MainActor
	init(sectionIndex: Int, model: PreferencesGeneralModel) {
		let sections = Self.availableSections(with: model)
		self = sections[sectionIndex]
	}

	@MainActor
	static func count(model: PreferencesGeneralModel) -> Int {
		let sections = Self.availableSections(with: model)
		return sections.count
	}

	@MainActor
	func sectionIndex(model: PreferencesGeneralModel) -> Int {
		let sections = Self.availableSections(with: model)
		return sections.firstIndex(of: self)!
	}

	@MainActor
	private static func availableSections(with model: PreferencesGeneralModel) -> [Self] {
		var sections = allCases
		if model.hasRomFile,
		   let romSectionIndex = sections.firstIndex(of: .rom) {
			sections.remove(at: romSectionIndex)
		}
		if !UIDevice.isIPad,
		   let iPadMouseSection = sections.firstIndex(of: .iPadMouse) {
			sections.remove(at: iPadMouseSection)
		}

		return sections
	}
}
