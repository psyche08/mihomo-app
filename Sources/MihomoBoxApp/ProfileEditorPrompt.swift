import AppKit
import Foundation

@MainActor
enum ProfileEditorPrompt {
  typealias Save = @Sendable (String) async -> String?

  private static var activeControllers: [ObjectIdentifier: ProfileEditorWindowController] = [:]

  static func run(name: String, contents: String, save: @escaping Save) async throws {
    try await withCheckedThrowingContinuation { continuation in
      var controller: ProfileEditorWindowController?
      controller = ProfileEditorWindowController(
        name: name,
        contents: contents,
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
  private let saveButton = NSButton(title: "Validate & Save", target: nil, action: nil)
  private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  private var finished = false
  private var applyingHighlight = false
  private var saving = false

  init(
    name: String,
    contents: String,
    save: @escaping ProfileEditorPrompt.Save,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    saveOperation = save
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

    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    cancelButton.keyEquivalent = "\u{1b}"
    saveButton.target = self
    saveButton.action = #selector(save)
    saveButton.keyEquivalent = "\r"

    for view in [title, detailLabel, scroll, errorLabel, cancelButton, saveButton] {
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
      scroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
      scroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
      scroll.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 10),
      scroll.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -10),
      errorLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
      errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -12),
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
    applyHighlighting()
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

  @objc private func save() {
    guard !saving else { return }
    saving = true
    saveButton.isEnabled = false
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
    finished = true
    completion(result)
  }

  private func updateDetails() {
    let lineCount = max(1, textView.string.reduce(into: 1) { count, character in
      if character == "\n" { count += 1 }
    })
    detailLabel.stringValue =
      "YAML · \(lineCount) lines · Mihomo completion: Option-Escape · Validated before save"
  }

  private func applyHighlighting() {
    guard let storage = textView.textStorage else { return }
    applyingHighlight = true
    defer { applyingHighlight = false }
    let selection = textView.selectedRanges
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
    textView.selectedRanges = selection
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
