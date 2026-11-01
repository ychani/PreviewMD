// What tools/test-old-macos.sh asks of the guest's screen, built on the host
// for the oldest macOS the app supports and run in the guest by `tart exec`.
//
//   probe windows <app name>   one line per on-screen window of that app:
//                              "<window id>\t<title>"
//   probe ocr <png>            the text Vision reads in the image, one line each
//
// Window titles need Screen Recording; in the Cirrus Labs base images the
// guest agent that `tart exec` runs under already has it, so nothing is
// granted here (and nothing on the host).
import AppKit
import CoreGraphics
import Vision

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func windows(owner: String) {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        fail("no window list")
    }
    for window in list {
        guard window[kCGWindowOwnerName as String] as? String == owner,
              window[kCGWindowLayer as String] as? Int == 0,
              let id = window[kCGWindowNumber as String] as? Int else { continue }
        print("\(id)\t\(window[kCGWindowName as String] as? String ?? "")")
    }
}

func ocr(path: String) {
    guard let image = NSImage(contentsOfFile: path),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fail("cannot read \(path)")
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    do {
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
    } catch {
        fail("OCR failed: \(error)")
    }
    for observation in request.results ?? [] {
        if let text = observation.topCandidates(1).first?.string { print(text) }
    }
}

let args = CommandLine.arguments
switch (args.count, args.count > 1 ? args[1] : "") {
case (3, "windows"): windows(owner: args[2])
case (3, "ocr"): ocr(path: args[2])
default: fail("usage: probe windows <app name> | probe ocr <png>")
}
