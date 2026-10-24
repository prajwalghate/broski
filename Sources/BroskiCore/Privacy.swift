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
}
