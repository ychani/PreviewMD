// Prints the text in an image (Vision), one recognized line each. Runs on the
// host, so a test can assert what a guest screenshot actually shows.
import AppKit
import Vision

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
let req = VNRecognizeTextRequest()
req.recognitionLevel = .accurate
try VNImageRequestHandler(cgImage: img).perform([req])
for o in req.results ?? [] { if let t = o.topCandidates(1).first?.string { print(t) } }
