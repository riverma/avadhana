import XCTest
@testable import Avadhana

final class LinkTests: XCTestCase {
    private let github = SiteTile(name: "GitHub", url: "https://github.com", allowedDomains: ["github.com"])

    // MARK: Who sent a link

    func testHelperProcessesCountAsTheirApp() {
        XCTAssertEqual(Links.appBundlePath(forExecutable: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"),
                       "/Applications/Slack.app")
        XCTAssertEqual(Links.appBundlePath(forExecutable: "/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight"),
                       "/System/Library/CoreServices/Spotlight.app")
        XCTAssertNil(Links.appBundlePath(forExecutable: "/usr/bin/open"))
    }

    func testSendingAppOfThisProcessIsFound() {
        // The test runner isn't an app, so this walks up through its parents and must stop safely.
        _ = Links.sendingApp(pid: getpid())
        XCTAssertNil(Links.sendingApp(pid: 1), "launchd is never treated as an app")
        XCTAssertNil(Links.sendingApp(pid: 999_999), "an unknown process sends nothing")
    }

    func testSendingAppResolvesRunningApps() throws {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            throw XCTSkip("Finder isn't running")
        }
        XCTAssertEqual(Links.sendingApp(pid: finder.processIdentifier)?.bundleID, "com.apple.finder")
    }

    func testOnlyAddedAppsAndAvadhanaMaySendLinks() {
        let allowed: Set<String> = ["com.tinyspeck.slackmacgap", "com.apple.mail"]
        let own = "com.riverma.avadhana"
        XCTAssertTrue(Links.isAllowedSender("com.apple.mail", allowedApps: allowed, own: own))
        XCTAssertTrue(Links.isAllowedSender("com.tinyspeck.slackmacgap.helper", allowedApps: allowed, own: own))
        XCTAssertTrue(Links.isAllowedSender(own, allowedApps: allowed, own: own))
        XCTAssertFalse(Links.isAllowedSender("com.apple.Spotlight", allowedApps: allowed, own: own))
        XCTAssertFalse(Links.isAllowedSender("com.apple.mailx", allowedApps: allowed, own: own), "a prefix alone isn't enough")
        XCTAssertFalse(Links.isAllowedSender("", allowedApps: allowed, own: own))
    }

    // MARK: Sites of a host

    func testSiteDomain() {
        XCTAssertEqual(Links.siteDomain(of: "docs.github.com"), "github.com")
        XCTAssertEqual(Links.siteDomain(of: "GitHub.com"), "github.com")
        XCTAssertEqual(Links.siteDomain(of: "www.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(Links.siteDomain(of: "news.abc.net.au"), "abc.net.au")
        XCTAssertEqual(Links.siteDomain(of: "a.b.example.org"), "example.org")
        XCTAssertEqual(Links.siteDomain(of: "localhost"), "localhost")
        XCTAssertEqual(Links.siteDomain(of: "192.168.1.20"), "192.168.1.20")
    }

    func testLinkTileIsNamedAfterItsSite() {
        let tile = SiteTile.link(to: URL(string: "https://www.quantamagazine.org/some-article/")!)
        XCTAssertEqual(tile.name, "quantamagazine.org")
        XCTAssertNotNil(tile.validatedURL)
    }

    // MARK: Clicking links in your sites

    func testAllowedDomainsLoadInPlace() {
        XCTAssertEqual(Links.siteNavigation(github, to: "gist.github.com", isLinkClick: true, openLinks: true), .allow)
    }

    func testClickedLinkToAnotherSiteOpensOnItsOwnWhenLinksAreOn() {
        XCTAssertEqual(Links.siteNavigation(github, to: "en.wikipedia.org", isLinkClick: true, openLinks: true), .openAsLink)
        XCTAssertEqual(Links.siteNavigation(github, to: "en.wikipedia.org", isLinkClick: true, openLinks: false), .block)
    }

    func testPagesCantLeaveTheirSiteWithoutAClick() {
        XCTAssertEqual(Links.siteNavigation(github, to: "ads.example.com", isLinkClick: false, openLinks: true), .block)
    }

    func testSiteWithNoDomainsStaysOnItsHost() {
        let hn = SiteTile(name: "HN", url: "https://news.ycombinator.com", allowedDomains: [])
        XCTAssertEqual(Links.siteNavigation(hn, to: "news.ycombinator.com", isLinkClick: true, openLinks: true), .allow)
        XCTAssertEqual(Links.siteNavigation(hn, to: "example.com", isLinkClick: true, openLinks: true), .openAsLink)
    }

    // MARK: Pages opened from a link

    func testFirstPageAndRedirectsAreFollowed() {
        XCTAssertEqual(Links.linkNavigation(to: "t.co", site: nil, isUserAction: false, onFirstPage: true, isBackForward: false), .allowAndFollow)
        // A "you're leaving" page that forwards on by itself.
        XCTAssertEqual(Links.linkNavigation(to: "example.com", site: "t.co", isUserAction: false, onFirstPage: true, isBackForward: false), .allowAndFollow)
    }

    func testLinkPagesStayOnTheirSite() {
        XCTAssertEqual(Links.linkNavigation(to: "docs.example.com", site: "example.com", isUserAction: true, onFirstPage: false, isBackForward: false), .allow)
        XCTAssertEqual(Links.linkNavigation(to: "youtube.com", site: "example.com", isUserAction: true, onFirstPage: true, isBackForward: false), .block)
        XCTAssertEqual(Links.linkNavigation(to: "youtube.com", site: "example.com", isUserAction: false, onFirstPage: false, isBackForward: false), .block)
    }

    func testBackAndForwardAlwaysWork() {
        XCTAssertEqual(Links.linkNavigation(to: "t.co", site: "example.com", isUserAction: false, onFirstPage: false, isBackForward: true), .allow)
    }
}
