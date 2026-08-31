import Foundation

/// Which locally installed CLI produces meeting summaries. sezish never ships
/// or proxies a model for this: the user's own tool, the user's own account.
public enum SummaryEngineKind: String, Sendable, CaseIterable {
    case claude   // Claude Code CLI
    case codex    // OpenAI Codex CLI
}

/// Where the knowledge vault lives inside the user's notesFolder, and what its card
/// directories are called. Named once here because two sides must agree: the prompt
/// tells the agent these paths, and later stages create and read them on disk.
public enum SummaryVault {
    /// The vault is a subdirectory, not the notesFolder itself: the user's notes are
    /// theirs, and everything the agent writes stays in one folder they can delete.
    public static let subdirectory = "sezish"
    public static let meetingsDir = "meetings"
    public static let peopleDir = "people"
    public static let projectsDir = "projects"
    public static let decisionsDir = "decisions"
    /// Hub note linking every card — the entry point of the vault graph.
    public static let hubFile = "_index.md"
}

/// Builds the instruction text handed to the summary CLI. The template is English
/// because models follow English instructions most reliably, with one explicit
/// directive for the language the user actually reads the cards in.
public enum SummaryPromptBuilder {
    public static func build(
        outputLanguage: AppLanguage,
        meetingMdPath: String,
        notesFolderPath: String
    ) -> String {
        let languageName = switch outputLanguage {
        case .ru: "Russian"
        case .uz: "Uzbek"
        case .kk: "Kazakh"
        case .ky: "Kyrgyz"
        case .en: "English"
        }

        return """
        ROLE
        You maintain the user's personal knowledge vault, built from meeting transcripts.
        Your work directory is the vault at \(notesFolderPath).

        INPUT
        Read the meeting transcript file at \(meetingMdPath). It is markdown. Transcript
        lines may be tagged "Я:" / "Они:" (ru) or "Men:" / "Ular:" (uz): the mic side
        ("Я" / "Men") is the vault owner, the system side ("Они" / "Ular") is the other
        party on the call.

        CARD FORMAT
        Every card is one markdown file with YAML frontmatter:

        ---
        type: meeting | contact | project | decision
        description: one-line search snippet, NEVER a repeat of the title
        tags: [2-5 tags, lowercase, kebab-case]
        status: active
        created: YYYY-MM-DD
        ---

        # Title

        Prose body.

        ## Log
        - YYYY-MM-DD — what changed (optional; one line per dated update)

        ## Related
        - [[wikilink]]

        The filename is the kebab-case stem of the title, and it IS the wikilink target.

        Vault layout:
        - sezish/meetings/  — type: meeting
        - sezish/people/    — type: contact
        - sezish/projects/  — type: project
        - sezish/decisions/ — type: decision
        - sezish/_index.md  — the hub. Create it with a heading and a links list if absent.

        WORKFLOW (mandatory order)
        1. LOOKUP FIRST. Before writing any entity, search the existing cards (grep/glob
           across the vault) for it. NEVER create a near-duplicate of a card that exists.
        2. For each entity decide exactly one of:
           ADD       — no card exists yet; create one.
           NOOP      — a card exists and the transcript adds nothing; leave it alone.
           UPDATE    — same subject, new facts; sharpen `description` and append a dated
                       line to `## Log`.
           SUPERSEDE — a new fact contradicts a stored one; rewrite the field and move the
                       old value into an append-only `## History` section with a date range.
        3. ALWAYS create exactly one meeting card in sezish/meetings/. Derive its filename
           from the meeting file's basename. It holds: the date, the participants (linked),
           and a faithful summary — key points, decisions with owners, action items with
           owners and deadlines, open questions — plus `## Related` links to every entity
           card you touched.
        4. Entities: fewer but richer. Only significant people, projects and decisions.
           Skip logistics, small talk and transient status.
        5. LINKING PROTOCOL (mandatory). Every new card's `## Related` links the hub
           [[sezish/_index]] plus 2-3 sibling cards, and the new card goes into the hub's
           link list.

        ANTI-PATTERNS (forbidden)
        - A `description` that repeats the title.
        - No tags, or more than 5 tags.
        - A card for trivia.
        - Two contradictory current values for the same fact — use SUPERSEDE instead.
        - Editing lines that already exist under `## History`.

        OUTPUT LANGUAGE
        Write all card content — titles, descriptions, prose, log lines — in \(languageName).
        Frontmatter keys and `type` values stay English.

        BOUNDARIES
        - Modify files ONLY inside the vault at \(notesFolderPath).
        - Never touch the transcript file itself.
        - Do not use the network.
        """
    }
}

/// Idempotency stamp appended to a meeting .md once its summary exists, so a re-run
/// (retry, salvage, a second launch over the same notes folder) skips work already
/// done. The APP writes it after the engine exits successfully; the prompt above never
/// mentions it, because an agent that knew the syntax could stamp a summary it never
/// wrote and every later run would skip a meeting that was never read.
public enum SummaryMarker {
    private static let prefix = "<!-- sezish-summary:"

    public static func isPresent(in mdText: String) -> Bool {
        mdText.contains(prefix)
    }

    public static func line(date: Date) -> String {
        "\(prefix) \(ISO8601DateFormatter().string(from: date)) -->"
    }

    /// Appends the marker as a new last line. Deliberately dumb: it never reads or
    /// rewrites what is already there, so stamping can only ever add bytes to the
    /// user's transcript. Guard it with `isPresent` — twice appended is twice written.
    public static func append(to url: URL, date: Date) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n\(line(date: date))".utf8))
    }
}
