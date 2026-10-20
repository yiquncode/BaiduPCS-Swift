import Testing
@testable import BaiduKit

struct SigningTests {
    /// 参考实现单测的向量。它传入的 DEVUID 是 `O|...`，不是由 BDUSS 算出的值。
    @Test func locateDownloadRandMatchesReferenceVector() {
        let sign = LocateDownloadSign(bduss: "test_bduss", uid: 10086, time: 1571140066,
                                      devUID: "O|1E67351CCE80B2CF48DB511CD77ACD9F")
        #expect(sign.rand == "b6bb7a6f46899e181baea58798d4fdb889775c2c")
    }

    @Test func devUIDIsUppercaseMD5WithSuffix() {
        #expect(LocateDownloadSign.devUID(bduss: "test_bduss") == "66AE65D3C5D483FC4431FC43670A4673|0")
    }

    @Test func queryTailKeepsPipeUnencoded() {
        let sign = LocateDownloadSign(bduss: "test_bduss", uid: 10086, time: 1571140066,
                                      devUID: "O|1E67351CCE80B2CF48DB511CD77ACD9F")
        #expect(sign.queryTail == "time=1571140066&rand=b6bb7a6f46899e181baea58798d4fdb889775c2c"
            + "&devuid=O|1E67351CCE80B2CF48DB511CD77ACD9F&cuid=O|1E67351CCE80B2CF48DB511CD77ACD9F")
    }

    @Test func locateDownloadQuerySortsAndEncodesFixedPart() {
        let sign = LocateDownloadSign(bduss: "b", uid: 1, time: 2)
        let query = LocateDownloadSign.query(path: "/Ferry/a b+c.zip", sign: sign)
        #expect(query.hasPrefix("ant=1&apn_id=1_0&app_id=250528&channel=0&check_blue=1&clienttype=17&es=1&esl=1"
            + "&freeisp=0&method=locatedownload&path=%2FFerry%2Fa%20b%2Bc.zip&queryfree=0&use=0&ver=4.0&time=2&rand="))
        #expect(query.hasSuffix("|0"))
    }

    @Test func tiebaSignSortsKeysAndAppendsSecret() {
        #expect(TiebaLogin.sign([("b", "2"), ("a", "1")]) == "42961B9881C2D7CB297E9498F9767789")
    }

    @Test func tiebaFormMatchesIndependentComputation() {
        let form = TiebaLogin.form(bduss: "test_bduss", now: 1571140066)
        let values = Dictionary(form, uniquingKeysWith: { $1 })
        #expect(TiebaLogin.cuid == "E82F28EAEBCFB6940C28FDD975E8EDBF|286245630389068")
        #expect(values["bdusstoken"] == "test_bduss|null")
        #expect(values["timestamp"] == "1571140066922")
        #expect(values["sign"] == "CC0C8CA80E8AA195B3C00E0874A3BED1")
    }
}
