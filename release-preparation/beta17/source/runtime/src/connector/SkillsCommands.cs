using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

// SmartConnector.exe skills <command> [options]: Skills Sync and the skill scripts as compiled code, so no PowerShell
// script has to run for them. Each command does what the script of the same name did (same files under
// %LOCALAPPDATA%\AutodeskMcpSkillCollection, same requests to the skill service, same log text and exit codes);
// options are the script's parameters written --like-this, and may repeat for lists.
//
//   skills sync [--action Sync|Run|Preview|Configure|Enable|Disable|Status] [--product Revit|AutoCAD|3dsMax]
//               [--repository-root <dir>] [--state-root <dir>] [--additional-skill-root <dir>]... [--reminder On|Off]
//                                         weekly-skill-collection.ps1: the Skills Sync button (default action Sync)
//   skills preview [same options]         the same with --action Preview: what would be sent, nothing uploaded
//   skills collect [--repository-root] [--output-root] [--additional-skill-root]... [--only-additional-skill-roots]
//               [--exclude-skill <name>]... [--exclusion-list-path]      collect-skills-for-review.ps1
//   skills submit [--repository-root] [--repository-url] [--base-branch] [--reviewer] [--candidate-root] [--state-root]
//               [--include-saved-skills] [--additional-skill-root]... [--dry-run]   submit-team-knowledge.ps1
//   skills usage [--action Run|Unregister] [--state-root]                send-usage.ps1
//   skills codex-sync [--action Install|Update|Publish] [--message <text>] [--destination <dir>] [--repository-root]
//                                         sync-codex-skills.ps1
//   skills retire-tasks [--stop-agent] [--state-root] [--connector-state] [--startup-folder] [--install-root]
//                                         retire-background-tasks.ps1
//   skills configure [--repository-root]  configure-connector-tasks.ps1
//   skills initialize --config-path <file>   Initialize-SkillService.ps1
//   skills central [--repository-root] [--state-root] [--additional-skill-root]... [--category <name>]... [--preview]
//                                         central-skill-sync.ps1 itself (sync runs it)
// Helpers for the tests: install-library, library, categories, products, and retire-tasks --match-task.
namespace SmartConnector
{
    internal static class SkillsCommands
    {
        // `skills ...` is handled here; anything else is left to Program.Main.
        internal static bool TryRun(string[] args, out int code)
        {
            code = 0;
            if (args.Length == 0 || args[0] != "skills") return false;
            Program.AttachConsole();
            try { code = Dispatch(args.Length > 1 ? args[1] : "", args.Skip(2).ToArray()); }
            catch (Exception exception)
            {
                // The windows show the script's message; a failure is exit code 1, as an uncaught throw was.
                SkillConsole.Err(exception.Message);
                code = 1;
            }
            return true;
        }

        private static string Repository(SkillOptions o)
        {
            return o.Get("repository-root", Paths.Root);
        }

        // The weekly runner's own default: the install folder, which is %LOCALAPPDATA%\BIM-CAD-MCP on a normal PC.
        private static string WeeklyRepository(SkillOptions o)
        {
            string standard = Path.Combine(Paths.LocalAppData, "BIM-CAD-MCP");
            string fallback = !Directory.Exists(Path.Combine(standard, ".agents", "skills")) && Directory.Exists(Path.Combine(Paths.Root, ".agents", "skills")) ? Paths.Root : standard;
            return o.Get("repository-root", fallback);
        }

        private static string State(SkillOptions o)
        {
            return o.Get("state-root", Paths.SkillState);
        }

        private static int Dispatch(string command, string[] rest)
        {
            SkillOptions o = new SkillOptions(rest);
            SkillSink sink = new SkillSink(null);
            switch (command)
            {
                case "sync":
                case "preview":
                {
                    WeeklyOptions w = new WeeklyOptions();
                    w.Action = o.Choice("action", new[] { "Configure", "Enable", "Disable", "Status", "Run", "Preview", "Sync" }, command == "preview" ? "Preview" : "Sync");
                    w.Product = o.Choice("product", new[] { "", "Revit", "AutoCAD", "3dsMax" }, "");
                    w.Reminder = o.Choice("reminder", new[] { "", "On", "Off" }, "");
                    w.RepositoryRoot = WeeklyRepository(o);
                    w.StateRoot = State(o);
                    w.AdditionalSkillRoots = o.List("additional-skill-root").Concat(o.List("additional-skill-roots")).ToArray();
                    return WeeklyRunner.Run(w, sink);
                }
                case "central":
                {
                    CentralOptions c = new CentralOptions();
                    c.RepositoryRoot = Repository(o); c.StateRoot = State(o);
                    c.AdditionalSkillRoots = o.List("additional-skill-root").Concat(o.List("additional-skill-roots")).ToArray();
                    c.Categories = o.List("category").Concat(o.List("categories")).ToArray();
                    c.Preview = o.Flag("preview");
                    return CentralSync.Run(c, sink);
                }
                case "collect":
                {
                    CollectorOptions c = new CollectorOptions();
                    c.RepositoryRoot = Repository(o);
                    c.OutputRoot = o.Get("output-root", Path.Combine(Paths.LocalAppData, "BIM-CAD-MCP", "skill-review"));
                    c.AdditionalSkillRoots = o.List("additional-skill-root").Concat(o.List("additional-skill-roots")).ToArray();
                    c.OnlyAdditionalSkillRoots = o.Flag("only-additional-skill-roots");
                    c.ExcludeSkills = o.List("exclude-skill").Concat(o.List("exclude-skills")).ToArray();
                    c.ExclusionListPath = o.Get("exclusion-list-path", Path.Combine(Paths.SkillState, "excluded-skills.txt"));
                    foreach (string line in SkillCollector.Run(c, sink).Lines) sink.Out(line);
                    return 0;
                }
                case "submit":
                {
                    SubmitOptions s = new SubmitOptions();
                    s.RepositoryRoot = Repository(o);
                    s.RepositoryUrl = o.Get("repository-url", s.RepositoryUrl);
                    s.BaseBranch = o.Get("base-branch", s.BaseBranch);
                    s.Reviewer = o.Has("reviewer") ? o.Get("reviewer", "") : s.Reviewer;
                    s.CandidateRoot = o.Get("candidate-root", Path.Combine(Paths.LocalAppData, "BIM-CAD-MCP", "team-candidates"));
                    s.StateRoot = o.Get("state-root", Path.Combine(Paths.LocalAppData, "BIM-CAD-MCP", "team-collection"));
                    s.IncludeSavedSkills = o.Flag("include-saved-skills");
                    s.AdditionalSkillRoots = o.List("additional-skill-root").Concat(o.List("additional-skill-roots")).ToArray();
                    s.DryRun = o.Flag("dry-run");
                    string json = SkillSubmitter.Run(s, sink);
                    if (json != null) sink.Out(json);
                    return 0;
                }
                case "usage":
                {
                    string action = o.Choice("action", new[] { "Run", "Unregister" }, "Run");
                    if (action == "Run") return UsageSender.Run(State(o), sink, false);
                    try { RetireTasks.UnregisterUsageTask(); sink.Out("Usage reporting task removed."); return 0; }
                    catch (Exception exception)
                    {
                        string message = "Usage report failed; unsent counts are kept for the next run.";
                        UsageSender.WriteLog(State(o), message);
                        SkillConsole.Err(message + " " + exception.Message);
                        return 1;
                    }
                }
                case "codex-sync":
                    return CodexSync.Run(o.Choice("action", new[] { "Install", "Update", "Publish" }, "Install"), o.Get("message", "Update Codex skills"), o.Get("destination", ""), Repository(o), sink);
                case "retire-tasks":
                {
                    if (o.Has("match-task"))
                    {
                        sink.Out(RetireTasks.IsRetiredTask(o.Get("match-task", ""), o.List("match-arguments")) ? "True" : "False");
                        return 0;
                    }
                    RetireTasks.Options r = new RetireTasks.Options();
                    r.StopAgent = o.Flag("stop-agent");
                    r.StateRoot = State(o);
                    r.ConnectorState = o.Get("connector-state", Path.Combine(Paths.LocalAppData, "AutodeskMcpConnector"));
                    r.StartupFolder = o.Get("startup-folder", Path.Combine(Env.AppData, "Microsoft", "Windows", "Start Menu", "Programs", "Startup"));
                    r.InstallRoot = o.Get("install-root", Paths.Root);
                    foreach (string line in RetireTasks.Run(r, sink)) sink.Out(line);
                    return 0;
                }
                case "configure":
                    ConnectorTasks.Run(Repository(o), sink);
                    return 0;
                case "initialize":
                    if (!o.Has("config-path")) throw new ArgumentException("Cannot process command because of one or more missing mandatory parameters: ConfigPath.");
                    SkillServiceEnrollment.Run(o.Get("config-path", ""), sink);
                    return 0;

                // Helpers the tests use to look at one function of the scripts at a time.
                case "install-library":
                {
                    object library = SkillFiles.ReadJson(o.Get("library-file", ""));
                    LibrarySummary s = CentralSync.InstallApprovedLibrary(library, SkillFiles.Folder(State(o)), Repository(o), o.List("client-root"), o.List("category"), sink);
                    sink.Out(PsJsonText.Compact(Json.Object("total", s.Total, "added", s.Added, "updated", s.Updated, "preserved", s.Preserved, "current", s.Current)));
                    return 0;
                }
                case "library":
                    sink.Out(PsJsonText.Compact(SkillLibrary.SkillFolders(o.Get("root", "")).Select(s => (object)Json.Object("name", s.Name, "category", s.Category, "path", s.Path)).ToArray()));
                    return 0;
                case "categories":
                    sink.Out(String.Join(",", SkillLibrary.SyncCategories(o.Get("product", ""), o.List("installed-product")).ToArray()));
                    return 0;
                case "products":
                    sink.Out(String.Join(",", SkillLibrary.InstalledProducts(o.Get("program-files", Env.ProgramFiles), o.Get("machine-root", @"HKLM:\SOFTWARE\Autodesk")).ToArray()));
                    return 0;
                default:
                    SkillConsole.Err("Usage: SmartConnector.exe skills <sync|preview|collect|submit|usage|codex-sync|retire-tasks|configure|initialize|central> [options]");
                    return 2;
            }
        }
    }
}
