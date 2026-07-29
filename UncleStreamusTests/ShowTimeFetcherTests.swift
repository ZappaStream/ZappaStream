import XCTest
@testable import UncleStreamus

final class ShowTimeFetcherTests: XCTestCase {

    // MARK: - ShowTime.init

    func testShowTime_earlyParenE() {
        XCTAssertEqual(ShowTime(from: "(E)"), .early)
    }

    func testShowTime_lateParenL() {
        XCTAssertEqual(ShowTime(from: "(L)"), .late)
    }

    func testShowTime_earlyString() {
        XCTAssertEqual(ShowTime(from: "Early show"), .early)
    }

    func testShowTime_lateUppercase() {
        XCTAssertEqual(ShowTime(from: "LATE"), .late)
    }

    func testShowTime_nil() {
        XCTAssertEqual(ShowTime(from: nil), .none)
    }

    func testShowTime_empty() {
        XCTAssertEqual(ShowTime(from: ""), .none)
    }

    func testShowTime_caseInsensitive() {
        XCTAssertEqual(ShowTime(from: "early"), .early)
    }

    func testShowTime_lateParenLShort() {
        XCTAssertEqual(ShowTime(from: "(L"), .late)
    }

    // MARK: - ShowTime.displayName

    func testShowTimeDisplayName_early() {
        XCTAssertEqual(ShowTime.early.displayName, "Early show")
    }

    func testShowTimeDisplayName_late() {
        XCTAssertEqual(ShowTime.late.displayName, "Late show")
    }

    func testShowTimeDisplayName_none() {
        XCTAssertEqual(ShowTime.none.displayName, "")
    }

    // MARK: - FZShowsFetcher.exceptions

    // The dict is keyed by base date only; Early/Late section keywords are derived
    // at lookup via `sectionKeywords(for:)`. These assertions mirror the resolution
    // the old per-suffix keys used to encode directly.

    func testException_1972_12_31_searchDate() {
        let exc = FZShowsFetcher.exceptions["1972 12 31"]
        XCTAssertNotNil(exc)
        XCTAssertEqual(exc?.searchDate, "1972 11 11")
    }

    func testException_1972_12_31_earlyLateKeywords() {
        let exc = FZShowsFetcher.exceptions["1972 12 31"]
        XCTAssertNil(exc?.sectionKeywords(for: .none))
        XCTAssertEqual(exc?.sectionKeywords(for: .early), ["Early"])
        XCTAssertEqual(exc?.sectionKeywords(for: .late), ["Late"])
    }

    func testException_1970_11_13_tapeKeywords() {
        let exc = FZShowsFetcher.exceptions["1970 11 13"]
        // No E/L designation defaults to Tape 1.
        XCTAssertEqual(exc?.sectionKeywords(for: .none), ["Tape 1"])
        XCTAssertEqual(exc?.sectionKeywords(for: .early), ["Tape 1"])
        XCTAssertEqual(exc?.sectionKeywords(for: .late), ["Tape 2"])
    }

    func testException_1970_11_14_tapeKeywords() {
        let exc = FZShowsFetcher.exceptions["1970 11 14"]
        XCTAssertEqual(exc?.sectionKeywords(for: .early), ["Tape 1"])
        XCTAssertEqual(exc?.sectionKeywords(for: .late), ["Tape 2"])
    }

    func testException_1970_05_08_searchDate() {
        let exc = FZShowsFetcher.exceptions["1970 05 08"]
        XCTAssertEqual(exc?.searchDate, "1970 05 08 or 09")
        // No split — every show time resolves to no keyword filter.
        XCTAssertNil(exc?.sectionKeywords(for: .none))
        XCTAssertNil(exc?.sectionKeywords(for: .early))
        XCTAssertNil(exc?.sectionKeywords(for: .late))
    }

    func testException_1970_05_09_searchDate() {
        let exc = FZShowsFetcher.exceptions["1970 05 09"]
        XCTAssertEqual(exc?.searchDate, "1970 05 08 or 09")
    }

    func testException_nonExistent_nil() {
        XCTAssertNil(FZShowsFetcher.exceptions["2000 01 01"])
    }

    func testException_1972_12_12_wrongDate() {
        let exc = FZShowsFetcher.exceptions["1972 12 12"]
        XCTAssertEqual(exc?.searchDate, "1972 12 09")
        XCTAssertEqual(exc?.sectionKeywords(for: .early), ["Early"])
    }

    // Suffixed keys no longer exist — only base dates are stored.
    func testException_suffixedKeysAbsent() {
        XCTAssertNil(FZShowsFetcher.exceptions["1972 12 31 E"])
        XCTAssertNil(FZShowsFetcher.exceptions["1970 11 13 L"])
    }

    // A non-split exception produces only its bare metadata key; a split one
    // produces bare + E + L.
    func testMetadataVariants_noSplit() {
        let exc = FZShowsFetcher.exceptions["1970 05 08"]
        let keys = exc?.metadataVariants(baseDate: "1970 05 08").map(\.key)
        XCTAssertEqual(keys, ["1970 05 08"])
    }

    func testMetadataVariants_split() {
        let exc = FZShowsFetcher.exceptions["1972 12 31"]
        let keys = exc?.metadataVariants(baseDate: "1972 12 31").map(\.key)
        XCTAssertEqual(keys, ["1972 12 31", "1972 12 31 E", "1972 12 31 L"])
    }

    // MARK: - String.decodeHTMLEntities

    func testDecodeHTMLEntities_amp() {
        XCTAssertEqual("Bread &amp; Butter".decodeHTMLEntities(), "Bread & Butter")
    }

    func testDecodeHTMLEntities_lt() {
        XCTAssertEqual("5 &lt; 10".decodeHTMLEntities(), "5 < 10")
    }

    func testDecodeHTMLEntities_gt() {
        XCTAssertEqual("10 &gt; 5".decodeHTMLEntities(), "10 > 5")
    }

    func testDecodeHTMLEntities_quot() {
        XCTAssertEqual("Say &quot;hello&quot;".decodeHTMLEntities(), "Say \"hello\"")
    }

    func testDecodeHTMLEntities_apos() {
        XCTAssertEqual("Rock &apos;n Roll".decodeHTMLEntities(), "Rock 'n Roll")
    }

    func testDecodeHTMLEntities_numeric39() {
        XCTAssertEqual("It&#39;s alive".decodeHTMLEntities(), "It's alive")
    }

    func testDecodeHTMLEntities_nbsp() {
        XCTAssertEqual("Hello&nbsp;World".decodeHTMLEntities(), "Hello World")
    }

    func testDecodeHTMLEntities_ndash() {
        XCTAssertEqual("2000&ndash;2001".decodeHTMLEntities(), "2000–2001")
    }

    func testDecodeHTMLEntities_mdash() {
        XCTAssertEqual("This&mdash;That".decodeHTMLEntities(), "This—That")
    }

    func testDecodeHTMLEntities_combined() {
        XCTAssertEqual("&lt;b&gt;Hello &amp; World&lt;/b&gt;".decodeHTMLEntities(), "<b>Hello & World</b>")
    }

    func testDecodeHTMLEntities_noEntities() {
        XCTAssertEqual("Plain text".decodeHTMLEntities(), "Plain text")
    }

    // MARK: - FZShowsFetcher.parseSetlist

    func testParseSetlist_simpleCommas() {
        let result = FZShowsFetcher.parseSetlist("Montana, Cosmik Debris, Camarillo Brillo")
        XCTAssertEqual(result, ["Montana", "Cosmik Debris", "Camarillo Brillo"])
    }

    func testParseSetlist_commaInsideParens_notSplit() {
        let result = FZShowsFetcher.parseSetlist("Inca Roads (incl. Dupree's Paradise), King Kong")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], "Inca Roads (incl. Dupree's Paradise)")
        XCTAssertEqual(result[1], "King Kong")
    }

    func testParseSetlist_commaInsideBrackets_notSplit() {
        let result = FZShowsFetcher.parseSetlist("Medley [parts 1, 2, 3], Broken Hearts Are For Assholes")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], "Medley [parts 1, 2, 3]")
        XCTAssertEqual(result[1], "Broken Hearts Are For Assholes")
    }

    func testParseSetlist_commaInsideBracketsInsideParens_notSplit() {
        // 1988-05-09: "I Am The Walrus* (incl. Jam [Bavarian Sunset, TRF])"
        // The comma between "Bavarian Sunset" and "TRF" is inside both a paren and a bracket.
        let result = FZShowsFetcher.parseSetlist(
            "I Am The Walrus* (incl. Jam [Bavarian Sunset, TRF]), Sofa (q: Lohengrin)"
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], "I Am The Walrus* (incl. Jam [Bavarian Sunset, TRF])")
        XCTAssertEqual(result[1], "Sofa (q: Lohengrin)")
    }

    func testParseSetlist_nestedBrackets_resetDepth() {
        let result = FZShowsFetcher.parseSetlist("Song [parts in ZA, [FZPTMOFZ]], Next Song Rocks")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], "Song [parts in ZA, [FZPTMOFZ]]")
        XCTAssertEqual(result[1], "Next Song Rocks")
    }

    func testParseSetlist_strayClosingParenDoesNotCascade() {
        // Real-world zappateers typo: an extra/stray ")" after "Babbette [YCDTOSA1]"
        // used to drive parenDepth negative, gluing the rest of the setlist into
        // one giant entry. Depth is now clamped at 0 so only the entry containing
        // the stray paren is affected (it keeps the typo char, but later songs split correctly).
        let result = FZShowsFetcher.parseSetlist(
            "Babbette [YCDTOSA1]), Approximate, Montana (q: Louie Louie, Dragnet)[incl. info, YCDTOSA1], The Booger Man (q: Louie Louie)"
        )
        XCTAssertEqual(result, [
            "Babbette [YCDTOSA1])",
            "Approximate",
            "Montana (q: Louie Louie, Dragnet)[incl. info, YCDTOSA1]",
            "The Booger Man (q: Louie Louie)"
        ])
    }

    func testParseSetlist_standaloneQuoteFoldedIntoPrecedingSong() {
        let result = FZShowsFetcher.parseSetlist("Johnny's Theme, q: Duke Of Earl, Wonderful Wino")
        XCTAssertEqual(result, ["Johnny's Theme (q: Duke Of Earl)", "Wonderful Wino"])
    }

    func testParseSetlist_standaloneQuoteAtStart_keptAsOwnEntry() {
        let result = FZShowsFetcher.parseSetlist("q: Duke Of Earl, Wonderful Wino")
        XCTAssertEqual(result, ["q: Duke Of Earl", "Wonderful Wino"])
    }

    func testParseSetlist_standaloneBracketedNoteFoldedIntoPrecedingSong() {
        // Regression for 1982 05 22 Düsseldorf: zappateers' source has a stray comma
        // before the "[incl. ...]" note ("Let's Move To Cleveland, [incl. Is That All
        // There Is?, G]") instead of attaching it directly, so "Is That All There Is?"
        // was surfacing as its own bogus track.
        let result = FZShowsFetcher.parseSetlist(
            "Bamboozled By Love, Let's Move To Cleveland, [incl. Is That All There Is?, G], Tinsel Town Rebellion"
        )
        XCTAssertEqual(result, [
            "Bamboozled By Love",
            "Let's Move To Cleveland [incl. Is That All There Is?, G]",
            "Tinsel Town Rebellion",
        ])
    }

    func testParseSetlist_correctlyAttachedBracketedNote_notDoubleFolded() {
        // "Song [incl. ...]" with no comma before the bracket is already one entry;
        // folding must not touch it.
        let result = FZShowsFetcher.parseSetlist(
            "Zoot Allures [incl. When No One Was No One, G], Sofa"
        )
        XCTAssertEqual(result, ["Zoot Allures [incl. When No One Was No One, G]", "Sofa"])
    }

    func testParseSetlist_standaloneBracketedNoteAtStart_keptAsOwnEntry() {
        let result = FZShowsFetcher.parseSetlist("[incl. Foo, G], Wonderful Wino")
        XCTAssertEqual(result, ["[incl. Foo, G]", "Wonderful Wino"])
    }

    // MARK: - FZShowsFetcher.redrivedSetlist (cache migration helper)

    func testRedrivedSetlist_foldsStandaloneQuoteFromOldlySplitArray() {
        // Shape an older parser would have produced (before "q:" folding existed)
        let old = ["Johnny's Theme", "q: Duke Of Earl", "Wonderful Wino"]
        let result = FZShowsFetcher.redrivedSetlist(from: old)
        XCTAssertEqual(result, ["Johnny's Theme (q: Duke Of Earl)", "Wonderful Wino"])
    }

    func testRedrivedSetlist_returnsNilWhenAlreadyCorrect() {
        let current = ["Johnny's Theme (q: Duke Of Earl)", "Wonderful Wino"]
        XCTAssertNil(FZShowsFetcher.redrivedSetlist(from: current))
    }

    func testRedrivedSetlist_returnsNilForEmptyArray() {
        XCTAssertNil(FZShowsFetcher.redrivedSetlist(from: []))
    }

    func testParseSetlist_shortEntriesFiltered() {
        let result = FZShowsFetcher.parseSetlist("Montana, ok, Cosmik Debris")
        XCTAssertFalse(result.contains("ok"))
        XCTAssertTrue(result.contains("Montana"))
        XCTAssertTrue(result.contains("Cosmik Debris"))
    }

    func testParseSetlist_emptyString() {
        let result = FZShowsFetcher.parseSetlist("")
        XCTAssertTrue(result.isEmpty)
    }

    func testParseSetlist_singleSong() {
        let result = FZShowsFetcher.parseSetlist("Montana")
        XCTAssertEqual(result, ["Montana"])
    }

    func testParseSetlist_whitespaceTrimmingAroundEntries() {
        let result = FZShowsFetcher.parseSetlist("  Montana  ,  Cosmik Debris  ")
        XCTAssertEqual(result[0], "Montana")
        XCTAssertEqual(result[1], "Cosmik Debris")
    }

    // MARK: - parseShowFromHTML

    func testParseShowFromHTML_minimalHTML_returnsShow() {
        let html = """
        <h4>1973 11 07 - Auditorium Theater, Chicago, IL</h4>
        <h6>90 min, SBD, A</h6>
        <p class="setlist">Montana, Cosmik Debris, Camarillo Brillo</p>
        <h4>1973 11 08 - Another Venue</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "73.html",
            searchDate: "1973 11 07", originalDate: "1973 11 07",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertNotNil(show)
        XCTAssertEqual(show?.venue, "Auditorium Theater, Chicago, IL")
        XCTAssertEqual(show?.showInfo, "90 min, SBD, A")
        XCTAssertEqual(show?.setlist.count, 3)
        XCTAssertEqual(show?.setlist[0], "Montana")
    }

    func testParseShowFromHTML_dateNotFound_returnsNil() {
        let html = "<h4>1999 01 01 - Some Venue</h4><h6>info</h6>"
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "73.html",
            searchDate: "1973 11 07", originalDate: "1973 11 07",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertNil(show)
    }

    func testParseShowFromHTML_earlyShowSection() {
        let html = """
        <h4>1973 11 07 - Theater, Chicago, IL</h4>
        <h5>Early</h5>
        <h6>60 min, SBD, A</h6>
        <p class="setlist">Montana, Cosmik Debris, Long Song Title</p>
        <h5>Late</h5>
        <h6>70 min, AUD, B</h6>
        <p class="setlist">King Kong, Camarillo Brillo, Another Long Song</p>
        <h4>1973 11 08 - Next</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "73.html",
            searchDate: "1973 11 07", originalDate: "1973 11 07",
            showTime: .early, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertNotNil(show)
        XCTAssertTrue(show?.setlist.contains("Montana") ?? false)
        XCTAssertFalse(show?.setlist.contains("King Kong") ?? true)
    }

    func testParseShowFromHTML_earlyShowUnclosedSetlistTag_stillParses() {
        // Regression for 1976 10 24 (E) Boston Music Hall: zappateers' source HTML
        // omits the closing </p> on the Early show's setlist, so the only terminator
        // left is the sibling <h5>Late show</h5> — which selectTargetSection already
        // strips out of the Early subsection. parseSetlistAndAcronyms must fall back
        // to the end of the (already-bounded) target section instead of returning nil.
        let html = """
        <h4>1976 10 24 - Boston Music Hall, Boston, MA</h4>
        <h5>Early show</h5>
        <h6>105 min, Aud, A/A-</h6>
        <p class="note">The better sounding recording ends after Dinah-Moe Humm.</p>
        <p class="setlist">The Purple Lagoon, Stinkfoot, Advance Romance (q: In-A-Gadda-Da-Vida), Muffin Man.
        <h5>Late show</h5>
        <h6>110 min, Aud, B+</h6>
        <p class="setlist">The Purple Lagoon, Stinkfoot, Advance Romance, Muffin Man</p>
        <h4>1976 10 27 - Next</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "7677.html",
            searchDate: "1976 10 24", originalDate: "1976 10 24",
            showTime: .early, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertNotNil(show)
        XCTAssertNotEqual(show?.setlist, ["No setlist available"])
        XCTAssertTrue(show?.setlist.contains("Advance Romance (q: In-A-Gadda-Da-Vida)") ?? false)
        XCTAssertTrue(show?.setlist.contains(where: { $0.hasPrefix("Muffin Man") }) ?? false)
        // Only the Early section's songs, not the Late show's.
        XCTAssertEqual(show?.setlist.count, 4)
    }

    func testParseShowFromHTML_dusseldorfStrayCommaBeforeBracketedNote() {
        // Regression for 1982 05 22 Philipshalle, Düsseldorf: source HTML has
        // "Let's Move To Cleveland, [incl. Is That All There Is?, G]" — the stray
        // comma must not surface "Is That All There Is?" as its own track.
        let html = """
        <h4>1982 05 22 - Philipshalle, Düsseldorf, Germany</h4>
        <h6>130 min, Aud, B+</h6>
        <p class="setlist">Bamboozled By Love, Let's Move To Cleveland, [incl. Is That All There Is?, <acronym title="Guitar">G</acronym>], Tinsel Town Rebellion</p>
        <h4>1982 05 23 - Next</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "8182.html",
            searchDate: "1982 05 22", originalDate: "1982 05 22",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertNotNil(show)
        XCTAssertFalse(show?.setlist.contains("Is That All There Is?") ?? true)
        XCTAssertTrue(show?.setlist.contains("Let's Move To Cleveland [incl. Is That All There Is?, G]") ?? false)
        XCTAssertEqual(show?.setlist.count, 3)
    }

    func testParseShowFromHTML_acronymExtraction() {
        let html = """
        <h4>1973 11 07 - Theater, Chicago, IL</h4>
        <h6>info</h6>
        <p class="setlist"><acronym title="Black Napkins">BN</acronym>, Montana</p>
        <h4>1973 11 08 - Next</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "73.html",
            searchDate: "1973 11 07", originalDate: "1973 11 07",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertNotNil(show)
        XCTAssertEqual(show?.acronyms.count, 1)
        XCTAssertEqual(show?.acronyms.first?.short, "BN")
        XCTAssertEqual(show?.acronyms.first?.full, "Black Napkins")
    }

    func testParseShowFromHTML_htmlEntitiesDecoded() {
        let html = """
        <h4>1973 11 07 - Theater, Chicago, IL</h4>
        <h6>info</h6>
        <p class="setlist">Bread &amp; Butter Song, Montana</p>
        <h4>1973 11 08 - Next</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "73.html",
            searchDate: "1973 11 07", originalDate: "1973 11 07",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertTrue(show?.setlist.first?.contains("&") ?? false)
    }

    func testParseShowFromHTML_noteExtracted() {
        let html = """
        <h4>1973 11 07 - Theater, Chicago, IL</h4>
        <h6>info</h6>
        <p class="note">This is a note about the show.</p>
        <p class="setlist">Montana, Cosmik Debris, Long Name Song</p>
        <h4>1973 11 08 - Next</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "73.html",
            searchDate: "1973 11 07", originalDate: "1973 11 07",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertEqual(show?.note, "This is a note about the show.")
    }

    func testParseShowFromHTML_periodFromFilename() {
        let html = """
        <h4>1973 11 07 - Theater, Chicago, IL</h4>
        <h6>info</h6>
        <p class="setlist">Montana, Cosmik Debris, Long Name Song</p>
        <h4>1973 11 08 - Next</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "73.html",
            searchDate: "1973 11 07", originalDate: "1973 11 07",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertEqual(show?.period, "1973: MOI with J.L. Ponty")
    }

    func testParseShowFromHTML_originalDatePreserved() {
        let html = """
        <h4>1972 11 11 - Theater, Chicago, IL</h4>
        <h6>info</h6>
        <p class="setlist">Montana, Cosmik Debris, Long Name Song</p>
        <h4>1972 11 12 - Next</h4>
        """
        // Exception: metadata says 1972 12 31 but search uses 1972 11 11
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "72.html",
            searchDate: "1972 11 11", originalDate: "1972 12 31",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        // date should be originalDate, not searchDate
        XCTAssertEqual(show?.date, "1972 12 31")
    }
}
