// SPDX-License-Identifier: GPL-3.0-only

import UIKit
import UniformTypeIdentifiers

@MainActor
@objcMembers
final class DesktopTextComposer: UIViewController, UITextViewDelegate {
    private let byteLimit = 4096
    private let sendText: (String) -> Bool
    private let editor = UITextView()
    private let message = UILabel()
    private lazy var sendButton = UIBarButtonItem(title: "Send", style: .done, target: self, action: #selector(send))

    init(sendText: @escaping (String) -> Bool) {
        self.sendText = sendText
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(sendText:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Send text to PC"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel)
        )
        navigationItem.rightBarButtonItem = sendButton

        editor.font = .preferredFont(forTextStyle: .body)
        editor.adjustsFontForContentSizeCategory = true
        editor.autocorrectionType = .no
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        editor.accessibilityLabel = "Text to send"
        editor.delegate = self
        editor.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.plainText.identifier])
        editor.translatesAutoresizingMaskIntoConstraints = false

        let paste = UIPasteControl(configuration: .init())
        paste.target = editor
        message.font = .preferredFont(forTextStyle: .footnote)
        message.adjustsFontForContentSizeCategory = true
        message.textColor = .secondaryLabel
        message.numberOfLines = 0

        let footer = UIStackView(arrangedSubviews: [paste, message])
        footer.alignment = .center
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editor)
        view.addSubview(footer)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            editor.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            editor.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            editor.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: editor.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: editor.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12)
        ])
        textViewDidChange(editor)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        editor.becomeFirstResponder()
    }

    func textViewDidChange(_ textView: UITextView) {
        let length = textView.text.utf8.count
        sendButton.isEnabled = length > 0 && length <= byteLimit && textView.markedTextRange == nil
        message.text = length > byteLimit
            ? "This text is too long. Send it in smaller pieces."
            : "Text goes to the focused field on your PC."
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }

    @objc private func send() {
        guard sendButton.isEnabled else { return }
        if sendText(editor.text) {
            dismiss(animated: true)
        } else {
            let alert = UIAlertController(
                title: "Text wasn’t sent",
                message: "Check that your PC is still connected, then try again.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}
