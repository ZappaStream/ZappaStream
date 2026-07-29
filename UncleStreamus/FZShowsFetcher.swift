import Foundation

// MARK: - HTML Entity Decoding

extension String {
    /// Decodes common HTML entities like &amp; &lt; &gt; &quot; etc.
    func decodeHTMLEntities() -> String {
        var result = self
        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&nbsp;", " "),
            ("&ndash;", "–"),
            ("&mdash;", "—"),
        ]
        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        return result
    }
}

struct FZShow {
    let date: String
    let venue: String
    let soundcheck: String?
    let note: String?
    let showInfo: String
    let setlist: [String]
    let acronyms: [(short: String, full: String)]
    let url: String

    // Location fields
    let city: String?
    let state: String?
    let country: String?

    // Period and tour fields
    let period: String?
    let tour: String?

    // Band info: "{h3 title}\n{members}" or nil
    let bandInfo: String?
}

/// Represents Early/Late show designation
enum ShowTime {
    case early
    case late
    case none

    init(from string: String?) {
        guard let s = string?.uppercased() else {
            self = .none
            return
        }
        if s.contains("(E)") || s.contains("(E") || s.contains("EARLY") {
            self = .early
        } else if s.contains("(L)") || s.contains("(L") || s.contains("LATE") {
            self = .late
        } else {
            self = .none
        }
    }

    var displayName: String {
        switch self {
        case .early: return "Early show"
        case .late: return "Late show"
        case .none: return ""
        }
    }
}

class FZShowsFetcher {

    // MARK: - Constants

    /// User-Agent header for HTTP requests to identify the app to servers
    // Hoisted to avoid recompiling the regex on every setlist parse call.
    // Force-unwrap is acceptable here: this is a literal, never changes, and a
    // typo would be caught immediately at launch rather than silently mid-parse.
    private static let acronymRegex = try! NSRegularExpression(
        pattern: #"<acronym title="([^"]+)">([^<]+)</acronym>"#
    )

    /// Matches the next show's `<h4>` date header; used to bound one show's section.
    /// Single source of truth — referenced from both section-scanning sites.
    private static let nextShowDatePattern = #"<h4>\d{4} \d{2} \d{2}"#

    /// Matches `<h3>` inner text (tour/title lines on 1970–71 style pages).
    /// Hoisted to avoid recompiling on every tour-name extraction.
    private static let h3ContentRegex = try! NSRegularExpression(
        pattern: #"<h3[^>]*>([^<]+)</h3>"#
    )

    /// Matches any `<h2` tag opening (tour-leg section boundary), regardless of
    /// attributes. Used by `extractBandInfo` to scope `<p class="band">` blocks.
    private static let h2TagStartRegex = try! NSRegularExpression(pattern: "<h2")

    /// Matches any `<h4` tag opening, regardless of attributes/content — deliberately
    /// NOT anchored to a date like `nextShowDatePattern`, since a non-date
    /// cross-reference `<h4>` (or a `<h4 class="wrongdate">`) still counts as "real
    /// content in this section" for `extractBandInfo`'s scoping logic.
    private static let h4TagStartRegex = try! NSRegularExpression(pattern: "<h4")

    /// Matches a whole `<p class="band">…</p>` block and captures its inner HTML.
    ///
    /// Deliberately tolerates inner markup (`(?:(?!</p>|<h[1-6]).)*` rather than a
    /// naive `[^<]*`): `rehearsals.html`'s September 1981 - July 1982 block carries a
    /// `<br>` plus a trailing "Note:" line, and a `[^<]*` capture skips it entirely —
    /// which used to hand every 1981+ rehearsal the wrong lineup. The lookahead keeps
    /// an unclosed `<p>` from running away past the next heading into a later section.
    /// Callers run the capture through `plainText(fromInnerHTML:)`.
    private static let bandBlockRegex = try! NSRegularExpression(
        pattern: #"<p class="band">((?:(?!</p>|<h[1-6]).)*)</p>"#,
        options: [.dotMatchesLineSeparators]
    )

    /// Matches an `<h3>` and captures its inner HTML, tolerating nested markup — the
    /// band-title headings on `7374.html` and `rehearsals.html` wrap an `<a id="…">`
    /// anchor, which `h3ContentRegex`'s `[^<]+` capture cannot match.
    ///
    /// Kept separate from `h3ContentRegex` on purpose: that one also feeds
    /// `scanLatestH3DateRange` (tour naming), and widening it there would change the
    /// `tour` field as a side effect of a band-info fix. Only `extractBandInfo` uses this.
    private static let h3TitleRegex = try! NSRegularExpression(
        pattern: #"<h3[^>]*>((?:(?!</h3>).)*)</h3>"#,
        options: [.dotMatchesLineSeparators]
    )

    /// Reduces a captured inner-HTML fragment to display text: `<br>` becomes a line
    /// break, every other tag is dropped, entities are decoded, and runs of blank
    /// lines collapse to one.
    private static func plainText(fromInnerHTML html: String) -> String {
        html
            .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n",
                                  options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .decodeHTMLEntities()
            .replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let userAgentString: String = {
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        return "UncleStreamus/1.0 (\(platform))"
    }()

    // MARK: - Exceptions Dictionary
    // Maps a base metadata date -> (search_date, section split) for shows where the
    // HTML structure doesn't match standard patterns. Keyed by base date ONLY; the
    // Early/Late variants and their section keywords are derived at lookup time via
    // `sectionKeywords(for:)` / `metadataVariants(baseDate:)`.

    /// How an exception's show splits into sections, and which keywords pick each one.
    enum SectionSplit {
        /// No Early/Late split — every `ShowTime` resolves to no keyword filter.
        case none
        /// Standard split: `.early` → ["Early"], `.late` → ["Late"], `.none` → nil.
        case earlyLate
        /// Non-standard split (e.g. "Tape 1"/"Tape 2"). `none` is the keyword used
        /// when no Early/Late is specified.
        case custom(none: [String]?, early: [String], late: [String])
    }

    struct ShowException {
        let searchDate: String          // Date to search for in HTML (may differ from metadata)
        let altFilename: String?        // Alternative filename if not on standard tour page
        let split: SectionSplit         // How the show splits into Early/Late sections

        /// Keywords used to locate the correct section for a given show time.
        func sectionKeywords(for showTime: ShowTime) -> [String]? {
            switch split {
            case .none:
                return nil
            case .earlyLate:
                switch showTime {
                case .none:  return nil
                case .early: return ["Early"]
                case .late:  return ["Late"]
                }
            case .custom(let none, let early, let late):
                switch showTime {
                case .none:  return none
                case .early: return early
                case .late:  return late
                }
            }
        }

        /// The metadata date keys this exception produces, paired with their show time.
        /// Split shows produce bare + " E" + " L" variants; non-split shows only the bare key.
        func metadataVariants(baseDate: String) -> [(key: String, showTime: ShowTime)] {
            switch split {
            case .none:
                return [(baseDate, .none)]
            case .earlyLate, .custom:
                return [(baseDate, .none), ("\(baseDate) E", .early), ("\(baseDate) L", .late)]
            }
        }
    }

    static let exceptions: [String: ShowException] = [
        // === 1970 11 13/14 Fillmore East ===
        // Uncertain dates, listed as "1970 11 13 and/or 14" with "Tape 1" / "Tape 2"
        // sections; without an E/L designation, default to Tape 1.
        "1970 11 13": ShowException(searchDate: "1970 11 13 and/or 14", altFilename: nil,
                                    split: .custom(none: ["Tape 1"], early: ["Tape 1"], late: ["Tape 2"])),
        "1970 11 14": ShowException(searchDate: "1970 11 13 and/or 14", altFilename: nil,
                                    split: .custom(none: ["Tape 1"], early: ["Tape 1"], late: ["Tape 2"])),

        // === 1970 05 08/09 Fillmore East ===
        // Listed as "1970 05 08 or 09"
        "1970 05 08": ShowException(searchDate: "1970 05 08 or 09", altFilename: nil, split: .none),
        "1970 05 09": ShowException(searchDate: "1970 05 08 or 09", altFilename: nil, split: .none),

        // === 1972 date confusions ===
        // Some recordings circulate with wrong dates
        "1972 12 31": ShowException(searchDate: "1972 11 11", altFilename: nil, split: .earlyLate),  // Wrong date, actually 11 11
        "1972 12 12": ShowException(searchDate: "1972 12 09", altFilename: nil, split: .earlyLate),  // Wrong date, actually 12 09

        // === 1973 11 23 Massey Hall, Toronto ===
        // Circulates as "Toronto 11 24" and "Edmonton 11 26"; zappateers notes both as wrong dates
        "1973 11 24": ShowException(searchDate: "1973 11 23", altFilename: nil, split: .earlyLate),
        "1973 11 26": ShowException(searchDate: "1973 11 23", altFilename: nil, split: .earlyLate),
    ]

    // MARK: - Tour Page Mapping

    static func getTourPageFilename(year: Int, month: Int) -> String? {
        switch (year, month) {
        case (1966...1968, _): return "6669.html"
        case (1969, 1...8): return "6669.html"
        case (1970, 2...5): return "6970.html"
        case (1970, 6...12): return "7071.html"
        case (1971, _): return "7071.html"
        case (1972, _): return "72.html"
        case (1973, 2...9): return "73.html"
        case (1973, 10...12): return "7374.html"
        case (1974, 1...12): return "7374.html"
        case (1975, 4...5): return "75.html"
        case (1975, 9...12): return "7576.html"
        case (1976, 1...3): return "7576.html"
        case (1976, 10...12): return "7677.html"
        case (1977, 1...2): return "7677.html"
        case (1977, 9...12): return "7778.html"
        case (1978, 1...2): return "7778.html"
        case (1978, 8...10): return "78.html"
        case (1978, 12): return "rehearsals.html"
        case (1979, _): return "79.html"
        case (1980, 3...7): return "80.html"
        case (1980, 8...12): return "80fall.html"
        case (1981, 9...12): return "8182.html"
        case (1982, 5...7): return "8182.html"
        case (1984, 7...12): return "84.html"
        case (1988, 2...6): return "88.html"
        default: return nil
        }
    }

    // MARK: - Public API

    /// Why a live fetch failed. Lets callers tell a genuine "the show isn't on the
    /// page" miss apart from a network/transport failure, instead of collapsing both
    /// into `nil` (which mislabels outages as "not found" and discards retry intent).
    enum FetchError: Error, CustomStringConvertible {
        case invalidURL          // couldn't parse the date / form a page URL
        case network(Error)      // URLSession transport failure
        case noData              // response body was empty or not UTF-8 decodable
        case showNotFound        // page loaded OK but the requested date wasn't present

        var description: String {
            switch self {
            case .invalidURL:     return "invalid URL"
            case .network(let e): return "network error: \(e.localizedDescription)"
            case .noData:         return "no/undecodable data"
            case .showNotFound:   return "show not found"
            }
        }
    }

    static func fetchShowInfo(date: String, showTime: ShowTime = .none,
                              completion: @escaping (Result<FZShow, FetchError>) -> Void) {
        // Strip optional E/L suffix (e.g. "1982 07 09 E" → "1982 07 09")
        // showDate keys now include the suffix; callers may pass either form
        let baseParts = date.components(separatedBy: " ")
        let baseDate = baseParts.prefix(3).joined(separator: " ")

        // Parse date format "1982 07 09"
        let parts = baseDate.components(separatedBy: " ")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let _ = Int(parts[2]) else {
            completion(.failure(.showNotFound))
            return
        }

        // Check for exceptions (keyed by base date; E/L keywords derived at lookup)
        let exception = exceptions[baseDate]
        let searchDate = exception?.searchDate ?? baseDate
        let sectionKeywords = exception?.sectionKeywords(for: showTime)

        #if DEBUG
        if exception != nil {
            print("📋 Using exception mapping: \(baseDate) -> \(searchDate)")
        }
        #endif

        // Determine filename
        let filename = exception?.altFilename ?? getTourPageFilename(year: year, month: month)

        guard let primaryFilename = filename else {
            completion(.failure(.showNotFound))
            return
        }

        let primaryURLString = "https://www.zappateers.com/fzshows/\(primaryFilename)"
        fetchFromURL(urlString: primaryURLString, filename: primaryFilename, searchDate: searchDate, originalDate: baseDate,
                     showTime: showTime, sectionKeywords: sectionKeywords) { result in
            switch result {
            case .success:
                completion(result)
            case .failure(.showNotFound):
                // Fall back to rehearsals.html only when the page loaded but lacked
                // the date — a transport failure is propagated, not masked or retried.
                #if DEBUG
                print("🔄 Primary page had no match, trying rehearsals.html")
                #endif
                let rehearsalsURLString = "https://www.zappateers.com/fzshows/rehearsals.html"
                self.fetchFromURL(urlString: rehearsalsURLString, filename: "rehearsals.html", searchDate: searchDate, originalDate: baseDate,
                                  showTime: showTime, sectionKeywords: sectionKeywords, completion: completion)
            case .failure:
                completion(result)
            }
        }
    }

    // MARK: - Private Helpers

    private static func fetchFromURL(urlString: String, filename: String, searchDate: String, originalDate: String,
                                     showTime: ShowTime, sectionKeywords: [String]?,
                                     completion: @escaping (Result<FZShow, FetchError>) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(.failure(.invalidURL))
            return
        }

        #if DEBUG
        print("📖 Fetching show info from: \(urlString)")
        #endif

        var request = URLRequest(url: url)
        request.setValue(userAgentString, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                #if DEBUG
                print("❌ Network error fetching HTML: \(error.localizedDescription)")
                #endif
                completion(.failure(.network(error)))
                return
            }
            guard let data = data,
                  let html = String(data: data, encoding: .utf8) else {
                #if DEBUG
                print("❌ Failed to decode HTML")
                #endif
                completion(.failure(.noData))
                return
            }

            if let show = parseShowFromHTML(html: html, filename: filename, searchDate: searchDate, originalDate: originalDate,
                                            showTime: showTime, sectionKeywords: sectionKeywords, url: urlString) {
                completion(.success(show))
            } else {
                completion(.failure(.showNotFound))
            }
        }.resume()
    }

    /// Splits a setlist text string on commas, respecting parentheses and brackets.
    /// Entries with 2 or fewer characters are filtered out.
    static func parseSetlist(_ text: String) -> [String] {
        var songs: [String] = []
        var currentSong = ""
        var parenDepth = 0
        var bracketDepth = 0

        for char in text {
            if char == "(" {
                parenDepth += 1
                currentSong.append(char)
            } else if char == ")" {
                // Clamp at 0: a stray/extra closing paren in the source HTML (typos
                // happen) would otherwise drive depth negative and never recover,
                // causing every subsequent comma to be treated as "inside a group"
                // and gluing the rest of the setlist into one giant entry.
                parenDepth = max(0, parenDepth - 1)
                currentSong.append(char)
            } else if char == "[" {
                bracketDepth += 1
                currentSong.append(char)
            } else if char == "]" {
                bracketDepth = 0
                currentSong.append(char)
            } else if char == "," && parenDepth == 0 && bracketDepth == 0 {
                let trimmed = currentSong.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed.count > 2 {
                    songs.append(trimmed)
                }
                currentSong = ""
            } else {
                currentSong.append(char)
            }
        }

        let trimmed = currentSong.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed.count > 2 {
            songs.append(trimmed)
        }

        return foldStandaloneBracketedNotes(foldStandaloneQuotes(songs))
    }

    /// Some setlists have a stray comma between a song and its trailing "[incl. ...]"
    /// bracket note (e.g. "Let's Move To Cleveland, [incl. Is That All There Is?, G]")
    /// instead of attaching it directly ("Song [incl. ...]"). A *correctly* attached
    /// bracket note never becomes its own comma-split entry — the depth tracking above
    /// already protects commas inside "[...]" — so any entry that is itself wholly
    /// wrapped in brackets is always the result of a stray comma. Fold it back into the
    /// preceding entry so it renders as an annotation rather than a bogus standalone
    /// track. Entries with no preceding song are left as-is.
    static func foldStandaloneBracketedNotes(_ songs: [String]) -> [String] {
        var merged: [String] = []
        for song in songs {
            if song.hasPrefix("["), song.hasSuffix("]"), !merged.isEmpty {
                merged[merged.count - 1] += " \(song)"
            } else {
                merged.append(song)
            }
        }
        return merged
    }

    /// Some setlists list a quote as its own comma-separated entry (e.g.
    /// "Johnny's Theme, q: Duke Of Earl, Wonderful Wino") rather than wrapping
    /// it in parentheses on the preceding song. Fold those into the preceding
    /// entry as "(q: ...)" so SongFormatter renders them as quotes instead of
    /// standalone tracks. Entries with no preceding song are left as-is.
    static func foldStandaloneQuotes(_ songs: [String]) -> [String] {
        var merged: [String] = []
        for song in songs {
            if song.lowercased().hasPrefix("q:"), !merged.isEmpty {
                merged[merged.count - 1] += " (\(song))"
            } else {
                merged.append(song)
            }
        }
        return merged
    }

    /// Re-derives a setlist that was previously split by an older version of
    /// `parseSetlist` by rejoining its entries and re-splitting with the
    /// current logic. This lets a one-time migration fix already-cached shows
    /// (e.g. standalone "q:" entries, or songs glued together by a stray
    /// closing-paren cascade) without re-fetching from zappateers — and it
    /// automatically benefits from any future `parseSetlist` improvements.
    /// Returns nil if re-deriving produces the same result (no migration needed).
    static func redrivedSetlist(from existing: [String]) -> [String]? {
        guard !existing.isEmpty else { return nil }
        let rederived = parseSetlist(existing.joined(separator: ", "))
        return rederived != existing ? rederived : nil
    }

    static func parseShowFromHTML(html: String, filename: String, searchDate: String, originalDate: String,
                                          showTime: ShowTime, sectionKeywords: [String]?,
                                          url: String) -> FZShow? {
        // Find the date inside an <h4> tag (not in notes or other places)
        // Search for "<h4>DATE" or "<h4 class=...>DATE" patterns
        let h4Pattern = "<h4[^>]*>\(NSRegularExpression.escapedPattern(for: searchDate))"
        guard let h4Match = html.range(of: h4Pattern, options: .regularExpression) else {
            #if DEBUG
            print("❌ Date \(searchDate) not found in any <h4> tag")
            #endif
            return nil
        }

        // Find the start of this <h4> tag, then </h4> after it
        let fullH4Start = h4Match.lowerBound
        guard let h4End = html.range(of: "</h4>", range: fullH4Start..<html.endIndex) else {
            #if DEBUG
            print("❌ Could not find </h4> tag after <h4>")
            #endif
            return nil
        }

        let fullH4 = String(html[fullH4Start..<h4End.upperBound])
        #if DEBUG
        print("🏟️ FULL h4: '\(fullH4)'")
        #endif

        var venue = "Unknown Venue"
        if let parsedVenue = extractVenue(fromH4: fullH4) {
            venue = parsedVenue
            #if DEBUG
            print("🏟️ Venue: '\(venue)'")
            #endif
        }

        // Find end of THIS show's entire section (next h4 date OR end of file)
        let showSectionEnd: String.Index
        if let nextH4Range = html.range(of: Self.nextShowDatePattern, options: .regularExpression,
                                        range: h4End.upperBound..<html.endIndex) {
            showSectionEnd = nextH4Range.lowerBound
        } else {
            showSectionEnd = html.endIndex
        }
        let showSection = String(html[h4End.upperBound..<showSectionEnd])
        #if DEBUG
        print("📄 Show section length: \(showSection.count) chars")
        #endif

        // Select the subsection matching the requested show time, then parse its
        // show-info / note / setlist independently.
        let (targetSection, detectedShowType) = selectTargetSection(
            html: html, sectionStart: h4End.upperBound, showSection: showSection,
            showSectionEnd: showSectionEnd, showTime: showTime, sectionKeywords: sectionKeywords)

        let showInfo = parseShowInfo(fromSection: targetSection) ?? "No show info"
        let note = parseNote(fromSection: targetSection)
        let (setlist, acronyms) = parseSetlistAndAcronyms(fromSection: targetSection)
            ?? (["No setlist available"], [])

        // Build final show info with show type
        let finalShowType = showTime != .none ? showTime : detectedShowType
        let finalShowInfo: String
        if finalShowType != .none {
            finalShowInfo = "\(finalShowType.displayName) - \(showInfo)"
        } else {
            finalShowInfo = showInfo
        }

        // Extract period name from filename
        let period = GeoData.periodName(forFilename: filename)

        // Extract tour name from HTML (h3 tag preceding this show)
        let tour = extractTourName(html: html, beforeIndex: h4Match.lowerBound)

        // Extract band lineup from HTML (last <p class="band"> block before this show)
        let bandInfo = extractBandInfo(html: html, beforeIndex: h4Match.lowerBound)

        // Parse location from venue
        let location = GeoData.parseLocation(from: venue)

        #if DEBUG
        print("✅ SUCCESS: \(venue) | \(setlist.count) songs | \(finalShowInfo)")
        print("   📍 Location: \(location.city ?? "?"), \(location.state ?? "?"), \(location.country ?? "?")")
        print("   🗓️ Period: \(period ?? "?") | Tour: \(tour ?? "?")")
        #endif

        // Include E/L suffix so Early and Late shows from the same date get distinct showDate keys
        let dateKey: String
        switch showTime {
        case .early: dateKey = "\(originalDate) E"
        case .late:  dateKey = "\(originalDate) L"
        case .none:  dateKey = originalDate
        }

        return FZShow(
            date: dateKey,
            venue: venue,
            soundcheck: nil,
            note: note,
            showInfo: finalShowInfo,
            setlist: setlist,
            acronyms: acronyms,
            url: url,
            city: location.city,
            state: location.state,
            country: location.country,
            period: period,
            tour: tour,
            bandInfo: bandInfo
        )
    }

    // MARK: - parseShowFromHTML Helpers

    /// Parses the venue name from a show's full `<h4>` heading (the text after the
    /// dash). Returns nil when the heading has no dash.
    private static func extractVenue(fromH4 fullH4: String) -> String? {
        guard let dashIndex = fullH4.firstIndex(of: "-") else { return nil }
        let afterDash = fullH4[fullH4.index(after: dashIndex)..<fullH4.endIndex]
        return String(afterDash)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .decodeHTMLEntities()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Selects the subsection of a show's HTML matching the requested show time.
    /// Uses exception `sectionKeywords` when provided, otherwise the Early/Late
    /// `<h5>` headings (falling back to the whole section, optionally preferring a
    /// "Show" section over a "Soundcheck"). Returns the target subsection text plus
    /// any show type auto-detected when none was requested.
    private static func selectTargetSection(html: String, sectionStart: String.Index,
                                            showSection: String, showSectionEnd: String.Index,
                                            showTime: ShowTime, sectionKeywords: [String]?)
        -> (section: String, detectedShowType: ShowTime) {

        // Translate a range within `showSection` to the equivalent index in `html`.
        func absIndex(of subRange: Range<String.Index>) -> String.Index {
            html.index(sectionStart,
                       offsetBy: showSection.distance(from: showSection.startIndex, to: subRange.lowerBound))
        }

        if let keywords = sectionKeywords {
            // Use exception keywords to find the right section
            let foundRange = keywords.lazy.compactMap {
                showSection.range(of: $0, options: .caseInsensitive)
            }.first
            if let range = foundRange {
                return (String(html[absIndex(of: range)..<showSectionEnd]), .none)
            }
            return (showSection, .none)
        }

        if showTime != .none {
            // Find Early/Late section
            let targetKeyword = showTime == .early ? "Early" : "Late"
            guard let h5Range = showSection.range(of: "<h5>\(targetKeyword)", options: .caseInsensitive) else {
                #if DEBUG
                print("🎭 No \(targetKeyword) section found, using full show section")
                #endif
                return (showSection, .none)
            }
            // Truncate at the next sibling <h5> so notes/setlist from the other show aren't included
            let subsectionEnd: String.Index
            if let nextH5Range = showSection.range(of: "<h5>", options: .caseInsensitive,
                                                   range: h5Range.upperBound..<showSection.endIndex) {
                subsectionEnd = absIndex(of: nextH5Range)
            } else {
                subsectionEnd = showSectionEnd
            }
            #if DEBUG
            print("🎭 Found \(targetKeyword) show section")
            #endif
            return (String(html[absIndex(of: h5Range)..<subsectionEnd]), showTime)
        }

        // No showTime specified - prefer a "Show" section over "Soundcheck", else
        // default to the first (Early) of any Early/Late split.
        if let showRange = showSection.range(of: "<h5>Show", options: .caseInsensitive) {
            #if DEBUG
            print("🎭 Found Show section (preferring over Soundcheck)")
            #endif
            return (String(html[absIndex(of: showRange)..<showSectionEnd]), .none)
        } else if showSection.range(of: "<h5>Early", options: .caseInsensitive) != nil {
            #if DEBUG
            print("🎭 Detected Early show (defaulting to first)")
            #endif
            return (showSection, .early)
        }
        return (showSection, .none)
    }

    /// Parses all `<h6>` show-info blocks from a target section, joining multiple
    /// sources with " • ". Sources can be separate `<h6>` tags or `<br>`-separated
    /// within one. Returns nil when the section has no show-info tags.
    private static func parseShowInfo(fromSection targetSection: String) -> String? {
        let h6Pattern = "<h6>([\\s\\S]*?)</h6>"
        guard let h6Regex = try? NSRegularExpression(pattern: h6Pattern, options: []) else { return nil }

        // Only search up to the setlist or note to avoid picking up h6 from other shows
        let searchEnd = targetSection.range(of: #"<p class\s*=\s*"setlist">"#, options: .regularExpression)?.lowerBound
            ?? targetSection.range(of: #"<p class\s*=\s*"note">"#, options: .regularExpression)?.lowerBound
            ?? targetSection.endIndex
        let searchSection = String(targetSection[..<searchEnd])
        let nsRange = NSRange(searchSection.startIndex..<searchSection.endIndex, in: searchSection)

        var allShowInfos: [String] = []
        h6Regex.enumerateMatches(in: searchSection, range: nsRange) { match, _, _ in
            if let match = match, let range = Range(match.range(at: 1), in: searchSection) {
                let h6Content = String(searchSection[range])
                    .replacingOccurrences(of: #"<[Bb][Rr]\s*/?>"#, with: " • ", options: .regularExpression)
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .decodeHTMLEntities()
                    .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !h6Content.isEmpty {
                    allShowInfos.append(h6Content)
                }
            }
        }

        guard !allShowInfos.isEmpty else { return nil }
        let showInfo = allShowInfos.joined(separator: " • ")
        #if DEBUG
        print("📊 Show info (\(allShowInfos.count) source(s)): '\(showInfo)'")
        #endif
        return showInfo
    }

    /// Parses the note paragraph (`<p class="note">`) from a target section, if
    /// present, converting anchor tags to markdown links and stripping the rest.
    private static func parseNote(fromSection targetSection: String) -> String? {
        guard let noteStart = targetSection.range(of: #"<p class\s*=\s*"note">"#, options: .regularExpression),
              let noteEnd = targetSection.range(of: "</p>", range: noteStart.upperBound..<targetSection.endIndex)
        else { return nil }

        let note = String(targetSection[noteStart.lowerBound..<noteEnd.upperBound])
            .replacingOccurrences(of: #"<p class\s*=\s*"note">"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "</p>", with: "")
            .replacingOccurrences(of: #"<a href="([^"]+)">([^<]+)</a>"#, with: "[$2]($1)", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .decodeHTMLEntities()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        print("📝 Note: '\(note)'")
        #endif
        return note
    }

    /// Parses the setlist (`<p class="setlist">`) and any acronym mappings from a
    /// target section. The setlist ends at `</p>` or the next `<h5>`/`<h4>` heading,
    /// whichever comes first (some shows have unclosed setlist tags); if neither is
    /// present, it runs to the end of the target section, which callers have already
    /// bounded to this show/subsection (e.g. an Early show's `<h5>` sibling boundary
    /// removes the trailing `<h5>Late` a broken `<p>` would otherwise have fallen
    /// back on). Returns nil only when the section has no `<p class="setlist">` at all.
    private static func parseSetlistAndAcronyms(fromSection targetSection: String)
        -> (setlist: [String], acronyms: [(short: String, full: String)])? {

        guard let setlistStart = targetSection.range(of: #"<p class\s*=\s*"setlist">"#, options: .regularExpression)
        else { return nil }
        let searchFrom = setlistStart.upperBound

        var setlistEndIndex: String.Index?
        if let pEnd = targetSection.range(of: "</p>", range: searchFrom..<targetSection.endIndex) {
            setlistEndIndex = pEnd.lowerBound
        }
        for heading in ["<h5>", "<h4>"] {
            if let hRange = targetSection.range(of: heading, range: searchFrom..<targetSection.endIndex) {
                if setlistEndIndex == nil || hRange.lowerBound < setlistEndIndex! {
                    setlistEndIndex = hRange.lowerBound
                }
            }
        }
        let finalSetlistEndIndex = setlistEndIndex ?? targetSection.endIndex

        let rawSetlistText = String(targetSection[setlistStart.upperBound..<finalSetlistEndIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract acronym mappings from raw HTML before stripping tags
        var acronyms: [(short: String, full: String)] = []
        let nsRange = NSRange(rawSetlistText.startIndex..<rawSetlistText.endIndex, in: rawSetlistText)
        for match in FZShowsFetcher.acronymRegex.matches(in: rawSetlistText, range: nsRange) {
            if let fullRange = Range(match.range(at: 1), in: rawSetlistText),
               let shortRange = Range(match.range(at: 2), in: rawSetlistText) {
                acronyms.append((short: String(rawSetlistText[shortRange]), full: String(rawSetlistText[fullRange])))
            }
        }

        // Now strip HTML, decode entities, and parse songs
        let setlistText = rawSetlistText
            .replacingOccurrences(of: #"<acronym title="([^"]+)">([^<]+)</acronym>"#, with: "$2", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .decodeHTMLEntities()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Split on commas, but not commas inside parentheses or brackets
        return (parseSetlist(setlistText), acronyms)
    }

    /// Extracts the tour name from the HTML structure before the show date
    /// Structure 1 (most tours):
    /// <h2>September - December 1977<br>
    /// <span class="redbig">USA and Canada tour</span></h2>
    /// Result: "USA and Canada tour (September - December 1977)"
    ///
    /// Structure 2 (1970-1971 tours):
    /// <h2><span class="redbig">1970</span></h2>
    /// <h3>The Mothers Of Invention, June - December 1970</h3>
    /// Result: "The Mothers Of Invention (June - December 1970)"
    private static func extractTourName(html: String, beforeIndex: String.Index) -> String? {
        // Get the HTML before this show
        let precedingHTML = String(html[html.startIndex..<beforeIndex])

        let h2 = scanLatestH2TourInfo(in: precedingHTML)
        let h3DateRange = scanLatestH3DateRange(in: precedingHTML)

        // Combine tour name and date range
        // Priority:
        // 1. h2 tour name with h2 date range (e.g., "USA and Canada tour (September - December 1977)")
        // 2. h2 tour name with h3 date range
        // 3. h2 year with h3 date range (for 1970-1971 pages: "1970 (June - December 1970)")
        if let tour = h2.tourName {
            if let date = h2.dateRange, !date.isEmpty {
                return "\(tour) (\(date))"
            } else if let date = h3DateRange, !date.isEmpty {
                return "\(tour) (\(date))"
            } else {
                return tour
            }
        }

        // Fall back to year + h3 date range for pages like 1970-1971
        if let year = h2.year, let dateRange = h3DateRange {
            return "\(year) (\(dateRange))"
        }

        return nil
    }

    /// Scans every `<h2>` block before a show and returns the most recent tour name
    /// (or bare year) and its date range, using the "last wins" accumulation the
    /// inline scan relied on. `tourName` and `year` are mutually exclusive.
    private static func scanLatestH2TourInfo(in precedingHTML: String)
        -> (tourName: String?, year: String?, dateRange: String?) {
        var tourName: String? = nil
        var year: String? = nil  // For year-only entries like "1970"
        var dateRange: String? = nil

        let h2Pattern = "<h2[^>]*>([\\s\\S]*?)</h2>"
        guard let regex = try? NSRegularExpression(pattern: h2Pattern, options: []) else {
            return (nil, nil, nil)
        }
        let nsRange = NSRange(precedingHTML.startIndex..<precedingHTML.endIndex, in: precedingHTML)

        regex.enumerateMatches(in: precedingHTML, range: nsRange) { match, _, _ in
            guard let match = match,
                  let range = Range(match.range(at: 1), in: precedingHTML) else { return }

            let h2Content = String(precedingHTML[range])

            // Extract tour name from <span class="redbig">...</span>
            let spanPattern = "<span class=\"redbig\">([^<]+)</span>"
            if let spanRegex = try? NSRegularExpression(pattern: spanPattern),
               let spanMatch = spanRegex.firstMatch(in: h2Content, range: NSRange(h2Content.startIndex..<h2Content.endIndex, in: h2Content)),
               let spanRange = Range(spanMatch.range(at: 1), in: h2Content) {
                let extracted = String(h2Content[spanRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                // Check if it's a year-only entry like "1970", "1971"
                if !extracted.isEmpty {
                    if extracted.rangeOfCharacter(from: .letters) != nil && extracted.count > 4 {
                        // It's a real tour name (contains letters and more than 4 chars)
                        tourName = extracted
                        year = nil  // Clear year since we have a real tour name
                    } else if extracted.count == 4, Int(extracted) != nil {
                        // It's a year like "1970"
                        year = extracted
                        tourName = nil  // Clear tour name since it's just a year
                    }
                }
            }

            // Extract date range (text before <br> or <span>, after any <a> tag)
            let cleanedContent = h2Content
                .replacingOccurrences(of: "<a[^>]*></a>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "<a[^>]*>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "</a>", with: "")

            if let brRange = cleanedContent.range(of: "<br") {
                let dateCandidate = String(cleanedContent[..<brRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !dateCandidate.isEmpty {
                    dateRange = dateCandidate
                }
            } else if let spanRange = cleanedContent.range(of: "<span") {
                let dateCandidate = String(cleanedContent[..<spanRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !dateCandidate.isEmpty {
                    dateRange = dateCandidate
                }
            }
        }
        return (tourName, year, dateRange)
    }

    /// Scans every `<h3>` "Band Name, Date Range" block (1970-1971 style pages)
    /// before a show and returns the date range from the last one.
    private static func scanLatestH3DateRange(in precedingHTML: String) -> String? {
        var dateRange: String? = nil
        let nsRange = NSRange(precedingHTML.startIndex..<precedingHTML.endIndex, in: precedingHTML)

        Self.h3ContentRegex.enumerateMatches(in: precedingHTML, range: nsRange) { match, _, _ in
            guard let match = match,
                  let range = Range(match.range(at: 1), in: precedingHTML) else { return }

            let h3Content = String(precedingHTML[range]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Parse "Band Name, Date Range" format to extract date range
            if let commaRange = h3Content.range(of: ", ", options: .backwards) {
                dateRange = String(h3Content[commaRange.upperBound...])
            }
        }
        return dateRange
    }

    // MARK: - Bulk Import

    /// Parses all shows from a downloaded HTML page for local DB import.
    /// Returns one FZShow per date/variant found, including exception mappings for this filename.
    static func importAllShows(fromHTML html: String, filename: String, url: String) -> [FZShow] {
        var shows: [FZShow] = []

        // Step 1: Standard import — find all <h4> entries with YYYY MM DD dates
        let datePattern = "<h4[^>]*>(\\d{4} \\d{2} \\d{2})"
        if let regex = try? NSRegularExpression(pattern: datePattern) {
            let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
            let matches = regex.matches(in: html, range: nsRange)

            for match in matches {
                guard let dateRange = Range(match.range(at: 1), in: html),
                      let h4Range = Range(match.range(at: 0), in: html) else { continue }
                let dateStr = String(html[dateRange])

                // Find section bounds to detect Early/Late subsections
                guard let h4End = html.range(of: "</h4>", range: h4Range.upperBound..<html.endIndex) else { continue }
                let nextShowSectionEnd: String.Index
                if let nextH4 = html.range(of: Self.nextShowDatePattern, options: .regularExpression,
                                            range: h4End.upperBound..<html.endIndex) {
                    nextShowSectionEnd = nextH4.lowerBound
                } else {
                    nextShowSectionEnd = html.endIndex
                }
                let section = String(html[h4End.upperBound..<nextShowSectionEnd])
                let hasEarly = section.range(of: "<h5>Early", options: .caseInsensitive) != nil
                let hasLate  = section.range(of: "<h5>Late",  options: .caseInsensitive) != nil

                if hasEarly || hasLate {
                    if hasEarly, let show = parseShowFromHTML(html: html, filename: filename, searchDate: dateStr,
                                                              originalDate: dateStr, showTime: .early,
                                                              sectionKeywords: nil, url: url) {
                        shows.append(show)
                    }
                    if hasLate, let show = parseShowFromHTML(html: html, filename: filename, searchDate: dateStr,
                                                             originalDate: dateStr, showTime: .late,
                                                             sectionKeywords: nil, url: url) {
                        shows.append(show)
                    }
                } else {
                    if let show = parseShowFromHTML(html: html, filename: filename, searchDate: dateStr,
                                                   originalDate: dateStr, showTime: .none,
                                                   sectionKeywords: nil, url: url) {
                        shows.append(show)
                    }
                }
            }
        }

        // Step 2: Exception mappings — import under metadata date keys so lookup needs no translation
        for (baseDate, exc) in exceptions {
            // Determine which page this exception belongs to
            let parts = baseDate.components(separatedBy: " ")
            guard parts.count >= 3, let year = Int(parts[0]), let month = Int(parts[1]) else { continue }

            let expectedFilename = exc.altFilename ?? getTourPageFilename(year: year, month: month)
            guard expectedFilename == filename else { continue }

            // Expand the base date into its metadata variants (bare + E/L when split).
            for variant in exc.metadataVariants(baseDate: baseDate) {
                guard let parsed = parseShowFromHTML(html: html, filename: filename,
                                                     searchDate: exc.searchDate, originalDate: baseDate,
                                                     showTime: variant.showTime,
                                                     sectionKeywords: exc.sectionKeywords(for: variant.showTime),
                                                     url: url) else { continue }

                // Build a show with the metadata date key so DB lookup needs no exceptions dict
                let metadataShow = FZShow(
                    date: variant.key,
                    venue: parsed.venue, soundcheck: parsed.soundcheck, note: parsed.note,
                    showInfo: parsed.showInfo, setlist: parsed.setlist, acronyms: parsed.acronyms,
                    url: parsed.url, city: parsed.city, state: parsed.state, country: parsed.country,
                    period: parsed.period, tour: parsed.tour, bandInfo: parsed.bandInfo
                )
                shows.append(metadataShow)
            }
        }

        return shows
    }

    /// A single `<p class="band">...</p>` match: its full range plus decoded/trimmed text.
    private struct BandBlock {
        let range: Range<String.Index>
        let text: String
    }

    /// Collects every `<p class="band">...</p>` block in `text`, in document order.
    private static func collectBandBlocks(in text: String) -> [BandBlock] {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return Self.bandBlockRegex.matches(in: text, range: nsRange).compactMap { match in
            guard let fullRange = Range(match.range(at: 0), in: text),
                  let contentRange = Range(match.range(at: 1), in: text) else { return nil }
            return BandBlock(range: fullRange, text: plainText(fromInnerHTML: String(text[contentRange])))
        }
    }

    /// Collects the start position of every match of `regex` in `text`, in document order.
    private static func tagStartIndices(matching regex: NSRegularExpression, in text: String) -> [String.Index] {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { Range($0.range, in: text)?.lowerBound }
    }

    /// Extracts the band lineup from the HTML structure before the show date.
    ///
    /// A page can contain multiple `<p class="band">` blocks across `<h2>` tour-leg
    /// sections. Some persist forward as the default lineup until superseded (e.g. a
    /// mid-tour personnel change); others are a one-off scoped to a single short run
    /// (e.g. an expanded horn section for one week of shows) and must NOT bleed into
    /// later, unrelated tour legs that don't define their own block.
    ///
    /// A block is classified by what immediately follows it: if no `<h4>` (show or
    /// cross-reference heading) appears before the next `<h2>` section boundary, the
    /// block was never actually "used" within its own section and is treated as a
    /// persisting default; otherwise it's scoped to just that section. Resolution
    /// walks blocks backward from the show, using the nearest one that either shares
    /// the show's section or is a persisting default.
    ///
    /// Known limitation (not handled): a persisting default can still incorrectly
    /// bleed into a much later, structurally unrelated `<h2>` section that itself
    /// defines no block and has no nearer override to stop it (e.g. `rehearsals.html`'s
    /// "September 1981 - July 1982" band bleeding into a "Late 1987" section). Fixing
    /// that would require parsing the free-text date ranges in `<h3>` titles.
    ///
    /// Returns "{h3 title}\n{members}" or nil if no applicable band block is found.
    private static func extractBandInfo(html: String, beforeIndex: String.Index) -> String? {
        let precedingHTML = String(html[html.startIndex..<beforeIndex])

        let bandBlocks = collectBandBlocks(in: precedingHTML)
        guard !bandBlocks.isEmpty else { return nil }

        let h2Starts = tagStartIndices(matching: Self.h2TagStartRegex, in: precedingHTML)
        let h4Starts = tagStartIndices(matching: Self.h4TagStartRegex, in: precedingHTML)

        var winner: BandBlock? = nil
        for block in bandBlocks.reversed() {
            guard let nextH2 = h2Starts.first(where: { $0 > block.range.upperBound }) else {
                // No <h2> between this block and the show: same section, use it.
                winner = block
                break
            }
            let h4Intervenes = h4Starts.contains { $0 > block.range.upperBound && $0 < nextH2 }
            if !h4Intervenes {
                // Nothing used this block within its own section: it's a persisting default.
                winner = block
                break
            }
            // Scoped to its own (different) section; keep searching further back.
        }

        guard let bandRange = winner?.range, let membersText = winner?.text, !membersText.isEmpty else {
            return nil
        }

        // Find the last <h3> before the winning band block for the title
        let beforeBand = String(precedingHTML[precedingHTML.startIndex..<bandRange.lowerBound])
        var titleText: String? = nil

        let nsRange = NSRange(beforeBand.startIndex..<beforeBand.endIndex, in: beforeBand)
        Self.h3TitleRegex.enumerateMatches(in: beforeBand, range: nsRange) { match, _, _ in
            guard let match = match,
                  let range = Range(match.range(at: 1), in: beforeBand) else { return }
            let candidate = plainText(fromInnerHTML: String(beforeBand[range]))
            if !candidate.isEmpty {
                titleText = candidate
            }
        }

        if let title = titleText {
            return "\(title)\n\(membersText)"
        } else {
            return membersText
        }
    }
}
