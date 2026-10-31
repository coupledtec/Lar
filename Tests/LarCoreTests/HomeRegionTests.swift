import Foundation
import Testing
@testable import LarCore

@Suite struct HomeRegionTests {
    @Test func lgServerByCountry() {
        #expect(HomeRegion.thinQServer(for: "BR").host() == "api-aic.lgthinq.com")
        #expect(HomeRegion.thinQServer(for: "us").host() == "api-aic.lgthinq.com")
        #expect(HomeRegion.thinQServer(for: "DE").host() == "api-eic.lgthinq.com")
        #expect(HomeRegion.thinQServer(for: "ZA").host() == "api-eic.lgthinq.com")
        #expect(HomeRegion.thinQServer(for: "KR").host() == "api-kic.lgthinq.com")
        #expect(HomeRegion.thinQServer(for: "AU").host() == "api-kic.lgthinq.com")
    }

    @Test func tuyaDataCenterByCountry() {
        #expect(HomeRegion.tuyaRegion(for: "BR") == "us")
        #expect(HomeRegion.tuyaRegion(for: "FR") == "eu")
        #expect(HomeRegion.tuyaRegion(for: "IN") == "in")
        #expect(HomeRegion.tuyaRegion(for: "CN") == "cn")
    }
}
