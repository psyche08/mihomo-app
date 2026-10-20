import AppKit
import Foundation
import MihomoDNSCore
import UniformTypeIdentifiers

@MainActor
enum ProfileEditorPrompt {
  typealias Save = @Sendable (String) async -> String?

  private static var activeControllers: [ObjectIdentifier: ProfileEditorWindowController] = [:]

  static func run(
    name: String,
    contents: String,
    activatesOnSave: Bool,
    save: @escaping Save
  ) async throws {
    try await withCheckedThrowingContinuation { continuation in
      var controller: ProfileEditorWindowController?
      controller = ProfileEditorWindowController(
        name: name,
        contents: contents,
        activatesOnSave: activatesOnSave,
        save: save
      ) { result in
        if let controller {
          activeControllers.removeValue(forKey: ObjectIdentifier(controller))
        }
        continuation.resume(with: result)
      }
      guard let controller else {
        continuation.resume(throwing: ProfileCoordinatorError.cancelled)
        return
      }
      activeControllers[ObjectIdentifier(controller)] = controller
      controller.showWindow(nil)
      controller.window?.center()
      controller.window?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }
}

@MainActor
private final class ProfileEditorWindowController: NSWindowController,
  NSWindowDelegate, NSTextViewDelegate
{
  private let saveOperation: ProfileEditorPrompt.Save
  private let completion: (Result<Void, Error>) -> Void
  private let textView = NSTextView()
  private let errorLabel = NSTextField(wrappingLabelWithString: "")
  private let detailLabel = NSTextField(labelWithString: "")
  private let managedFieldsLabel = NSTextField(wrappingLabelWithString: "")
  private let saveButton = NSButton(title: "Validate & Save", target: nil, action: nil)
  private let networkButton = NSButton(title: "Network Settings…", target: nil, action: nil)
  private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  private var finished = false
  private var applyingHighlight = false
  private var saving = false
  private var pendingHighlight: DispatchWorkItem?
  private let activatesOnSave: Bool

  init(
    name: String,
    contents: String,
    activatesOnSave: Bool,
    save: @escaping ProfileEditorPrompt.Save,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    saveOperation = save
    self.activatesOnSave = activatesOnSave
    self.completion = completion
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Edit \(name)"
    window.minSize = NSSize(width: 680, height: 440)
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    configure(name: name, contents: contents)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func configure(name: String, contents: String) {
    guard let contentView = window?.contentView else { return }

    let title = NSTextField(labelWithString: name)
    title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    title.lineBreakMode = .byTruncatingMiddle

    detailLabel.stringValue =
      "YAML · Mihomo key completion: Option-Escape · Save runs the bundled Mihomo validator"
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

    managedFieldsLabel.stringValue = MihomoProfileLanguage.managedFieldsNotice
    managedFieldsLabel.textColor = .systemOrange
    managedFieldsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    managedFieldsLabel.maximumNumberOfLines = 2

    textView.string = contents
    textView.delegate = self
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.textContainerInset = NSSize(width: 10, height: 10)
    textView.autoresizingMask = [.width]
    textView.isHorizontallyResizable = false
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: 0,
      height: CGFloat.greatestFiniteMagnitude
    )

    let scroll = NSScrollView()
    scroll.borderType = .bezelBorder
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = textView

    errorLabel.textColor = .systemRed
    errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    errorLabel.maximumNumberOfLines = 3
    errorLabel.isHidden = true

    networkButton.target = self
    networkButton.action = #selector(editNetworkSettings)
    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    cancelButton.keyEquivalent = "\u{1b}"
    saveButton.target = self
    saveButton.action = #selector(save)
    saveButton.title = activatesOnSave ? "Validate & Apply" : "Validate & Save"
    saveButton.keyEquivalent = "s"
    saveButton.keyEquivalentModifierMask = [.command]

    for view in [
      title, detailLabel, managedFieldsLabel, networkButton, scroll, errorLabel, cancelButton, saveButton,
    ] {
      view.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(view)
    }
    NSLayoutConstraint.activate([
      title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
      title.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
      title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
      detailLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      detailLabel.trailingAnchor.constraint(equalTo: title.trailingAnchor),
      detailLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
      managedFieldsLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      managedFieldsLabel.trailingAnchor.constraint(equalTo: title.trailingAnchor),
      managedFieldsLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 6),
      scroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
      scroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
      networkButton.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      networkButton.topAnchor.constraint(equalTo: managedFieldsLabel.bottomAnchor, constant: 8),
      scroll.topAnchor.constraint(equalTo: networkButton.bottomAnchor, constant: 8),
      scroll.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -10),
      errorLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
      errorLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: cancelButton.leadingAnchor,
        constant: -12
      ),
      errorLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
      cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
      cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
      saveButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
      saveButton.bottomAnchor.constraint(equalTo: cancelButton.bottomAnchor),
    ])

    updateDetails()
    applyHighlighting()
    window?.makeFirstResponder(textView)
  }

  func textDidChange(_ notification: Notification) {
    guard !applyingHighlight else { return }
    errorLabel.isHidden = true
    updateDetails()
    scheduleHighlighting()
  }

  func textView(
    _ textView: NSTextView,
    completions words: [String],
    forPartialWordRange charRange: NSRange,
    indexOfSelectedItem index: UnsafeMutablePointer<Int>?
  ) -> [String] {
    guard let range = Range(charRange, in: textView.string) else { return words }
    let partial = String(textView.string[range])
    let mihomo = MihomoProfileLanguage.completions(for: partial)
    return mihomo.isEmpty ? words : mihomo
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    finish(.failure(ProfileCoordinatorError.cancelled))
    return true
  }

  @objc private func cancel() {
    finish(.failure(ProfileCoordinatorError.cancelled))
    window?.close()
  }

  @objc private func editNetworkSettings() {
    guard !saving else { return }
    do {
      let form = try ProfileNetworkSettingsForm(source: textView.string)
      guard let updated = form.run() else { return }
      let range = NSRange(location: 0, length: (textView.string as NSString).length)
      if textView.shouldChangeText(in: range, replacementString: updated) {
        textView.replaceCharacters(in: range, with: updated)
        textView.didChangeText()
        applyHighlighting()
      }
    } catch {
      errorLabel.stringValue = error.localizedDescription
      errorLabel.textColor = .systemRed
      errorLabel.isHidden = false
    }
  }

  @objc private func save() {
    guard !saving else { return }
    pendingHighlight?.cancel()
    saving = true
    saveButton.isEnabled = false
    networkButton.isEnabled = false
    cancelButton.isEnabled = false
    errorLabel.stringValue = "Validating with Mihomo…"
    errorLabel.textColor = .secondaryLabelColor
    errorLabel.isHidden = false
    let contents = textView.string
    Task { [weak self] in
      guard let self else { return }
      if let message = await saveOperation(contents) {
        saving = false
        saveButton.isEnabled = true
        networkButton.isEnabled = true
        cancelButton.isEnabled = true
        errorLabel.stringValue = message
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = false
        window?.makeFirstResponder(textView)
        return
      }
      finish(.success(()))
      window?.close()
    }
  }

  private func finish(_ result: Result<Void, Error>) {
    guard !finished else { return }
    pendingHighlight?.cancel()
    pendingHighlight = nil
    finished = true
    completion(result)
  }

  private func updateDetails() {
    let lineCount = max(
      1,
      textView.string.reduce(into: 1) { count, character in
        if character == "\n" { count += 1 }
      }
    )
    detailLabel.stringValue =
      "YAML · \(lineCount) lines · Option-Escape completion · "
      + (activatesOnSave ? "⌘S validates and applies" : "⌘S validates and saves; switch to apply")
  }

  private func scheduleHighlighting() {
    pendingHighlight?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.pendingHighlight = nil
      if self.textView.hasMarkedText() {
        self.scheduleHighlighting()
        return
      }
      self.applyHighlighting()
    }
    pendingHighlight = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: work)
  }

  private func applyHighlighting() {
    guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
    applyingHighlight = true
    defer { applyingHighlight = false }
    let full = NSRange(location: 0, length: storage.length)
    storage.beginEditing()
    storage.setAttributes(
      [
        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor.textColor,
      ],
      range: full
    )
    let source = storage.string as NSString
    let pattern = #"(?m)^(\s*-?\s*)([A-Za-z][A-Za-z0-9_-]*)(\s*:)"#
    if let expression = try? NSRegularExpression(pattern: pattern) {
      expression.enumerateMatches(in: storage.string, range: full) { match, _, _ in
        guard let keyRange = match?.range(at: 2), keyRange.location != NSNotFound else { return }
        let key = source.substring(with: keyRange)
        storage.addAttribute(
          .foregroundColor,
          value: MihomoProfileLanguage.isKnownKey(key) ? NSColor.systemPurple : NSColor.systemBlue,
          range: keyRange
        )
      }
    }
    enumerateCommentRanges(in: storage.string) { range in
      storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
    }
    storage.endEditing()
    textView.typingAttributes = [
      .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
      .foregroundColor: NSColor.textColor,
    ]
  }

  private func enumerateCommentRanges(in source: String, body: (NSRange) -> Void) {
    let value = source as NSString
    var offset = 0
    while offset < value.length {
      let line = value.lineRange(for: NSRange(location: offset, length: 0))
      var quote: unichar?
      var escaped = false
      var index = line.location
      while index < NSMaxRange(line) {
        let character = value.character(at: index)
        if escaped {
          escaped = false
        } else if character == 92, quote == 34 {
          escaped = true
        } else if character == 34 || character == 39 {
          quote = quote == character ? nil : (quote == nil ? character : quote)
        } else if character == 35, quote == nil {
          body(NSRange(location: index, length: NSMaxRange(line) - index))
          break
        }
        index += 1
      }
      offset = NSMaxRange(line)
    }
  }
}


/// Produces a reviewable YAML draft. Saving remains a separate, validated
/// profile transaction; the chooser never changes the running network.
@MainActor
private final class ProfileNetworkSettingsForm: NSObject {
  private let source: String
  private let alert = NSAlert()
  private let port = NSTextField()
  private let stack = NSPopUpButton()
  private let mode = NSPopUpButton()
  private let policy = NSTextField()
  private let paths = NSTextView()
  private let error = NSTextField(wrappingLabelWithString: "")

  init(source: String) throws {
    self.source = source
    let settings = try NetworkProfileSettings.read(from: source)
    super.init()
    alert.messageText = "Profile Network Settings"
    alert.informativeText = "HTTP and SOCKS5 share one mixed port. Per-app routing requires Enhanced TUN and Rule mode; it includes helper processes inside each selected app. Changes below update the YAML draft."
    alert.addButton(withTitle: "Update Draft")
    alert.addButton(withTitle: "Cancel")
    port.stringValue = String(settings.mixedPort)
    stack.addItems(withTitles: ["mixed", "system", "gvisor"])
    stack.selectItem(withTitle: settings.tunStack)
    mode.addItems(withTitles: ["Use profile rules", "Only selected apps use policy; others DIRECT", "Selected apps DIRECT; others use profile rules"])
    mode.selectItem(at: NetworkProfileSettings.ApplicationMode.allCases.firstIndex(of: settings.applicationMode) ?? 0)
    policy.stringValue = settings.policy
    policy.placeholderString = "Existing proxy or policy group name"
    paths.string = settings.applicationPaths.joined(separator: "\n")
    paths.isRichText = false
    paths.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    paths.isAutomaticQuoteSubstitutionEnabled = false
    paths.isAutomaticDashSubstitutionEnabled = false
    paths.isAutomaticTextReplacementEnabled = false
    paths.autoresizingMask = [.width]
    paths.textContainer?.widthTracksTextView = true
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.documentView = paths
    let choose = NSButton(title: "Choose Applications…", target: self, action: #selector(chooseApplications))
    error.textColor = .systemRed
    let notice = NSTextField(wrappingLabelWithString: "Use one absolute .app path per line. Only-selected mode sends unmatched traffic directly, including traffic whose process cannot be identified. Global/Direct mode overrides app rules. Custom listeners must be edited in YAML.")
    notice.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    notice.textColor = .secondaryLabelColor
    let content = NSStackView(views: [
      NSTextField(labelWithString: "HTTP / SOCKS5 mixed port"), port,
      NSTextField(labelWithString: "TUN stack (mixed: system TCP + gVisor UDP)"), stack,
      NSTextField(labelWithString: "Per-app VPN routing"), mode,
      NSTextField(labelWithString: "Selected apps' policy"), policy,
      choose, scroll, notice, error,
    ])
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 6
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      content.widthAnchor.constraint(equalToConstant: 560),
      port.widthAnchor.constraint(equalTo: content.widthAnchor),
      policy.widthAnchor.constraint(equalTo: content.widthAnchor),
      scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
      scroll.heightAnchor.constraint(equalToConstant: 100),
      notice.widthAnchor.constraint(equalTo: content.widthAnchor),
      error.widthAnchor.constraint(equalTo: content.widthAnchor),
    ])
    content.layoutSubtreeIfNeeded()
    content.setFrameSize(content.fittingSize)
    alert.accessoryView = content
  }

  func run() -> String? {
    while alert.runModal() == .alertFirstButtonReturn {
      do {
        let settings = NetworkProfileSettings(
          mixedPort: Int(port.stringValue) ?? 0,
          tunStack: stack.titleOfSelectedItem ?? "mixed",
          applicationMode: NetworkProfileSettings.ApplicationMode.allCases[max(0, mode.indexOfSelectedItem)],
          applicationPaths: paths.string.components(separatedBy: .newlines).filter { !$0.isEmpty },
          policy: policy.stringValue
        )
        return try settings.applying(to: source)
      } catch {
        self.error.stringValue = error.localizedDescription
      }
    }
    return nil
  }

  @objc private func chooseApplications() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.applicationBundle]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    guard panel.runModal() == .OK else { return }
    let existing = paths.string.components(separatedBy: .newlines).filter { !$0.isEmpty }
    paths.string = Array(Set(existing + panel.urls.map(\.path))).sorted().joined(separator: "\n")
  }
}
