//
//  VMLibraryController.swift
//  VirtualCore
//
//  Created by Guilherme Rambo on 10/04/22.
//

import SwiftUI
import Combine
import OSLog

@MainActor
public final class VMLibraryController: ObservableObject {

    private lazy var logger = Logger(for: Self.self)

    public enum State {
        case loading
        case loaded([VBVirtualMachine])
        case failed(VBError)
    }
    
    @Published public private(set) var state = State.loading {
        didSet {
            if case .loaded(let vms) = state {
                self.virtualMachines = vms
            }
        }
    }
    
    @Published public private(set) var virtualMachines: [VBVirtualMachine] = []

    @Published public internal(set) var bootedMachineIdentifiers = Set<VBVirtualMachine.ID>()
    
    public static let shared = VMLibraryController()

    let settingsContainer: VBSettingsContainer

    private let filePresenter: VMLibraryFilePresenter
    private let updateSignal = PassthroughSubject<URL, Never>()

    init(settingsContainer: VBSettingsContainer = .current) {
        self.settingsContainer = settingsContainer
        self.settings = settingsContainer.settings
        self.libraryURL = settingsContainer.settings.libraryURL
        self.filePresenter = VMLibraryFilePresenter(
            presentedItemURL: settingsContainer.settings.libraryURL,
            signal: updateSignal
        )

        loadMachines()
        bind()
    }

    private var settings: VBSettings {
        didSet {
            self.libraryURL = settings.libraryURL
        }
    }

    @Published
    public private(set) var libraryURL: URL {
        didSet {
            guard oldValue != libraryURL else { return }
            loadMachines()
        }
    }

    private lazy var cancellables = Set<AnyCancellable>()
    
    private lazy var fileManager = FileManager()

    private func bind() {
        settingsContainer.$settings.sink { [weak self] newSettings in
            self?.settings = newSettings
        }
        .store(in: &cancellables)

        updateSignal
            .removeDuplicates()
            .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                self?.loadMachines()
            }
            .store(in: &cancellables)
    }

    public func loadMachines() {
        filePresenter.presentedItemURL = libraryURL

        guard let enumerator = fileManager.enumerator(at: libraryURL, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants], errorHandler: nil) else {
            state = .failed(.init("Failed to open directory at \(libraryURL.path)"))
            return
        }
        
        var vms = [VBVirtualMachine]()
        
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == VBVirtualMachine.bundleExtension else { continue }
            
            do {
                let machine = try VBVirtualMachine(bundleURL: url)
                
                vms.append(machine)
            } catch {
                assertionFailure("Failed to construct VM model: \(error)")
            }
        }

        vms.sort(by: { $0.bundleURL.creationDate > $1.bundleURL.creationDate })
        
        self.state = .loaded(vms)
    }

    public func reload(animated: Bool = true) {
        if animated {
            withAnimation(.spring()) {
                loadMachines()
            }
        } else {
            loadMachines()
        }
    }

    public func validateNewName(_ name: String, for vm: VBVirtualMachine) throws {
        try urlForRenaming(vm, to: name)
    }

}

// MARK: - Management Actions

public extension VMLibraryController {

    #if ENABLE_HARDWARE_ID_CHANGE
    func duplicate(_ vm: VBVirtualMachine, using method: VBVirtualMachine.DuplicationMethod) throws {
        var newVM = try duplicate(vm)

        if method == .changeID {
            try newVM.generateNewMachineIdentifier()
            try newVM.generateAuxiliaryStorage()
        }

        reload()
    }
    #endif

    @discardableResult
    func duplicate(_ vm: VBVirtualMachine) throws -> VBVirtualMachine {
        let newName = "Copy of " + vm.name

        let copyURL = try urlForRenaming(vm, to: newName)

        try fileManager.copyItem(at: vm.bundleURL, to: copyURL)

        var newVM = try VBVirtualMachine(bundleURL: copyURL)

        newVM.bundleURL.creationDate = .now

        reload()

        return newVM
    }

    func moveToTrash(_ vm: VBVirtualMachine) async throws {
        try await NSWorkspace.shared.recycle([vm.bundleURL])

        reload()
    }

    func rename(_ vm: VBVirtualMachine, to newName: String) throws {
        let newURL = try urlForRenaming(vm, to: newName)

        try fileManager.moveItem(at: vm.bundleURL, to: newURL)
    }

    @discardableResult
    func urlForRenaming(_ vm: VBVirtualMachine, to name: String) throws -> URL {
        guard name.count >= 3 else {
            throw Failure("Name must be at least 3 characters long.")
        }

        let newURL = vm
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(name)
            .appendingPathExtension(VBVirtualMachine.bundleExtension)

        guard !fileManager.fileExists(atPath: newURL.path) else {
            throw Failure("Another virtual machine is already using this name, please choose another one.")
        }

        return newURL
    }
    
}

// MARK: - File Presenter

private final class VMLibraryFilePresenter: NSObject, NSFilePresenter {

    private lazy var logger = Logger(for: Self.self)

    var presentedItemURL: URL?

    var presentedItemOperationQueue: OperationQueue = .main

    let signal: PassthroughSubject<URL, Never>

    init(presentedItemURL: URL?, signal: PassthroughSubject<URL, Never>) {
        self.presentedItemURL = presentedItemURL
        self.signal = signal

        super.init()

        NSFileCoordinator.addFilePresenter(self)
    }

    private func sendSignalIfNeeded(for url: URL) {
        guard url.pathExtension == VBVirtualMachine.bundleExtension else { return }

        signal.send(url)
    }

    func presentedSubitemDidAppear(at url: URL) {
        logger.debug("Added: \(url.path)")

        sendSignalIfNeeded(for: url)
    }

    func presentedSubitemDidChange(at url: URL) {
        sendSignalIfNeeded(for: url)
    }

    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        logger.debug("Moved: \(oldURL.path) -> \(newURL.path)")

        sendSignalIfNeeded(for: newURL)
    }

    func accommodatePresentedSubitemDeletion(at url: URL) async throws {
        logger.debug("Deleted: \(url.path)")

        sendSignalIfNeeded(for: url)
    }

}

// MARK: - Download Helpers

public extension VMLibraryController {

    func getDownloadsBaseURL() throws -> URL {
        let baseURL = libraryURL.appendingPathComponent("_Downloads")
        if !FileManager.default.fileExists(atPath: baseURL.path) {
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        }

        return baseURL
    }

    func existingLocalURL(for remoteURL: URL) throws -> URL? {
        let localURL = try getDownloadsBaseURL()

        let downloadedFileURL = localURL.appendingPathComponent(remoteURL.lastPathComponent)

        if FileManager.default.fileExists(atPath: downloadedFileURL.path) {
            return downloadedFileURL
        } else {
            return nil
        }
    }

}
