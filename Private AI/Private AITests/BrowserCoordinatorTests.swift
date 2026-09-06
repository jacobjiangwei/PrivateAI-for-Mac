import AppKit
import Foundation
import LLMCore
import PrivateAITools
import Testing
@testable import Private_AI

@Suite("Browser Coordinator", .serialized)
@MainActor
struct BrowserCoordinatorTests {
    @Test("captures a rendered WebView, scrolls, and rejects a stale frame")
    func screenshotScrollAndStaleFrame() async throws {
        let browser = BrowserCoordinator(allowsTestURLs: true)
        let html = """
        <!doctype html>
        <html>
          <head>
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
              html, body { margin: 0; background: white; }
              #top { height: 900px; background: rgb(220, 30, 50); }
              #target { height: 700px; background: rgb(20, 80, 220); color: white; font-size: 48px; }
            </style>
          </head>
          <body>
            <div id="top"></div>
            <div id="target">PIXEL-GROUND-TRUTH-73</div>
            <script>document.title = 'Dynamic Visual Fixture';</script>
          </body>
        </html>
        """
        let encoded = Data(html.utf8).base64EncodedString()
        let url = try #require(URL(string: "data:text/html;base64,\(encoded)"))

        let opened = try await browser.execute(.open(url))
        let first = try #require(opened.frame)
        let firstImage = try #require(NSImage(data: first.image.data))

        #expect(first.pageTitle == "Dynamic Visual Fixture")
        #expect(first.image.width == 1_280)
        #expect((first.image.height ?? 0) > 0)
        #expect(firstImage.isValid)

        let scrolled = try await browser.execute(.scroll(
            sessionID: first.sessionID,
            frameID: first.frameID,
            x: 640,
            y: 400,
            deltaX: 0,
            deltaY: 700
        ))
        let second = try #require(scrolled.frame)

        #expect(second.frameID != first.frameID)
        #expect(second.scrollY > first.scrollY)
        await #expect(throws: BrowserCoordinatorError.staleFrame) {
            try await browser.execute(.scroll(
                sessionID: first.sessionID,
                frameID: first.frameID,
                x: 640,
                y: 400,
                deltaX: 0,
                deltaY: 100
            ))
        }

        _ = try await browser.execute(.close(sessionID: first.sessionID))
        #expect(!browser.isActive)
    }

      @Test("button click executes exactly once")
      func buttonClick() async throws {
        let browser = BrowserCoordinator(allowsTestURLs: true)
        let html = """
        <!doctype html>
        <html>
          <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            html, body { margin: 0; background: white; }
            button { position: absolute; left: 400px; top: 300px; width: 300px; height: 120px; font-size: 36px; }
          </style>
          </head>
          <body>
          <button aria-label="Increment once" onclick="window.count += 1; this.textContent = 'COUNT=' + window.count">COUNT=0</button>
          <script>window.count = 0;</script>
          </body>
        </html>
        """
        let encoded = Data(html.utf8).base64EncodedString()
        let url = try #require(URL(string: "data:text/html;base64,\(encoded)"))
        let opened = try await browser.execute(.open(url))
        let first = try #require(opened.frame)

        _ = try await browser.execute(.click(
            sessionID: first.sessionID,
            frameID: first.frameID,
            x: 550,
            y: 360
        ))

        let text = try await browser.pageText(sessionID: first.sessionID)
        #expect(text.contains("COUNT=1"))
        #expect(text.contains("COUNT=2") == false)
        _ = try await browser.execute(.close(sessionID: first.sessionID))
      }
}