import Foundation
import UIKit

final class UIKitDemoViewController: UIViewController {
    private let session: URLSession
    private let sampleURL: URL

    private let resultLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.text = "No request has been sent yet."
        return label
    }()

    private lazy var sendButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = "Send sample GET"

        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = "uikit-demo-send-request"
        button.addTarget(self, action: #selector(sendSampleRequest), for: .touchUpInside)
        return button
    }()

    init(session: URLSession, sampleURL: URL) {
        self.session = session
        self.sampleURL = sampleURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "UIKit Demo"
        view.backgroundColor = .systemBackground

        let descriptionLabel = makeLabel(
            text: "This request uses an instrumented URLSessionConfiguration."
        )
        #if DEBUG
            let inspectorMessage = "Hold for one second with one finger in Simulator or three fingers on a device to open Windshield."
        #else
            let inspectorMessage = "Windshield is excluded from Release builds."
        #endif

        let inspectorLabel = makeLabel(text: inspectorMessage)
        inspectorLabel.textColor = .secondaryLabel

        let stackView = UIStackView(arrangedSubviews: [
            descriptionLabel,
            sendButton,
            resultLabel,
            inspectorLabel,
        ])
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.spacing = 16
        stackView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(
                equalTo: view.readableContentGuide.leadingAnchor
            ),
            stackView.trailingAnchor.constraint(
                equalTo: view.readableContentGuide.trailingAnchor
            ),
            stackView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc
    private func sendSampleRequest() {
        sendButton.isEnabled = false
        resultLabel.text = "Request in progress..."

        session.dataTask(with: sampleURL) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }

                self.sendButton.isEnabled = true
                if let error {
                    self.resultLabel.text = "Request failed: \(error.localizedDescription)"
                    return
                }

                let statusCode = (response as? HTTPURLResponse)?.statusCode
                let status = statusCode.map(String.init) ?? "unknown"
                self.resultLabel.text = "HTTP \(status), \(data?.count ?? 0) bytes received."
            }
        }.resume()
    }

    private func makeLabel(text: String) -> UILabel {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.text = text
        return label
    }
}
