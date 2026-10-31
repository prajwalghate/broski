import Foundation

/// Local-only projects never go to Claude. One check for the Mac and the iPhone, so they can't drift apart.
public enum LocalOnly {
    /// True when a capture touches a local-only project: one of `projects` (what the rules picked, the project
    /// picked by hand, the running session's project) is local only, or the text names one anywhere in it,
    /// not just the first project the rules found.
    public static func touches(_ text: String, projects: [String?], localOnly: Set<String>, catalog: ProjectCatalog) -> Bool {
        guard !localOnly.isEmpty else { return false }
        if projects.contains(where: { $0.map(localOnly.contains) == true }) { return true }
        return catalog.projects.contains { project in
            localOnly.contains(project.name) && ProjectCatalog(projects: [project]).mentioned(in: text) != nil
        }
    }

    /// The turns a reply may carry: talking about a local-only project, all of them (the reply then stays on this
    /// device); otherwise none tagged with a local-only project, so what was said about one (an interview's answers
    /// rarely name it) can't reach a cloud model after you switch.
    public static func sendable(_ turns: [Turn], project: String?, localOnly: Set<String>) -> [Turn] {
        guard !localOnly.isEmpty, !(project.map(localOnly.contains) ?? false) else { return turns }
        return turns.filter { !($0.project.map(localOnly.contains) ?? false) }
    }
}
