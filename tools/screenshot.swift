// Draws screenshot.png for the README from the app's own views, in light mode.
// Run: swiftc -parse-as-library -o /tmp/shot tools/screenshot.swift $(ls Sources/*.swift | grep -v main.swift) && /tmp/shot
import AppKit
import SwiftUI

@main struct Shot {
    @MainActor static func main() {
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        let issue = Issue(range: NSRange(location: 0, length: 9), original: "recieved", suggestion: "received", kind: .spelling,
                          reason: "Misspelled: i before e, except after c.")
        let tidy = Tidy("Thanks for jumping on this.\n\nBefore the install we need to:\n- Order the two outdoor units\n- Get the electrician to run the 240 V circuits\n- Book the crane for the roof lift\n\nLet me know if any of that is a problem.",
                        summary: "Split into paragraphs and made the to-dos a list.")
        let text = "We recieved the units yesterday."
        let view = HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                ZStack(alignment: .bottomTrailing) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(text).font(.brand(15)).padding(.horizontal, 12).padding(.top, 12)
                        // the red underline under the misspelled word
                        HStack(spacing: 0) {
                            Text("We ").font(.brand(15)).hidden()
                            Rectangle().fill(Color(nsColor: Brand.red)).frame(height: 2)
                                .frame(width: ("recieved" as NSString).size(withAttributes: [.font: NSFont(name: "Helvetica Neue", size: 15)!]).width)
                        }.padding(.horizontal, 12).padding(.top, 1)
                        Spacer()
                    }
                    .frame(width: 360, height: 70, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(white: 0.8)))
                    DotView(count: 1, checking: false, tidy: true, click: {}).padding(4)
                }
                CardView(issue: issue, total: 3, accept: {}, ignore: {}, addWord: {}, fixAll: {})
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            }
            DotCardView(count: 3, checking: false, tidy: tidy, warn: false, fixAll: {}, tidyUp: {})
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
        .padding(28)
        .background(Color(red: 0.973, green: 0.961, blue: 0.949))          // brand Beige-Light
        .environment(\.colorScheme, .light)
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let cg = r.cgImage else { print("render failed"); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "screenshot.png"))
        print("wrote screenshot.png", cg.width, cg.height)
    }
}
