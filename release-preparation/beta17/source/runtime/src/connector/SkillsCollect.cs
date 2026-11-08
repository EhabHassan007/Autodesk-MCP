using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

// scripts\collect-skills-for-review.ps1 and scripts\submit-team-knowledge.ps1 as compiled code: finding the skills
// saved on this PC and preparing them for review, and the private GitHub pull request for daily team intake.
namespace SmartConnector
{
    internal sealed class CollectorOptions
    {
        internal string RepositoryRoot, OutputRoot, ExclusionListPath;
        internal string[] AdditionalSkillRoots = new string[0], ExcludeSkills = new string[0];
        internal bool OnlyAdditionalSkillRoots;
    }

    internal sealed class CollectorResult
    {
        internal string ReviewDirectory, ReportPath, ZipPath;
        internal int Decisions, Excluded;

        internal string[] Lines
        {
            get
            {
                return new[] { "Review report: " + ReportPath, "Review package: " + ZipPath,
                    "Candidates requiring a decision: " + Decisions, "Skills kept private by the exclusion list: " + Excluded };
            }
        }
    }

    // Collects skills found on this PC (Codex, Claude Code, agent folders and extra folders) into a review folder:
    // candidates that are new or changed against the approved library, REVIEW.md, a ZIP and sources.json.
    internal static class SkillCollector
    {
        private sealed class Source { internal string Label, Path; }

        internal static CollectorResult Run(CollectorOptions options, SkillSink sink)
        {
            string repositorySkills = Path.Combine(options.RepositoryRoot, ".agents", "skills");
            if (!Directory.Exists(repositorySkills)) throw new InvalidOperationException("Repository skill library was not found: " + repositorySkills);

            // Personal skills listed here never leave this PC: one folder name per line, # starts a comment.
            HashSet<string> excluded = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            List<string> names = new List<string>(options.ExcludeSkills);
            if (options.ExclusionListPath != null && File.Exists(options.ExclusionListPath)) names.AddRange(SkillFiles.ReadLines(options.ExclusionListPath));
            foreach (string name in names)
            {
                string trimmed = (name ?? "").Trim();
                if (trimmed.Length > 0 && !trimmed.StartsWith("#", StringComparison.Ordinal)) excluded.Add(trimmed);
            }
            int excludedCount = 0;

            string codexHome = String.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("CODEX_HOME")) ? Path.Combine(Env.Home, ".codex") : Environment.GetEnvironmentVariable("CODEX_HOME");
            List<Source> sources = new List<Source>();
            if (!options.OnlyAdditionalSkillRoots)
            {
                sources.Add(new Source { Label = "Codex user skills", Path = Path.Combine(codexHome, "skills") });
                sources.Add(new Source { Label = "Agent user skills", Path = Path.Combine(Env.Home, ".agents", "skills") });
                sources.Add(new Source { Label = "Claude Code user skills", Path = Path.Combine(Env.Home, ".claude", "skills") });
            }
            int sourceNumber = 1;
            foreach (string root in options.AdditionalSkillRoots)
            {
                if (String.IsNullOrWhiteSpace(root)) continue;
                sources.Add(new Source { Label = "Additional root " + sourceNumber, Path = root });
                sourceNumber++;
            }

            string stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss-fff", CultureInfo.InvariantCulture);
            string computer = Regex.Replace(Env.Variable("COMPUTERNAME"), "[^A-Za-z0-9_-]", "_");
            string reviewDirectory = Path.Combine(options.OutputRoot, computer + "-" + stamp);
            string candidateDirectory = Path.Combine(reviewDirectory, "candidates");
            Directory.CreateDirectory(candidateDirectory);

            Dictionary<string, string> repositoryHashes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (SkillFolder skill in SkillLibrary.SkillFolders(repositorySkills)) repositoryHashes[skill.Name] = SkillHash.OfFolder(skill.Path, true);

            List<string[]> results = new List<string[]>();   // skill, status, source, files, flags, hash
            // Candidate folder -> where it came from, so Skills Sync can say where two differing copies of a skill live.
            Dictionary<string, object> candidateSources = new Dictionary<string, object>();
            HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            string repositoryFull = Path.GetFullPath(repositorySkills).TrimEnd('\\', '/');
            foreach (Source source in sources)
            {
                if (!Directory.Exists(source.Path)) continue;
                if (SkillFiles.IsLink(source.Path)) continue;
                if (String.Equals(Path.GetFullPath(source.Path).TrimEnd('\\', '/'), repositoryFull, StringComparison.OrdinalIgnoreCase)) continue;

                DirectoryInfo[] skills = new DirectoryInfo(source.Path).GetDirectories();
                Array.Sort(skills, (a, b) => String.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase));
                foreach (DirectoryInfo skill in skills)
                {
                    // Get-ChildItem -Directory without -Force does not list hidden folders.
                    if (skill.Name.StartsWith(".", StringComparison.Ordinal) || (skill.Attributes & FileAttributes.Hidden) != 0) continue;
                    if (!File.Exists(Path.Combine(skill.FullName, "SKILL.md"))) continue;
                    // Excluded skills are not copied or listed, because REVIEW.md can be attached to a submission.
                    if (excluded.Contains(skill.Name)) { excludedCount++; continue; }
                    if (SkillSafety.HasLinks(skill.FullName)) { sink.Warn("Skipped linked skill: " + skill.Name); continue; }
                    string hash = SkillHash.OfFolder(skill.FullName, true);
                    string key = skill.Name + "|" + hash;
                    if (!seen.Add(key)) continue;

                    string status = !repositoryHashes.ContainsKey(skill.Name) ? "NEW" : repositoryHashes[skill.Name] == hash ? "IDENTICAL" : "CHANGED";
                    int flags = SkillSafety.FlagCount(skill.FullName);

                    if (status != "IDENTICAL")
                    {
                        string targetName = skill.Name + "-" + hash.Substring(0, 8).ToLowerInvariant();
                        SkillFiles.CopyFolder(skill.FullName, Path.Combine(candidateDirectory, targetName));
                        candidateSources[targetName] = source.Label;
                    }
                    results.Add(new[] { skill.Name, status, source.Label, skill.GetFiles("*", SearchOption.AllDirectories).Length.ToString(CultureInfo.InvariantCulture),
                        flags.ToString(CultureInfo.InvariantCulture), hash.Substring(0, 12).ToLowerInvariant() });
                }
            }

            string reportPath = Path.Combine(reviewDirectory, "REVIEW.md");
            List<string> lines = new List<string>();
            lines.Add("# Local skill review");
            lines.Add("");
            lines.Add("Generated: " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss zzz", CultureInfo.InvariantCulture));
            lines.Add("Computer: " + computer);
            lines.Add("");
            lines.Add("Nothing in this package was added or pushed to GitHub. Review candidate contents and sensitive-content flags before approving publication.");
            lines.Add("To propose this package to the repository owner, open https://github.com/EhabHassan007/Autodesk-MCP/issues/new?template=skill-submission.yml and attach the ZIP after reviewing it.");
            lines.Add("");
            lines.Add("| Skill | Status | Source | Files | Sensitive flags | Hash |");
            lines.Add("|---|---|---|---:|---:|---|");
            foreach (string[] item in results.OrderBy(r => r[1], StringComparer.CurrentCultureIgnoreCase).ThenBy(r => r[0], StringComparer.CurrentCultureIgnoreCase))
                lines.Add("| " + item[0] + " | " + item[1] + " | " + item[2] + " | " + item[3] + " | " + item[4] + " | " + item[5] + " |");
            if (results.Count == 0) lines.Add("| _No user skills found_ | - | - | 0 | 0 | - |");
            lines.Add("");
            lines.Add("Statuses: NEW is absent from the repository; CHANGED has the same name but different contents; IDENTICAL already matches the repository and is not copied into candidates.");
            File.WriteAllText(reportPath, String.Join("\r\n", lines.ToArray()) + "\r\n", SkillFiles.Utf8Bom);

            string zipPath = Path.Combine(options.OutputRoot, "skill-review-" + computer + "-" + stamp + ".zip");
            ZipFolder(reviewDirectory, zipPath);
            // Written after the ZIP so it stays local: source labels only, no personal paths.
            File.WriteAllText(Path.Combine(reviewDirectory, "sources.json"), PsJsonText.Pretty(candidateSources), SkillFiles.Utf8Bom);

            CollectorResult result = new CollectorResult();
            result.ReviewDirectory = reviewDirectory; result.ReportPath = reportPath; result.ZipPath = zipPath;
            result.Decisions = results.Count(r => r[1] != "IDENTICAL");
            result.Excluded = excludedCount;
            return result;
        }

        // Compress-Archive -Path <folder>\* : the folder's contents, forward slashes in the entry names.
        private static void ZipFolder(string folder, string zipPath)
        {
            if (File.Exists(zipPath)) File.Delete(zipPath);
            string root = Path.GetFullPath(folder).TrimEnd('\\', '/');
            using (ZipArchive archive = OpenZip(zipPath))
            {
                foreach (string directory in Directory.GetDirectories(root, "*", SearchOption.AllDirectories))
                    if (Directory.GetFileSystemEntries(directory).Length == 0) archive.CreateEntry(SkillText.Relative(root, directory) + "/");
                foreach (string file in Directory.GetFiles(root, "*", SearchOption.AllDirectories))
                {
                    ZipArchiveEntry entry = archive.CreateEntry(SkillText.Relative(root, file), CompressionLevel.Optimal);
                    using (Stream input = File.OpenRead(file))
                    using (Stream output = entry.Open())
                        input.CopyTo(output);
                }
            }
        }

        private static ZipArchive OpenZip(string path)
        {
            return new ZipArchive(new FileStream(path, FileMode.CreateNew, FileAccess.Write), ZipArchiveMode.Create, false);
        }
    }

    internal sealed class SubmitOptions
    {
        internal string RepositoryRoot, RepositoryUrl = "https://github.com/EhabHassan007/Autodesk-MCP.git", BaseBranch = "main", Reviewer = "EhabHassan007";
        internal string CandidateRoot, StateRoot;
        internal bool IncludeSavedSkills, DryRun;
        internal string[] AdditionalSkillRoots = new string[0];
    }

    // Daily team intake: sanitized candidates go to a skill-intake/* branch of the team repository and a draft pull
    // request asks the owner for review. Nothing is merged or published to main.
    internal static class SkillSubmitter
    {
        private sealed class Selected { internal string Name, Hash, Path; }

        // The GitHub API address. The tests point it at a stand-in on this computer (loopback HTTP only).
        private static string ApiBase
        {
            get
            {
                string value = Environment.GetEnvironmentVariable("SMART_CONNECTOR_GITHUB_API");
                Uri uri;
                if (!String.IsNullOrEmpty(value) && Uri.TryCreate(value, UriKind.Absolute, out uri) && uri.Scheme == "http" && uri.IsLoopback
                    && Environment.GetEnvironmentVariable("SMART_CONNECTOR_ALLOW_LOOPBACK_HTTP") == "1")
                    return value.TrimEnd('/');
                return "https://api.github.com";
            }
        }

        private static string PrintJson(object value) { return PsJsonText.Pretty(value); }

        private static ProcessResult Git(string git, string[] arguments, bool allowFailure, IDictionary<string, string> environment)
        {
            ProcessResult result = SkillProcess.Run(git, arguments, null, environment, null);
            if (!allowFailure && result.ExitCode != 0)
                throw new InvalidOperationException(git + " failed with exit code " + result.ExitCode + ".\n" + String.Join(Environment.NewLine, result.Lines));
            return result;
        }

        private static byte[] Utf8(string text) { return SkillFiles.Utf8.GetBytes(text); }

        // Returns the JSON the script printed (null when it printed nothing). Warnings go to the sink.
        internal static string Run(SubmitOptions options, SkillSink sink)
        {
            Directory.CreateDirectory(options.CandidateRoot);
            Directory.CreateDirectory(options.StateRoot);

            string stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss-fff", CultureInfo.InvariantCulture);
            string reviewRoot = Path.Combine(options.StateRoot, "review-" + stamp);
            // The collector runs in this process, so folders keep their boundaries.
            CollectorOptions collect = new CollectorOptions();
            collect.RepositoryRoot = options.RepositoryRoot; collect.OutputRoot = reviewRoot;
            collect.AdditionalSkillRoots = new[] { options.CandidateRoot }.Concat(options.AdditionalSkillRoots).ToArray();
            collect.OnlyAdditionalSkillRoots = !options.IncludeSavedSkills;
            collect.ExclusionListPath = Path.Combine(Paths.LocalAppData, "AutodeskMcpSkillCollection", "excluded-skills.txt");
            SkillCollector.Run(collect, sink);

            DirectoryInfo reviewDirectory = new DirectoryInfo(reviewRoot).GetDirectories().OrderByDescending(d => d.LastWriteTime).FirstOrDefault();
            if (reviewDirectory == null) throw new InvalidOperationException("The collector did not create a review directory.");
            string candidateDirectory = Path.Combine(reviewDirectory.FullName, "candidates");
            DirectoryInfo[] candidateFolders = Directory.Exists(candidateDirectory) ? new DirectoryInfo(candidateDirectory).GetDirectories() : new DirectoryInfo[0];

            string ledgerPath = Path.Combine(options.StateRoot, "submitted-hashes.json");
            Dictionary<string, string> submitted = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (File.Exists(ledgerPath))
            {
                try { submitted = SkillFiles.ReadStringMap(ledgerPath); }
                catch (Exception) { throw new InvalidOperationException("Submission ledger is invalid: " + ledgerPath); }
            }

            List<Selected> selected = new List<Selected>();
            Dictionary<string, string> chosen = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (DirectoryInfo candidate in candidateFolders)
            {
                string name;
                try { name = SkillSafety.NameOf(candidate.FullName); }
                catch (Exception) { sink.Warn("Skipped invalid skill: " + candidate.Name); continue; }
                try { SkillSafety.CheckCandidate(candidate.FullName); }
                catch (Exception exception) { sink.Warn("Skipped candidate " + name + ": " + exception.Message); continue; }
                string hash = SkillHash.OfFolder(candidate.FullName, false);
                if (submitted.ContainsKey(hash)) continue;
                if (chosen.ContainsKey(name) && !String.Equals(chosen[name], hash, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Conflicting candidates were found for skill: " + name);
                if (!chosen.ContainsKey(name))
                {
                    chosen[name] = hash;
                    selected.Add(new Selected { Name = name, Hash = hash, Path = candidate.FullName });
                }
            }

            if (selected.Count == 0)
                return PrintJson(Json.Object("status", "no_new_candidates", "review", reviewDirectory.FullName));

            if (options.DryRun)
                return PrintJson(Json.Object("status", "dry_run",
                    "candidates", selected.Select(s => (object)Json.Object("name", s.Name, "hash", s.Hash.Substring(0, 12))).ToArray(),
                    "review", reviewDirectory.FullName));

            string git = SkillProcess.Find("git");
            if (git == null) throw new InvalidOperationException("git is required for automatic team submission.");
            Uri repositoryUri = new Uri(options.RepositoryUrl);
            string repositorySlug = repositoryUri.AbsolutePath.Trim('/').Replace(".git", "");
            string identityPath = Path.Combine(options.StateRoot, "installation-id.txt");
            if (!File.Exists(identityPath)) File.WriteAllText(identityPath, Guid.NewGuid().ToString("N"), SkillFiles.Utf8);
            string identity = File.ReadAllText(identityPath).Trim();
            string batchText = String.Join(":", selected.Select(s => s.Hash).OrderBy(h => h, StringComparer.CurrentCultureIgnoreCase).ToArray());
            string batchId;
            using (SHA256 sha = SHA256.Create()) batchId = BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(batchText))).Replace("-", "").Substring(0, 20).ToLowerInvariant();
            string branch = "skill-intake/" + identity + "/" + batchId;
            string checkout = Path.Combine(Path.GetTempPath(), "BimCadMcp-intake-" + Guid.NewGuid().ToString("N"));
            // Git must never stop to ask a question on a window nobody can see.
            Dictionary<string, string> environment = new Dictionary<string, string>();
            environment["GCM_INTERACTIVE"] = "Never"; environment["GIT_TERMINAL_PROMPT"] = "0";
            Dictionary<string, string> headers = null;
            try
            {
                ProcessResult credentialResult = SkillProcess.Run(git, new[] { "credential", "fill" }, "protocol=https\nhost=github.com\n\n\n", environment, null);
                Dictionary<string, string> credential = new Dictionary<string, string>();
                foreach (string line in credentialResult.StdOut.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None))
                {
                    int separator = line.IndexOf('=');
                    if (separator > 0) credential[line.Substring(0, separator)] = line.Substring(separator + 1);
                }
                string password;
                if (!credential.TryGetValue("password", out password) || String.IsNullOrWhiteSpace(password))
                    throw new InvalidOperationException("Git Credential Manager did not return GitHub credentials. Open connector Settings > Connect GitHub, then retry.");
                headers = new Dictionary<string, string>();
                headers["Authorization"] = "Bearer " + password;
                headers["Accept"] = "application/vnd.github+json";
                headers["X-GitHub-Api-Version"] = "2022-11-28";
                headers["User-Agent"] = "BIM-CAD-MCP-team-intake";
                // Use the authenticated account's GitHub identity without changing global Git settings.
                object account = SkillHttp.Request("GET", ApiBase + "/user", headers, null, null, null, 100);
                string login = PsJson.Text(PsJson.Value(account, "login")), accountId = PsJson.Text(PsJson.Value(account, "id"));
                if (!Regex.IsMatch(login, "^[A-Za-z0-9-]+$", RegexOptions.IgnoreCase) || !Regex.IsMatch(accountId, @"^\d+$"))
                    throw new InvalidOperationException("GitHub did not return a valid account identity. Use Settings > Connect GitHub and retry.");
                string authorEmail = accountId + "+" + login + "@users.noreply.github.com";
                Git(git, new[] { "clone", "--quiet", "--single-branch", "--branch", options.BaseBranch, options.RepositoryUrl, checkout }, false, environment);
                Git(git, new[] { "-C", checkout, "config", "--local", "user.name", login }, false, environment);
                Git(git, new[] { "-C", checkout, "config", "--local", "user.email", authorEmail }, false, environment);
                ProcessResult remote = Git(git, new[] { "-C", checkout, "ls-remote", "--heads", "origin", "refs/heads/" + branch }, false, environment);
                bool branchExists = remote.Lines.Length > 0;
                if (branchExists)
                {
                    Git(git, new[] { "-C", checkout, "fetch", "origin", "refs/heads/" + branch }, false, environment);
                    Git(git, new[] { "-C", checkout, "switch", "-c", branch, "FETCH_HEAD" }, false, environment);
                }
                else Git(git, new[] { "-C", checkout, "switch", "-c", branch }, false, environment);
                string skillsRoot = Path.Combine(checkout, ".agents", "skills");
                Directory.CreateDirectory(skillsRoot);
                foreach (Selected candidate in selected)
                {
                    string target = Path.Combine(skillsRoot, candidate.Name);
                    SkillSafety.AssertChildPath(skillsRoot, target);
                    if (Directory.Exists(target)) SkillFiles.DeleteFolder(target);
                    SkillFiles.CopyFolder(candidate.Path, target);
                }

                List<string> add = new List<string> { "-C", checkout, "add", "--" };
                add.AddRange(selected.Select(s => ".agents/skills/" + s.Name));
                Git(git, add.ToArray(), false, environment);
                ProcessResult diff = Git(git, new[] { "-C", checkout, "diff", "--cached", "--quiet" }, true, environment);
                if (diff.ExitCode == 0 && !branchExists)
                    return PrintJson(Json.Object("status", "already_approved", "skills", selected.Select(s => (object)s.Name).ToArray()));

                string title = "Team skill review: " + String.Join(", ", selected.Select(s => s.Name).OrderBy(n => n, StringComparer.CurrentCultureIgnoreCase).ToArray());
                if (diff.ExitCode == 1) Git(git, new[] { "-C", checkout, "commit", "--quiet", "-m", title }, false, environment);
                else if (diff.ExitCode != 0) throw new InvalidOperationException("Could not inspect staged changes.");
                Git(git, new[] { "-C", checkout, "push", "--quiet", "--set-upstream", "origin", branch }, false, environment);

                List<string> body = new List<string>();
                body.Add("Automated team knowledge candidate for owner review.");
                body.Add("");
                body.Add("Automated local checks found no flagged content in these candidates. These checks are not exhaustive; review contents before approval.");
                body.Add("The candidate is untrusted until the repository owner reviews and approves it.");
                body.Add("");
                body.Add("Skills:");
                foreach (Selected candidate in selected.OrderBy(s => s.Name, StringComparer.CurrentCultureIgnoreCase))
                    body.Add("- `" + candidate.Name + "` - `" + candidate.Hash.Substring(0, 12).ToLowerInvariant() + "`");
                string bodyText = String.Join("\r\n", body.ToArray()) + "\r\n";

                string prUrl;
                string owner = repositorySlug.Split('/')[0], repository = repositorySlug.Split('/')[1];
                string existingUri = ApiBase + "/repos/" + owner + "/" + repository + "/pulls?state=all&head=" + owner + ":" + branch;
                object existing = SkillHttp.Request("GET", existingUri, headers, null, null, null, 100);
                string existingUrl = ExistingPullRequest(existing);
                if (existingUrl != null) prUrl = existingUrl;
                else
                {
                    string payload = PsJsonText.Pretty(Json.Object("title", title, "head", branch, "base", options.BaseBranch, "body", bodyText, "draft", true));
                    object created = SkillHttp.Request("POST", ApiBase + "/repos/" + owner + "/" + repository + "/pulls", headers, null, "application/json", Utf8(payload), 100);
                    prUrl = PsJson.Text(PsJson.Value(created, "html_url"));
                    if (!String.IsNullOrWhiteSpace(options.Reviewer))
                    {
                        try
                        {
                            string reviewPayload = PsJsonText.Pretty(Json.Object("reviewers", new object[] { options.Reviewer }));
                            SkillHttp.Request("POST", ApiBase + "/repos/" + owner + "/" + repository + "/pulls/" + PsJson.Text(PsJson.Value(created, "number")) + "/requested_reviewers",
                                headers, null, "application/json", Utf8(reviewPayload), 100);
                        }
                        catch (Exception) { }
                    }
                }

                foreach (Selected candidate in selected) submitted[candidate.Hash] = prUrl;
                string temporaryLedger = ledgerPath + ".tmp";
                Dictionary<string, object> ledger = new Dictionary<string, object>();
                foreach (KeyValuePair<string, string> pair in submitted) ledger[pair.Key] = pair.Value;
                File.WriteAllText(temporaryLedger, PsJsonText.Pretty(ledger), SkillFiles.Utf8Bom);
                SkillFiles.MoveOver(temporaryLedger, ledgerPath);

                return PrintJson(Json.Object("status", "submitted_for_approval", "pull_request", prUrl, "reviewer", options.Reviewer,
                    "skills", selected.Select(s => (object)s.Name).ToArray()));
            }
            finally
            {
                if (headers != null) headers["Authorization"] = null;
                if (Directory.Exists(checkout))
                {
                    // Only ever delete inside the temp folder.
                    string resolvedTemp = Path.GetFullPath(Path.GetTempPath()).TrimEnd('\\', '/') + Path.DirectorySeparatorChar;
                    if (Path.GetFullPath(checkout).StartsWith(resolvedTemp, StringComparison.OrdinalIgnoreCase))
                    {
                        try { SkillFiles.DeleteFolder(checkout); } catch (Exception) { }
                    }
                }
            }
        }

        // The first pull request in the answer that has an html_url.
        private static string ExistingPullRequest(object answer)
        {
            System.Collections.IEnumerable list = answer as System.Collections.IEnumerable;
            if (list == null || answer is string || answer is IDictionary<string, object>) list = answer == null ? new object[0] : new[] { answer };
            foreach (object item in list)
            {
                string url = PsJson.Text(PsJson.Value(item, "html_url"));
                if (url.Length > 0) return url;
            }
            return null;
        }
    }
}
