import XCTest
@testable import Avadhana

final class LinkTests: XCTestCase {
    private let github = SiteTile(name: "GitHub", url: "https://github.com", allowedDomains: ["github.com"])

    // MARK: Telling a link's page apart from your own

    private func state(_ address: String?, tabs: Int? = nil) -> Links.WindowState {
        Links.WindowState(address: address, tabs: tabs)
    }

    func testNewTabIsALink() {
        XCTAssertTrue(Links.isNewPage(state("example.com", tabs: 8), comparedTo: state("github.com", tabs: 7), launched: false))
    }

    func testSameTabsMeansYourOwnPageEvenIfItsAddressChanged() {
        // Firefox and Chrome report tabs; a page changing its own address isn't a link.
        XCTAssertFalse(Links.isNewPage(state("mail.proton.me/inbox/2", tabs: 7), comparedTo: state("mail.proton.me/inbox", tabs: 7), launched: false))
        XCTAssertFalse(Links.isNewPage(state("github.com", tabs: 6), comparedTo: state("github.com", tabs: 7), launched: false))
    }

    func testWithoutTabCountsANewAddressIsALink() {
        // Safari doesn't report tabs.
        XCTAssertTrue(Links.isNewPage(state("https://example.com/"), comparedTo: state("https://github.com/"), launched: false))
        XCTAssertFalse(Links.isNewPage(state("https://github.com/"), comparedTo: state("https://github.com/"), launched: false))
    }

    func testNewWindowOrNewlyOpenedBrowserIsALink() {
        XCTAssertTrue(Links.isNewPage(state("example.com", tabs: 1), comparedTo: nil, launched: false))
        XCTAssertTrue(Links.isNewPage(state("example.com", tabs: 3), comparedTo: state("example.com", tabs: 3), launched: true))
    }

    func testNothingLoadedYetIsntALink() {
        XCTAssertFalse(Links.isNewPage(state(""), comparedTo: nil, launched: true))
        XCTAssertFalse(Links.isNewPage(state(nil), comparedTo: nil, launched: true))
    }

    func testAddressBarText() {
        XCTAssertEqual(Links.webURL(fromAddress: "example.com/?a=1")?.absoluteString, "https://example.com/?a=1")
        XCTAssertEqual(Links.webURL(fromAddress: " https://github.com/riverma ")?.absoluteString, "https://github.com/riverma")
        XCTAssertEqual(Links.webURL(fromAddress: "http://neverssl.com")?.absoluteString, "http://neverssl.com")
        XCTAssertNil(Links.webURL(fromAddress: "how to focus"), "search text")
        XCTAssertNil(Links.webURL(fromAddress: "about:newtab"))
        XCTAssertNil(Links.webURL(fromAddress: "file:///Users/me/page.html"))
        XCTAssertNil(Links.webURL(fromAddress: "localhost"))
        XCTAssertNil(Links.webURL(fromAddress: ""))
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
