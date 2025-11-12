import Flutter
import UIKit
import LibProofMode

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Set up ProofMode platform channel
    setupProofModeChannel()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func setupProofModeChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else {
      NSLog("❌ ProofMode: Could not get FlutterViewController")
      return
    }

    let channel = FlutterMethodChannel(
      name: "org.openvine/proofmode",
      binaryMessenger: controller.binaryMessenger
    )

    channel.setMethodCallHandler { [weak self] (call, result) in
      switch call.method {
      case "generateProof":
        guard let args = call.arguments as? [String: Any],
              let mediaPath = args["mediaPath"] as? String else {
          result(FlutterError(
            code: "INVALID_ARGUMENT",
            message: "Media path is required",
            details: nil
          ))
          return
        }

        NSLog("🔐 ProofMode: Generating proof for: \(mediaPath)")

        do {
          // Create MediaItem from file URL
          let fileURL = URL(fileURLWithPath: mediaPath)
          guard FileManager.default.fileExists(atPath: mediaPath) else {
            result(FlutterError(
              code: "FILE_NOT_FOUND",
              message: "Media file does not exist: \(mediaPath)",
              details: nil
            ))
            return
          }

          let mediaItem = MediaItem(mediaUrl: fileURL)

          // Configure proof generation options
          // Include device ID, location (if available), and network info
          let options = ProofGenerationOptions(
            showDeviceIds: true,
            showLocation: true,
            showMobileNetwork: true,
            notarizationProviders: []
          )

          // Generate proof using LibProofMode
          _ = Proof.shared.process(mediaItem: mediaItem, options: options)

          // Return the SHA256 hash (used as proof identifier)
          guard let proofHash = mediaItem.mediaItemHash, !proofHash.isEmpty else {
            NSLog("❌ ProofMode: Proof generation did not produce hash")
            result(FlutterError(
              code: "PROOF_HASH_MISSING",
              message: "LibProofMode did not generate video hash",
              details: nil
            ))
            return
          }

          NSLog("🔐 ProofMode: Proof generated successfully: \(proofHash)")
          result(proofHash)

        } catch {
          NSLog("❌ ProofMode: Proof generation failed: \(error.localizedDescription)")
          result(FlutterError(
            code: "PROOF_GENERATION_FAILED",
            message: error.localizedDescription,
            details: nil
          ))
        }

      case "getProofDir":
        guard let args = call.arguments as? [String: Any],
              let proofHash = args["proofHash"] as? String else {
          result(FlutterError(
            code: "INVALID_ARGUMENT",
            message: "Proof hash is required",
            details: nil
          ))
          return
        }

        NSLog("🔐 ProofMode: Getting proof directory for hash: \(proofHash)")

        // ProofMode stores proof in documents directory under hash subfolder
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        let proofDirPath = (documentsPath as NSString).appendingPathComponent(proofHash)

        if FileManager.default.fileExists(atPath: proofDirPath) {
          NSLog("🔐 ProofMode: Proof directory found: \(proofDirPath)")
          result(proofDirPath)
        } else {
          NSLog("⚠️ ProofMode: Proof directory not found for hash: \(proofHash)")
          result(nil)
        }

      case "isAvailable":
        // iOS ProofMode library is now available
        NSLog("🔐 ProofMode: isAvailable check - true (LibProofMode installed)")
        result(true)

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    NSLog("✅ ProofMode: Platform channel registered with LibProofMode")
  }
}
