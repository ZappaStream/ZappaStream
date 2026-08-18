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

    // MARK: - <h4 class="wrongdate"> section boundaries

    /// The real markup around 1974 11 30 Naperville, IL. Zappateers marks "commonly
    /// listed as" pointer entries with `<h4 class="wrongdate">`; the show-section end
    /// pattern used to be bare-tag-only, so 1974 11 30 — which has no note of its own —
    /// ran past the 1974 12 01 pointer entry and adopted its "See 1974 12 03." note.
    private static let wrongdateEntryHTML = """
    <h4>1974 11 29 - Field House, North Central College, Naperville, IL</h4>
    <h6>60 min, SBD, A-</h6>
    <p class="note">Strange mix, with Bird Legs' bass mixed way up front.</p>
    <p class="setlist">Tush Tush Tush, Stinkfoot, RDNZL, Cosmik Debris</p>

    <h4>1974 11 30 - Field House, North Central College, Naperville, IL</h4>
    <h6>125 min, Aud, B+</h6>
    <p class="setlist">Tush Tush Tush, Stinkfoot, RDNZL, Village Of The Sun</p>

    <h4 class="wrongdate">1974 12 01 - Public Hall, Cleveland, OH</h4>
    <p class="note">See 1974 12 03.</p>

    <h4>1974 12 03 - Public Hall, Cleveland, OH</h4>
    <p class="note">Usually listed as 1974 12 01, but this is the correct date.</p>
    <h6>90 min, Aud, B-/C+</h6>
    <p class="setlist">Tush Tush Tush, Stinkfoot, RDNZL, Dog Meat</p>
    """

    private func parseNaperville(_ date: String) -> FZShow? {
        FZShowsFetcher.parseShowFromHTML(
            html: Self.wrongdateEntryHTML, filename: "7374.html",
            searchDate: date, originalDate: date,
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
    }

    func testParseShowFromHTML_noteFromWrongdateEntryDoesNotBleed() {
        let show = parseNaperville("1974 11 30")
        XCTAssertNotNil(show)
        XCTAssertNil(show?.note)
    }

    func testParseShowFromHTML_attributedH4BoundsSection() {
        // The tighter boundary must not truncate the show's own content.
        let show = parseNaperville("1974 11 30")
        XCTAssertEqual(show?.showInfo, "125 min, Aud, B+")
        XCTAssertEqual(show?.setlist, ["Tush Tush Tush", "Stinkfoot", "RDNZL", "Village Of The Sun"])
        XCTAssertEqual(show?.venue, "Field House, North Central College, Naperville, IL")
    }

    func testParseShowFromHTML_ownNoteStillWinsBeforeWrongdateEntry() {
        // 1974 11 29 has its own note and is followed by a note-bearing show, and
        // 1974 12 03 has its own note while directly preceded by the pointer entry.
        XCTAssertEqual(parseNaperville("1974 11 29")?.note,
                       "Strange mix, with Bird Legs' bass mixed way up front.")
        XCTAssertEqual(parseNaperville("1974 12 03")?.note,
                       "Usually listed as 1974 12 01, but this is the correct date.")
    }

    func testImportAllShows_wrongdateEntryDoesNotLeakNoteToPreviousShow() {
        // The offline cache goes through importAllShows, so assert the whole page at once.
        let shows = FZShowsFetcher.importAllShows(
            fromHTML: Self.wrongdateEntryHTML, filename: "7374.html", url: "https://example.com"
        )
        let notes = Dictionary(uniqueKeysWithValues: shows.map { ($0.date, $0.note) })

        XCTAssertNil(notes["1974 11 30"] ?? nil)
        XCTAssertEqual(notes["1974 11 29"] ?? nil,
                       "Strange mix, with Bird Legs' bass mixed way up front.")
        // The pointer entry is still imported under its own date — a tape circulated
        // under the wrong date should find the cross-reference.
        XCTAssertEqual(notes["1974 12 01"] ?? nil, "See 1974 12 03.")
        XCTAssertEqual(notes["1974 12 03"] ?? nil,
                       "Usually listed as 1974 12 01, but this is the correct date.")
    }

    func testParseShowFromHTML_earlyLateNotesStayWithTheirOwnSubsection() {
        // 1974 10 31 Felt Forum: only the Late show carries a note. The fix must not be
        // extended into parseNote by clamping at the setlist tag — that would drop this
        // note, which sits after the Early setlist.
        let html = """
        <h4>1974 10 31 - Felt Forum, New York, NY</h4>
        <h5>Early show</h5>
        <h6>110 min, Aud, A-/B+</h6>
        <p class="setlist">Tush Tush Tush, Stinkfoot, Inca Roads, Penguin In Bondage</p>
        <h5>Late show</h5>
        <h6>125 min, Aud, A-</h6>
        <p class="note">With Lance Loud on vocals (*) and Bruce Fowler on trombone (**).</p>
        <p class="setlist">Tush Tush Tush, Stinkfoot, RDNZL, Babbette</p>

        <h4 class="wrongdate">1974 11 01 - Capital Centre, Landover, MD</h4>
        <p class="note">See 1974 11 08.</p>

        <h4>1974 11 08 - Next</h4>
        """
        func parse(_ time: ShowTime) -> FZShow? {
            FZShowsFetcher.parseShowFromHTML(
                html: html, filename: "7374.html",
                searchDate: "1974 10 31", originalDate: "1974 10 31",
                showTime: time, sectionKeywords: nil, url: "https://example.com"
            )
        }
        XCTAssertNil(parse(.early)?.note)
        XCTAssertEqual(parse(.late)?.note,
                       "With Lance Loud on vocals (*) and Bruce Fowler on trombone (**).")
        // The Late subsection ends at the page's next entry, not at the pointer entry's note.
        XCTAssertEqual(parse(.late)?.setlist, ["Tush Tush Tush", "Stinkfoot", "RDNZL", "Babbette"])
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

    // MARK: - extractBandInfo (via parseShowFromHTML)

    func testParseShowFromHTML_bandInfo_scopedBlockDoesNotBleedAcrossH2Section() {
        // Regression for 1977 02 03 Pavillon De Paris, Paris: the December-1976-only
        // NY band block must not bleed into the following European leg, which defines
        // no block of its own and should fall back to the base Oct76-Feb77 block.
        let html = """
        <h3>Frank Zappa's Band, October 1976 - February 1977</h3>
        <p class="band">FZ, Ray White, Patrick O'Hearn, Terry Bozzio, Eddie Jobson, Bianca Thornton (through November 11).</p>
        <h2 id="NA">October - November 1976 US and Canada tour</h2>
        <h4>1976 10 24 - Some Venue, City, ST</h4>
        <h6>info</h6>
        <p class="setlist">Song One, Song Two, Song Three</p>
        <h2 id="NY">December 1976 Christmas in New York</h2>
        <h3>Frank Zappa's Band, December 1976</h3>
        <p class="band">FZ, Ray White, Ruth Underwood, Dave Samuels, Mike Brecker, Randy Brecker, Lou Marini, Ron Cuber, Tom Malone.</p>
        <h4>1976 12 26 - Palladium, New York, NY</h4>
        <h6>info</h6>
        <p class="setlist">Song One, Song Two, Song Three</p>
        <h2 id="EU">January - February 1977 European tour</h2>
        <h4>1977 02 03 - Pavillon De Paris, Paris, France</h4>
        <h6>info</h6>
        <p class="setlist">Song One, Song Two, Song Three</p>
        <h4>1977 02 04 - Next</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "7677.html",
            searchDate: "1977 02 03", originalDate: "1977 02 03",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertNotNil(show?.bandInfo)
        XCTAssertTrue(show?.bandInfo?.contains("Eddie Jobson") ?? false)
        XCTAssertFalse(show?.bandInfo?.contains("Ron Cuber") ?? true)
        XCTAssertTrue(show?.bandInfo?.hasPrefix("Frank Zappa's Band, October 1976 - February 1977") ?? false)
    }

    func testParseShowFromHTML_bandInfo_prefacingBlockPersistsAcrossMultipleH2Legs() {
        // A block sitting at the tail of its section (no <h4> before the next <h2>)
        // must keep applying across several subsequent bare <h2> legs with no block
        // of their own — mirrors 7374.html's April-May 1974 -> June-Dec 1974 case.
        let html = """
        <h2 id="AprMay">April - May 1974</h2>
        <h3>Frank Zappa's Band, April 1974</h3>
        <p class="band">FZ, Napoleon Murphy Brock, George Duke, Tom Fowler, Ralph Humphrey.</p>
        <h4>1974 04 15 - Venue A, City, ST</h4>
        <h6>info</h6>
        <p class="setlist">Song One, Song Two, Song Three</p>
        <h3>Frank Zappa's Band, May 1974</h3>
        <p class="band">FZ, Napoleon Murphy Brock, George Duke, Tom Fowler, Ralph Humphrey, Chester Thompson.</p>
        <h2 id="JunAug">June - August 1974</h2>
        <h2 id="SepOct">September - October 1974</h2>
        <h2 id="OctDec">October - December 1974</h2>
        <h4>1974 11 02 - Venue B, City, ST</h4>
        <h6>info</h6>
        <p class="setlist">Song One, Song Two, Song Three</p>
        <h4>1974 11 03 - Next</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "7374.html",
            searchDate: "1974 11 02", originalDate: "1974 11 02",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertNotNil(show?.bandInfo)
        XCTAssertTrue(show?.bandInfo?.contains("Chester Thompson") ?? false)
        XCTAssertTrue(show?.bandInfo?.hasPrefix("Frank Zappa's Band, May 1974") ?? false)
    }

    func testParseShowFromHTML_bandInfo_persistsAcrossOneH2WithNoOwnBlock() {
        let html = """
        <h3>Frank Zappa's Band, 1988</h3>
        <p class="band">FZ, Ike Willis, Mike Keneally, Bobby Martin.</p>
        <h2 id="leg1">Leg One</h2>
        <h4>1988 02 01 - Venue A, City, ST</h4>
        <h6>info</h6>
        <p class="setlist">Song One, Song Two, Song Three</p>
        <h4>1988 02 02 - Next</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "88.html",
            searchDate: "1988 02 01", originalDate: "1988 02 01",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertTrue(show?.bandInfo?.contains("Mike Keneally") ?? false)
    }

    func testParseShowFromHTML_bandInfo_sameSectionNoBoundaryCrossed() {
        let html = """
        <h2 id="leg1">Leg One</h2>
        <h3>Frank Zappa's Band, 1988</h3>
        <p class="band">FZ, Ike Willis, Mike Keneally, Bobby Martin.</p>
        <h4>1988 02 01 - Venue A, City, ST</h4>
        <h6>info</h6>
        <p class="setlist">Song One, Song Two, Song Three</p>
        <h4>1988 02 02 - Next</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "88.html",
            searchDate: "1988 02 01", originalDate: "1988 02 01",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertTrue(show?.bandInfo?.contains("Bobby Martin") ?? false)
    }

    func testParseShowFromHTML_bandInfo_noBandBlock_returnsNil() {
        let html = """
        <h4>1973 11 07 - Auditorium Theater, Chicago, IL</h4>
        <h6>90 min, SBD, A</h6>
        <p class="setlist">Montana, Cosmik Debris, Camarillo Brillo</p>
        <h4>1973 11 08 - Next</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "73.html",
            searchDate: "1973 11 07", originalDate: "1973 11 07",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertNil(show?.bandInfo)
    }

    func testParseShowFromHTML_bandInfo_nonDateH4CrossReferenceStillScopesBlock() {
        // A non-date cross-reference <h4> (e.g. "Sources for official released
        // recordings...") must still count as "real content in this section" so the
        // Dec-1976-style block is correctly classified scoped, not prefacing.
        let html = """
        <h3>Frank Zappa's Band, October 1976 - February 1977</h3>
        <p class="band">FZ, Ray White, Patrick O'Hearn, Terry Bozzio, Eddie Jobson, Bianca Thornton.</p>
        <h2 id="NY">December 1976 Christmas in New York</h2>
        <h3>Frank Zappa's Band, December 1976</h3>
        <p class="band">FZ, Ray White, Ruth Underwood, Mike Brecker.</p>
        <h4 class="wrongdate">  &diams; <a href="somewhere.html">Sources for this show</a></h4>
        <h2 id="EU">January - February 1977 European tour</h2>
        <h4>1977 02 03 - Pavillon De Paris, Paris, France</h4>
        <h6>info</h6>
        <p class="setlist">Song One, Song Two, Song Three</p>
        <h4>1977 02 04 - Next</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "7677.html",
            searchDate: "1977 02 03", originalDate: "1977 02 03",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertTrue(show?.bandInfo?.contains("Eddie Jobson") ?? false)
        XCTAssertFalse(show?.bandInfo?.contains("Mike Brecker") ?? true)
    }

    func testParseShowFromHTML_bandInfo_blockWithInnerMarkupIsStillMatched() {
        // Regression for rehearsals.html's September 1981 - July 1982 block: its
        // members line ends in "<br>Note: ...", which a `[^<]*` capture skips over
        // entirely — handing every 1981+ rehearsal the stale 1980 lineup sitting
        // further up the page. The block must be matched, its <br> kept as a line
        // break, and the trailing note preserved.
        let html = """
        <h3>Frank Zappa's Band, November - December 1980</h3>
        <p class="band">FZ, Ike Willis, Steve Vai, Ray White, Arthur Barrow, Vinnie Colaiuta.</p>
        <h2 id="r80">September - October 1980 Los Angeles, CA</h2>
        <h4>1980 09 20 - Rehearsal</h4>
        <h6>info</h6>
        <p class="setlist">Song One, Song Two, Song Three</p>
        <h3><a id="r81"></a>Frank Zappa's band, September 1981 - July 1982</h3>
        <p class="band">FZ, Steve Vai, Ray White, Scott Thunes, Chad Wackerman.<br>
        Note: a few of the August 1981 tapes feature someone else.</p>
        <h2 id="r81b">August - September 1981 Los Angeles, CA</h2>
        <h4>1981 08 06 - Rehearsal</h4>
        <h6>info</h6>
        <p class="setlist">Song One, Song Two, Song Three</p>
        <h4>1981 08 07 - Next</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "rehearsals.html",
            searchDate: "1981 08 06", originalDate: "1981 08 06",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertTrue(show?.bandInfo?.contains("Chad Wackerman") ?? false)
        XCTAssertFalse(show?.bandInfo?.contains("Vinnie Colaiuta") ?? true)
        XCTAssertTrue(show?.bandInfo?.contains("Note: a few of the August 1981 tapes") ?? false)
        // <br> survives as a line break rather than gluing the note onto the lineup.
        XCTAssertFalse(show?.bandInfo?.contains("Wackerman.Note:") ?? true)
    }

    func testParseShowFromHTML_bandInfo_titleHeadingWithAnchorIsUsed() {
        // Regression for 7374.html / rehearsals.html: the band-title <h3> wraps an
        // <a id="…"> anchor, so a `[^<]+` capture misses it and the title falls back
        // to an older heading — labelling the right lineup with the wrong date range.
        let html = """
        <h3>The Mothers Of Invention, April - May 1974</h3>
        <p class="band">FZ, Napoleon Murphy Brock, George Duke, Ruth Underwood.</p>
        <h2 id="leg1">April - May 1974</h2>
        <h4>1974 05 08 - Venue A, City, ST</h4>
        <h6>info</h6>
        <p class="setlist">Song One, Song Two, Song Three</p>
        <h3 style="margin-top: 3em;"><a id="jd74"></a>The Mothers Of Invention, June - December 1974</h3>
        <p class="band">FZ, Napoleon Murphy Brock, George Duke, Ruth Underwood, Chester Thompson.</p>
        <h2 id="leg2">June - December 1974</h2>
        <h4>1974 07 05 - Venue B, City, ST</h4>
        <h6>info</h6>
        <p class="setlist">Song One, Song Two, Song Three</p>
        <h4>1974 07 06 - Next</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "7374.html",
            searchDate: "1974 07 05", originalDate: "1974 07 05",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertTrue(show?.bandInfo?.hasPrefix("The Mothers Of Invention, June - December 1974") ?? false)
        XCTAssertTrue(show?.bandInfo?.contains("Chester Thompson") ?? false)
    }

    // MARK: - Venue separator (comma vs dash)

    /// Zappateers separates the date from the venue with " - " on most pages, but
    /// 6970.html uses a comma for every entry and a handful of other pages carry one
    /// comma entry each. The venue parser used to split on the first ASCII hyphen, so
    /// a comma heading produced no venue at all and the show displayed "Unknown Venue".
    /// Reported for 1970 03 07 Olympic Auditorium, Los Angeles, CA.
    private func parseVenue(_ heading: String, searchDate: String,
                            filename: String = "6970.html") -> FZShow? {
        let html = """
        \(heading)
        <h6>60 min, AUD, B+</h6>
        <p class="setlist">Song One, Song Two, Song Three</p>
        <h4>1999 12 31 - Next</h4>
        """
        return FZShowsFetcher.parseShowFromHTML(
            html: html, filename: filename,
            searchDate: searchDate, originalDate: searchDate,
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
    }

    func testExtractVenue_commaSeparatedHeading() {
        // The reported show.
        let show = parseVenue("<h4>1970 03 07, Olympic Auditorium, Los Angeles, CA</h4>",
                              searchDate: "1970 03 07")
        XCTAssertEqual(show?.venue, "Olympic Auditorium, Los Angeles, CA")
    }

    func testExtractVenue_commaHeadingAlsoResolvesLocation() {
        // GeoData.parseLocation is fed the venue string, so the placeholder used to
        // land in `city` too — breaking the tour/location filters for these shows.
        let show = parseVenue("<h4>1970 03 07, Olympic Auditorium, Los Angeles, CA</h4>",
                              searchDate: "1970 03 07")
        XCTAssertEqual(show?.city, "Los Angeles")
        XCTAssertEqual(show?.state, "CA")
    }

    func testExtractVenue_dashSeparatedHeadingUnchanged() {
        let show = parseVenue("<h4>1973 11 07 - Orpheum Theater, Boston, MA</h4>",
                              searchDate: "1973 11 07", filename: "7374.html")
        XCTAssertEqual(show?.venue, "Orpheum Theater, Boston, MA")
    }

    func testExtractVenue_hyphenInsideDateRangeIsNotTheSeparator() {
        // 6669.html: "1966 06 24-25? - Fillmore Auditorium…". Splitting on the first
        // hyphen used to yield the junk venue "25? - Fillmore Auditorium, …".
        let show = parseVenue("<h4>1966 06 24-25? - Fillmore Auditorium, San Francisco, CA</h4>",
                              searchDate: "1966 06 24", filename: "6669.html")
        XCTAssertEqual(show?.venue, "Fillmore Auditorium, San Francisco, CA")
    }

    func testExtractVenue_dateQualifiersBeforeCommaSeparator() {
        // "?" and "or" qualifiers sit between the date and the separator.
        XCTAssertEqual(
            parseVenue("<h4>1968 10 23?, BBC Studios, London, UK</h4>",
                       searchDate: "1968 10 23", filename: "6669.html")?.venue,
            "BBC Studios, London, UK")
        XCTAssertEqual(
            parseVenue("<h4>1970 05 08 or 09, Fillmore East, New York, NY</h4>",
                       searchDate: "1970 05 08")?.venue,
            "Fillmore East, New York, NY")
        // Also when the exceptions dict searches the full qualified date.
        XCTAssertEqual(
            parseVenue("<h4>1970 05 08 or 09, Fillmore East, New York, NY</h4>",
                       searchDate: "1970 05 08 or 09")?.venue,
            "Fillmore East, New York, NY")
    }

    func testExtractVenue_commaHeadingWithQuotedVenueKeepsWholeString() {
        // Only the first separator splits, so a venue containing its own commas
        // survives intact — matching how dash pages behave.
        let show = parseVenue("<h4>1970 05 15, \"Contempo '70\", Pauley Pavilion, UCLA, Los Angeles, CA</h4>",
                              searchDate: "1970 05 15")
        XCTAssertEqual(show?.venue, "\"Contempo '70\", Pauley Pavilion, UCLA, Los Angeles, CA")
    }

    func testExtractVenue_attributedHeadingAndEntitySeparator() {
        // <h4 class="wrongdate"> pointer entries are still imported under their own date.
        XCTAssertEqual(
            parseVenue("<h4 class=\"wrongdate\">1970 05 11, Fillmore East, New York, NY</h4>",
                       searchDate: "1970 05 11")?.venue,
            "Fillmore East, New York, NY")
        // An &ndash; separator is decoded before the split, not after it.
        XCTAssertEqual(
            parseVenue("<h4>1970 06 18 &ndash; VPRO TV, Uddel, Netherlands</h4>",
                       searchDate: "1970 06 18", filename: "7071.html")?.venue,
            "VPRO TV, Uddel, Netherlands")
        // Non-ASCII venue names survive the split (the real 8182.html heading uses a
        // literal UTF-8 "ü", not an entity — decodeHTMLEntities has no &uuml; mapping).
        XCTAssertEqual(
            parseVenue("<h4>1982 06 26, Olympiahalle, München, Germany</h4>",
                       searchDate: "1982 06 26", filename: "8182.html")?.venue,
            "Olympiahalle, München, Germany")
    }

    func testExtractVenue_dateOnlyHeadingFallsBackToPlaceholder() {
        let show = parseVenue("<h4>1970 03 07</h4>", searchDate: "1970 03 07")
        XCTAssertEqual(show?.venue, FZShowsFetcher.unknownVenue)
    }
}
