using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32;

// The AI apps: registering the connector with Codex and Claude Code (through their own command lines), with Claude Desktop
// (its JSON config, at the roaming path and in the Microsoft Store package's copy), and restarting Claude Desktop so it
// loads the registration. The C# port of Register-McpServer, Register-ClaudeCodeMcpServer,
// Register-ClaudeDesktopMcpServer and Register-DetectedAiClients in Setup-BimCad.ps1.
namespace SmartConnector
{
    internal sealed class McpLaunch
    {
        internal string Command;
        internal string[] Arguments;
    }

    internal sealed class ClaudeDesktopInstallation
    {
        internal string Executable = "", Source = "";
    }

    internal sealed partial class InstallEngine
    {
        // Only entries that launch this connector's own bridges count as duplicates; another tool's server with a similar
        // name is left alone.
        internal static bool IsOwnConnectorEntry(string text)
        {
            return Regex.IsMatch(text ?? "", "BIM-CAD-MCP|SmartConnector\\.exe|autodesk-bridge\\.ps1|autocad-bridge\\.ps1|revit-bridge\\.ps1", RegexOptions.IgnoreCase);
        }

        // How an AI app starts the connector: the compiled SmartConnector.exe when it is installed (bin\SmartConnector.exe),
        // otherwise the PowerShell bridge.
        internal static McpLaunch GetMcpLaunch(string bridge, string[] bridgeArguments)
        {
            if (bridge.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) return new McpLaunch { Command = bridge, Arguments = bridgeArguments };
            List<string> arguments = new List<string> { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", bridge };
            arguments.AddRange(bridgeArguments);
            return new McpLaunch { Command = "powershell.exe", Arguments = arguments.ToArray() };
        }

        private void RemoveLegacyMcpEntries(string client, string command, string[] legacyNames, string[] removeArguments)
        {
            foreach (string legacy in legacyNames)
            {
                External existing = Invoke(command, new[] { "mcp", "get", legacy }, true, true, null);
                if (existing.ExitCode != 0 || !IsOwnConnectorEntry(String.Join("\n", existing.Output))) continue;
                List<string> arguments = new List<string> { "mcp", "remove", legacy };
                arguments.AddRange(removeArguments);
                External removed = Invoke(command, arguments.ToArray(), true, false, null);
                if (removed.ExitCode == 0) Step("Removed the older duplicate " + client + " MCP entry '" + legacy + "'.");
            }
        }

        // The name Codex and Claude Code know the connector by (their server names cannot contain spaces). Claude Desktop shows "Smart Connector".
        internal const string CliServerName = "smart-connector";

        // An entry under ANY name that still starts a PowerShell bridge. The retired names above are only the names earlier
        // versions used; an entry someone added under another name kept serving the old bridge, which has no apply_plan,
        // execute_autocad or generate_detail. The compiled connector is never matched (its path has no "-bridge.ps1").
        internal static readonly Regex StaleBridge = new Regex(@"(autodesk|autocad|revit)-bridge\.ps1", RegexOptions.IgnoreCase);

        // The server name a `mcp list` line starts with ("name: command ..." in Claude Code, a table in Codex).
        internal static string ListedServerName(string line)
        {
            Match colon = Regex.Match(line ?? "", @"^\s*([^:]+?):\s");
            if (colon.Success) return colon.Groups[1].Value.Trim();
            Match token = Regex.Match(line ?? "", @"^\s*(\S+)");
            return token.Success ? token.Groups[1].Value : "";
        }

        private void RemoveStaleBridgeCliEntries(string client, string command, string keep, string[] removeArguments)
        {
            try
            {
                External list = Invoke(command, new[] { "mcp", "list" }, true, true, null);
                if (list.ExitCode != 0) return;
                foreach (string line in list.Output)
                {
                    if (!StaleBridge.IsMatch(line)) continue;
                    string stale = ListedServerName(line);
                    if (stale.Length == 0 || String.Equals(stale, keep, StringComparison.OrdinalIgnoreCase)) continue;
                    List<string> arguments = new List<string> { "mcp", "remove", stale };
                    arguments.AddRange(removeArguments);
                    if (Invoke(command, arguments.ToArray(), true, false, null).ExitCode == 0)
                        Step("Removed the " + client + " entry '" + stale + "': it still started the old PowerShell bridge, which lacks apply_plan, execute_autocad and generate_detail.");
                }
            }
            catch (Exception exception) { Warning(client + " was not checked for old PowerShell bridge entries: " + exception.Message); }
        }

        // Asks the connector the AI apps now start what it offers, the way an app would (initialize, then tools/list), and
        // says so if the tools that mark the compiled connector are missing.
        private void VerifyConnectorTools(string exe)
        {
            string[] required = { "apply_plan", "execute_autocad", "generate_detail", "connection_status" };
            try
            {
                ProcessStartInfo info = new ProcessStartInfo(exe, "mcp");
                info.UseShellExecute = false; info.CreateNoWindow = true;
                info.RedirectStandardInput = true; info.RedirectStandardOutput = true; info.RedirectStandardError = true;
                info.StandardOutputEncoding = new UTF8Encoding(false);
                info.WorkingDirectory = Paths.LocalAppData;
                List<string> names = new List<string>();
                using (Process process = Process.Start(info))
                {
                    process.ErrorDataReceived += delegate { };
                    process.BeginErrorReadLine();
                    process.StandardInput.WriteLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\"}}");
                    process.StandardInput.WriteLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
                    process.StandardInput.Flush();
                    string answer = null;
                    Thread reader = new Thread(delegate ()
                    {
                        try
                        {
                            string line;
                            while ((line = process.StandardOutput.ReadLine()) != null)
                                if (line.IndexOf("\"id\":2", StringComparison.Ordinal) >= 0) { answer = line; return; }
                        }
                        catch (Exception) { }
                    });
                    reader.IsBackground = true;
                    reader.Start();
                    bool done = reader.Join(20000);
                    try { process.StandardInput.Close(); } catch (Exception) { }
                    if (!process.WaitForExit(3000)) { try { process.Kill(); } catch (Exception) { } }
                    if (!done || answer == null) throw new EngineException("it did not answer tools/list within 20 seconds");
                    OMap response = OJson.Parse(answer) as OMap;
                    OMap result = response == null ? null : response.Get("result") as OMap;
                    List<object> tools = result == null ? null : result.Get("tools") as List<object>;
                    if (tools == null) throw new EngineException("its tools/list answer had no tools");
                    foreach (object tool in tools) { OMap map = tool as OMap; if (map != null) names.Add(Convert.ToString(map.Get("name"))); }
                }
                string[] missing = required.Where(r => !names.Contains(r)).ToArray();
                if (missing.Length > 0) Warning("The connector the AI apps start does not offer: " + String.Join(", ", missing) + ". Run Repair again; if it persists, reinstall from the latest setup exe.");
                else Step("Checked the connector the AI apps start: it offers " + names.Count + " tools, including apply_plan, execute_autocad and generate_detail.");
            }
            catch (Exception exception) { Warning("The connector the AI apps start could not be checked: " + exception.Message); }
        }

        // The Codex config folder: CODEX_HOME, else .codex in the home folder.
        private static string CodexHome
        {
            get
            {
                string variable = Env.Variable("CODEX_HOME");
                return String.IsNullOrWhiteSpace(variable) ? Path.Combine(Env.Home, ".codex") : variable;
            }
        }

        // Writes [mcp_servers.<name>] into Codex's config.toml without the codex command-line tool (ChatGPT Desktop and the
        // Codex app read the same file). Every other line of the file is kept; only this connector's own tables are
        // replaced: the named one, and legacy-named ones whose command starts this connector. Backed up while writing.
        private void RegisterCodexConfigFile(string name, string bridge, string[] bridgeArguments, string[] legacyNames)
        {
            McpLaunch launch = GetMcpLaunch(bridge, bridgeArguments);
            string configPath = Path.Combine(CodexHome, "config.toml");
            Step("Registering the " + name + " MCP server in Codex settings for ChatGPT Desktop at " + configPath + "...");
            Directory.CreateDirectory(CodexHome);
            string before = File.Exists(configPath) ? File.ReadAllText(configPath) : "";
            string newline = before.Contains("\r\n") || before.Length == 0 ? "\r\n" : "\n";
            List<string> kept = new List<string>();
            List<string> table = null; string tableName = null;
            Action flush = delegate
            {
                if (table == null) return;
                bool ours = String.Equals(tableName, name, StringComparison.OrdinalIgnoreCase) ||
                    (legacyNames.Any(l => String.Equals(tableName, l, StringComparison.OrdinalIgnoreCase)) && IsOwnConnectorEntry(String.Join("\n", table)));
                if (!ours) kept.AddRange(table);
                table = null; tableName = null;
            };
            foreach (string line in before.Replace("\r\n", "\n").Split('\n'))
            {
                Match header = Regex.Match(line, @"^\s*\[(?!\[)\s*mcp_servers\.(""[^""]*""|'[^']*'|[A-Za-z0-9_-]+)(\.[^\]]*)?\s*\]\s*(#.*)?$");
                if (header.Success)
                {
                    string key = header.Groups[1].Value.Trim('"', '\'');
                    // A subtable ([mcp_servers.x.env]) belongs to the same server.
                    if (table != null && String.Equals(key, tableName, StringComparison.OrdinalIgnoreCase)) { table.Add(line); continue; }
                    flush();
                    table = new List<string> { line }; tableName = key;
                    continue;
                }
                if (Regex.IsMatch(line, @"^\s*\[")) flush();
                if (table != null) table.Add(line); else kept.Add(line);
            }
            flush();
            while (kept.Count > 0 && kept[kept.Count - 1].Trim().Length == 0) kept.RemoveAt(kept.Count - 1);
            Func<string, string> quote = delegate(string value) { return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\""; };
            List<string> entry = new List<string>
            {
                "[mcp_servers." + name + "]",
                "command = " + quote(launch.Command),
                "args = [" + String.Join(", ", launch.Arguments.Select(quote).ToArray()) + "]"
            };
            if (kept.Count > 0) kept.Add("");
            kept.AddRange(entry);
            string after = String.Join(newline, kept.ToArray()) + newline;
            if (after == before) { Step("The Smart Connector registration for ChatGPT Desktop is already correct."); return; }
            string backupPath = configPath + ".bim-cad-setup-" + Process.GetCurrentProcess().Id + ".bak";
            bool hadConfig = File.Exists(configPath);
            if (hadConfig) File.Copy(configPath, backupPath, true);
            try
            {
                string temporaryPath = configPath + ".tmp-" + Process.GetCurrentProcess().Id;
                File.WriteAllText(temporaryPath, after, new UTF8Encoding(false));
                if (hadConfig) File.Replace(temporaryPath, configPath, null); else File.Move(temporaryPath, configPath);
                Step("Smart Connector is registered for ChatGPT Desktop. Restart ChatGPT Desktop to load it.");
            }
            catch (Exception)
            {
                if (hadConfig && File.Exists(backupPath)) File.Copy(backupPath, configPath, true);
                throw;
            }
            finally { if (File.Exists(backupPath)) File.Delete(backupPath); }
        }

        private void RegisterMcpServer(string name, string bridge, string[] bridgeArguments, string[] legacyNames)
        {
            string codex = RequireCommand("codex");
            if (!File.Exists(bridge)) throw new EngineException("MCP bridge is missing: " + bridge);

            string configPath = Path.Combine(CodexHome, "config.toml");
            string backupPath = Path.Combine(CodexHome, "config.toml.bim-cad-setup-" + Process.GetCurrentProcess().Id + ".bak");
            bool hasBackup = false;
            if (File.Exists(configPath))
            {
                File.Copy(configPath, backupPath, true);
                hasBackup = true;
            }

            Step("Registering the " + name + " MCP server in Codex...");
            try
            {
                // Read-only verification avoids rewriting an already correct registration.
                External existing = InvokeAllowFailure(codex, "mcp", "get", name, "--json");
                if (existing.ExitCode == 0)
                {
                    try
                    {
                        object entry = Json.Serializer.DeserializeObject(String.Join("\n", existing.Output));
                        McpLaunch expected = GetMcpLaunch(bridge, bridgeArguments);
                        object transport = PsJson.Value(entry, "transport");
                        object args = PsJson.Value(transport, "args");
                        List<string> actualArgs = new List<string>();
                        System.Collections.IEnumerable items = args as System.Collections.IEnumerable;
                        if (items != null && !(args is string)) foreach (object item in items) actualArgs.Add(PsJson.Text(item));
                        else if (args != null) actualArgs.Add(PsJson.Text(args));
                        if (PsJson.NotFalse(PsJson.Value(entry, "enabled")) &&
                            String.Equals(PsJson.Text(PsJson.Value(transport, "command")), expected.Command, StringComparison.OrdinalIgnoreCase) &&
                            actualArgs.SequenceEqual(expected.Arguments, StringComparer.Ordinal))
                        {
                            Step("The Smart Connector registration in Codex is already correct.");
                            RemoveLegacyMcpEntries("Codex", codex, legacyNames, new string[0]);
                            return;
                        }
                    }
                    catch (Exception) { Step("Existing Codex registration could not be compared; registering the requested command."); }
                }
                RemoveLegacyMcpEntries("Codex", codex, legacyNames, new string[0]);
                // mcp add replaces this named entry and leaves unrelated servers alone.
                McpLaunch launch = GetMcpLaunch(bridge, bridgeArguments);
                List<string> command = new List<string> { "mcp", "add", name, "--", launch.Command };
                command.AddRange(launch.Arguments);
                Invoke(codex, command.ToArray(), false, false, null);
                Invoke(codex, "mcp", "get", name);
            }
            catch (Exception)
            {
                if (hasBackup) File.Copy(backupPath, configPath, true);
                throw;
            }
            finally
            {
                if (hasBackup && File.Exists(backupPath)) File.Delete(backupPath);
            }
        }

        // ---------- Claude Desktop: where it is, whether it runs ----------

        private static string[] ClaudePackageFolders()
        {
            string packagesRoot = Path.Combine(Paths.LocalAppData, "Packages");
            if (!Directory.Exists(packagesRoot)) return new string[0];
            try { return Directory.GetDirectories(packagesRoot, "*Claude*"); }
            catch (Exception) { return new string[0]; }
        }

        private static ClaudeDesktopInstallation GetClaudeDesktopInstallation()
        {
            string[] candidatePaths =
            {
                Path.Combine(Paths.LocalAppData, "AnthropicClaude", "Claude.exe"),
                Path.Combine(Paths.LocalAppData, "Programs", "Claude", "Claude.exe"),
                Path.Combine(Paths.LocalAppData, "Claude", "Claude.exe"),
                Path.Combine(Paths.LocalAppData, "Microsoft", "WindowsApps", "Claude.exe"),
                Path.Combine(Env.ProgramFiles, "Claude", "Claude.exe")
            };
            foreach (string candidate in candidatePaths)
                if (File.Exists(candidate)) return new ClaudeDesktopInstallation { Executable = candidate, Source = "file" };

            // Package enumeration may be blocked in restricted Windows sessions. The package data directory is sufficient
            // evidence that Claude Desktop is installed, while its MCP config still belongs in roaming AppData.
            if (ClaudePackageFolders().Length > 0) return new ClaudeDesktopInstallation { Source = "appx-directory" };

            try
            {
                RegistryKey[] roots =
                {
                    Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall"),
                    ConnectorStatus.OpenMachineKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall"),
                    ConnectorStatus.OpenMachineKey(@"Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall")
                };
                foreach (RegistryKey root in roots)
                {
                    if (root == null) continue;
                    using (root)
                    {
                        foreach (string subKey in root.GetSubKeyNames())
                        {
                            using (RegistryKey item = root.OpenSubKey(subKey))
                            {
                                if (item == null) continue;
                                string displayName = Convert.ToString(item.GetValue("DisplayName"));
                                if (!Regex.IsMatch(displayName, "^Claude(?: Desktop)?$", RegexOptions.IgnoreCase)) continue;
                                string executable = "";
                                string displayIcon = Regex.Replace(Convert.ToString(item.GetValue("DisplayIcon")).Trim().Trim('"'), @",\d+$", "");
                                string installLocation = Convert.ToString(item.GetValue("InstallLocation"));
                                if (displayIcon.Length > 0 && File.Exists(displayIcon)) executable = displayIcon;
                                else if (installLocation.Length > 0 && File.Exists(Path.Combine(installLocation, "Claude.exe"))) executable = Path.Combine(installLocation, "Claude.exe");
                                return new ClaudeDesktopInstallation { Executable = executable, Source = "uninstall-registry" };
                            }
                        }
                    }
                }
            }
            catch (Exception) { }
            return null;
        }

        private static string ClaudeDesktopConfigPath { get { return Path.Combine(Env.AppData, "Claude", "claude_desktop_config.json"); } }

        private static string[] ClaudeDesktopConfigPaths()
        {
            List<string> paths = new List<string> { ClaudeDesktopConfigPath };
            foreach (string package in ClaudePackageFolders()) paths.Add(Path.Combine(package, "LocalCache", "Roaming", "Claude", "claude_desktop_config.json"));
            return paths.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        }

        private static Process[] GetClaudeDesktopProcesses()
        {
            List<Process> found = new List<Process>();
            Process[] all;
            try { all = Process.GetProcessesByName("Claude"); }
            catch (Exception) { return new Process[0]; }
            foreach (Process process in all)
            {
                string path = "", title = "";
                try { path = process.MainModule.FileName; } catch (Exception) { }
                try { title = process.MainWindowTitle; } catch (Exception) { }
                if (Regex.IsMatch(title, "Claude", RegexOptions.IgnoreCase) ||
                    Regex.IsMatch(path, @"\\(?:AnthropicClaude|Programs\\Claude|WindowsApps\\[^\\]*Claude|Claude)\\", RegexOptions.IgnoreCase)) found.Add(process);
                else process.Dispose();
            }
            return found.ToArray();
        }

        private void RestartClaudeDesktopIfRunning(Process[] processes, ClaudeDesktopInstallation installation)
        {
            List<Process> running = new List<Process>();
            foreach (Process process in processes) { try { if (!process.HasExited) running.Add(process); } catch (Exception) { } }
            if (running.Count == 0) return;

            string launchPath = null;
            foreach (Process process in running)
            {
                try { string path = process.MainModule.FileName; if (!String.IsNullOrEmpty(path) && File.Exists(path)) { launchPath = path; break; } } catch (Exception) { }
            }
            if (launchPath == null && installation != null && installation.Executable.Length > 0 && File.Exists(installation.Executable)) launchPath = installation.Executable;

            Step("Restarting Claude Desktop so it loads the Smart Connector registration...");
            foreach (Process process in running) { try { process.CloseMainWindow(); } catch (Exception) { } }
            Thread.Sleep(2000);
            foreach (Process process in running)
            {
                try { if (!process.HasExited) process.Kill(); }
                catch (Exception) { Step("Claude Desktop process " + process.Id + " could not be stopped automatically."); }
            }
            try
            {
                if (launchPath != null)
                {
                    // Through the Windows shell, so Claude inherits none of this program's handles: started directly, it
                    // kept the setup window's output pipe open and setup waited until Claude was closed.
                    ProcessStartInfo info = new ProcessStartInfo(launchPath);
                    info.UseShellExecute = true;
                    info.WorkingDirectory = Paths.LocalAppData;
                    Process.Start(info).Dispose();
                    Step("Claude Desktop restarted successfully.");
                    return;
                }
                // The script also tried the Start menu's list of apps (Get-StartApps), which has no counterpart without PowerShell.
                Step("Claude Desktop was closed to reload the connector. Open it again from the Start menu.");
            }
            catch (Exception exception)
            {
                Step("Claude Desktop was closed to reload the connector, but automatic relaunch failed: " + exception.Message);
            }
        }

        private ClaudeDesktopInstallation InstallClaudeDesktop()
        {
            ClaudeDesktopInstallation installed = GetClaudeDesktopInstallation();
            if (installed != null) return installed;

            string winget = FindCommand("winget");
            if (winget == null)
                throw new EngineException("Claude Desktop is required for a local Revit connection, but Windows Package Manager was not found. Install Claude Desktop from https://claude.com/download, then run Install / Repair again.");

            Step("Claude Desktop is not installed. Installing the official Anthropic package for the current Windows user...");
            External result = Invoke(winget, new[] { "install", "--id", "Anthropic.Claude", "--exact", "--source", "winget", "--silent", "--accept-package-agreements", "--accept-source-agreements" }, true, false, null);
            if (result.ExitCode != 0) throw new EngineException("Claude Desktop installation failed.\r\n" + String.Join("\r\n", result.Output));

            for (int attempt = 0; attempt < 20; attempt++)
            {
                installed = GetClaudeDesktopInstallation();
                if (installed != null)
                {
                    Step("Claude Desktop is installed. The Smart Connector registration will now be added.");
                    return installed;
                }
                Thread.Sleep(1000);
            }
            Step("Windows completed the Claude Desktop installation, but its executable is not enumerable yet. Continuing with the standard per-user MCP registration.");
            return new ClaudeDesktopInstallation { Source = "winget" };
        }

        // ---------- Claude Code ----------

        private void RegisterClaudeCodeMcpServer(string name, string bridge, string[] bridgeArguments, string[] legacyNames)
        {
            string claude = FindCommand("claude");
            if (claude == null)
            {
                Step("Claude Code was not detected, so its MCP registration was skipped.");
                return;
            }
            if (!File.Exists(bridge)) throw new EngineException("MCP bridge is missing: " + bridge);

            string configPath = Path.Combine(Env.Home, ".claude.json");
            string backupPath = configPath + ".autodesk-mcp-" + Process.GetCurrentProcess().Id + ".bak";
            bool hadConfig = File.Exists(configPath);
            if (hadConfig) File.Copy(configPath, backupPath, true);

            Step("Registering the " + name + " MCP server in Claude Code...");
            try
            {
                RemoveLegacyMcpEntries("Claude Code", claude, legacyNames, new[] { "--scope", "user" });
                External existing = InvokeAllowFailure(claude, "mcp", "get", name);
                if (existing.ExitCode == 0) InvokeAllowFailure(claude, "mcp", "remove", name, "--scope", "user");

                McpLaunch launch = GetMcpLaunch(bridge, bridgeArguments);
                List<string> command = new List<string> { "mcp", "add", "--transport", "stdio", "--scope", "user", name, "--", launch.Command };
                command.AddRange(launch.Arguments);
                Invoke(claude, command.ToArray(), false, false, null);
                Invoke(claude, "mcp", "get", name);
            }
            catch (Exception)
            {
                if (hadConfig) File.Copy(backupPath, configPath, true);
                else if (File.Exists(configPath)) File.Delete(configPath);
                throw;
            }
            finally
            {
                if (File.Exists(backupPath)) File.Delete(backupPath);
            }
        }

        // ---------- Claude Desktop: the JSON config ----------

        // Adds (or replaces) the connector's entry in one config file, removes the retired names, and leaves every other
        // server and setting exactly as it was. The new file is written beside the old one, checked, then put in place, so
        // a config that cannot be read is left untouched. UTF-8 without a byte-order mark.
        private void RegisterClaudeDesktopMcpServer(string name, string bridge, string[] bridgeArguments, string[] legacyNames, string configPath)
        {
            if (!File.Exists(bridge)) throw new EngineException("MCP bridge is missing: " + bridge);

            string claudeDirectory = Path.GetDirectoryName(configPath);
            int id = Process.GetCurrentProcess().Id;
            string backupPath = configPath + ".autodesk-mcp-" + id + ".bak";
            string temporaryPath = configPath + ".autodesk-mcp-" + id + ".tmp";
            Directory.CreateDirectory(claudeDirectory);
            bool hadConfig = File.Exists(configPath);
            if (hadConfig) File.Copy(configPath, backupPath, true);

            Step("Registering the " + name + " local MCP server in Claude Desktop at " + configPath + "...");
            try
            {
                OMap config;
                if (hadConfig)
                {
                    string text = File.ReadAllText(configPath);
                    // A config with nothing in it is the same as a new one.
                    if (text.Trim('﻿', ' ', '\t', '\r', '\n').Length == 0) config = new OMap();
                    else
                    {
                        config = OJson.Parse(text) as OMap;
                        if (config == null) throw new EngineException("The Claude Desktop config is not a JSON object.");
                    }
                }
                else config = new OMap();

                if (!config.Has("mcpServers") || config.Get("mcpServers") == null) config.Set("mcpServers", new OMap());
                OMap servers = config.Get("mcpServers") as OMap;
                if (servers == null) throw new EngineException("The Claude Desktop config has an mcpServers value that is not an object.");

                // An old name is removed only when its entry starts this connector. Another tool that happens to use the same name
                // (a Python AutoCAD server called "AutoCAD MCP", a pyRevit server called "Revit Connector") is not ours to delete.
                foreach (string legacyName in legacyNames)
                {
                    if (!servers.Has(legacyName)) continue;
                    if (IsOwnConnectorEntry(OJson.Write(servers.Get(legacyName)))) { servers.Remove(legacyName); Step("Removed legacy Claude Desktop MCP registration: " + legacyName + "."); }
                    else Step("Kept the Claude Desktop entry '" + legacyName + "': it does not start this connector.");
                }

                if (!bridge.EndsWith(".ps1", StringComparison.OrdinalIgnoreCase))
                {
                    List<string> stale = new List<string>();
                    for (int i = 0; i < servers.Count; i++)
                        if (!String.Equals(servers.KeyAt(i), name, StringComparison.Ordinal) && StaleBridge.IsMatch(OJson.Write(servers.ValueAt(i)))) stale.Add(servers.KeyAt(i));
                    foreach (string staleName in stale)
                        if (servers.Remove(staleName)) Step("Removed the Claude Desktop entry '" + staleName + "': it still started the old PowerShell bridge, which lacks apply_plan, execute_autocad and generate_detail.");
                }

                McpLaunch launch = GetMcpLaunch(bridge, bridgeArguments);
                OMap entry = new OMap();
                entry.Set("command", launch.Command);
                entry.Set("args", new List<object>(launch.Arguments.Cast<object>()));
                servers.Set(name, entry);

                File.WriteAllText(temporaryPath, OJson.Write(config), EngineText.Utf8);
                OJson.ReadFile(temporaryPath);   // what was written must read back
                if (hadConfig)
                {
                    File.Copy(temporaryPath, configPath, true);
                    File.Delete(temporaryPath);
                }
                else File.Move(temporaryPath, configPath);
            }
            catch (Exception exception)
            {
                if (hadConfig && File.Exists(backupPath)) File.Copy(backupPath, configPath, true);
                else if (!hadConfig && File.Exists(configPath)) File.Delete(configPath);
                throw new EngineException("Claude Desktop registration failed. " + exception.Message);
            }
            finally
            {
                if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
                if (File.Exists(backupPath)) File.Delete(backupPath);
            }
        }

        // ---------- all the AI apps ----------

        private void RegisterDetectedAiClients(string root, string[] clients)
        {
            string bridge = Path.Combine(root, "src", "autodesk", "autodesk-bridge.ps1");
            string[] arguments = { "-RevitVersion", "2024" };
            // The compiled connector replaces the PowerShell bridge wherever it is installed.
            string compiled = Path.Combine(root, "bin", "SmartConnector.exe");
            if (File.Exists(compiled)) { bridge = compiled; arguments = new[] { "mcp" }; }
            // The Codex and Claude Code entry was called "autodesk" until the connector took its own name; an entry under the old name that starts this connector is replaced.
            string[] legacyNames = { "autocad", "revit", "AutoCAD MCP", "Revit Connector", "revit-mcp", "autodesk" };
            // Claude Desktop shows the key as the connector's name; the previous product name is retired.
            string[] claudeDesktopLegacyNames = legacyNames.Concat(new[] { "autodesk", "Autodesk MCP Connector", "Smart Autodesk Connector" }).ToArray();
            int detected = 0;
            List<string> registrationErrors = new List<string>();

            Process[] claudeDesktopProcesses = GetClaudeDesktopProcesses();
            ClaudeDesktopInstallation claudeDesktopInstallation = GetClaudeDesktopInstallation();

            Phase("codex");
            if (!clients.Contains("Codex")) { Step("Codex was not selected in setup."); Result("codex", "skipped", "not selected"); }
            else if (FindCommand("codex") != null)
            {
                try
                {
                    RegisterMcpServer(CliServerName, bridge, arguments, legacyNames);
                    if (!bridge.EndsWith(".ps1", StringComparison.OrdinalIgnoreCase)) RemoveStaleBridgeCliEntries("Codex", FindCommand("codex"), CliServerName, new string[0]);
                    detected++;
                    Result("codex", "ok");
                }
                catch (Exception exception)
                {
                    registrationErrors.Add("Codex: " + exception.Message);
                    Warning("Codex registration failed; continuing with other clients: " + exception.Message);
                    Result("codex", "failed", "see the setup log");
                }
            }
            else if (ConnectorStatus.ChatGptDesktopInstalled())
            {
                // ChatGPT Desktop (or the Codex app) without the command-line tool: its Codex side reads the same
                // config.toml, so the connector is written there directly.
                try
                {
                    RegisterCodexConfigFile(CliServerName, bridge, arguments, legacyNames);
                    detected++;
                    Result("codex", "ok", "restart ChatGPT Desktop to load it");
                }
                catch (Exception exception)
                {
                    registrationErrors.Add("ChatGPT Desktop: " + exception.Message);
                    Warning("ChatGPT Desktop registration failed; continuing with other clients: " + exception.Message);
                    Result("codex", "failed", "see the setup log");
                }
            }
            else { Step("Codex was not detected, so its MCP registration was skipped."); Result("codex", "skipped", "Codex is not installed"); }

            Phase("claude_code");
            if (!clients.Contains("ClaudeCode")) { Step("Claude Code was not selected in setup."); Result("claude_code", "skipped", "not selected"); }
            else if (FindCommand("claude") != null)
            {
                try
                {
                    RegisterClaudeCodeMcpServer(CliServerName, bridge, arguments, legacyNames);
                    if (!bridge.EndsWith(".ps1", StringComparison.OrdinalIgnoreCase)) RemoveStaleBridgeCliEntries("Claude Code", FindCommand("claude"), CliServerName, new[] { "--scope", "user" });
                    detected++;
                    Result("claude_code", "ok");
                }
                catch (Exception exception)
                {
                    registrationErrors.Add("Claude Code: " + exception.Message);
                    Warning("Claude Code registration failed; continuing with Claude Desktop: " + exception.Message);
                    Result("claude_code", "failed", "see the setup log");
                }
            }
            else { Step("Claude Code was not detected, so its MCP registration was skipped."); Result("claude_code", "skipped", "Claude Code is not installed"); }

            Phase("claude_desktop");
            if (!clients.Contains("ClaudeDesktop")) { Step("Claude Desktop was not selected in setup."); Result("claude_desktop", "skipped", "not selected"); }
            else
            {
                if (_o.InstallClaudeDesktopIfMissing && claudeDesktopInstallation == null) claudeDesktopInstallation = InstallClaudeDesktop();
                if (claudeDesktopInstallation != null || _o.InstallClaudeDesktopIfMissing)
                {
                    bool desktopFailed = false;
                    foreach (string configPath in ClaudeDesktopConfigPaths())
                    {
                        try
                        {
                            RegisterClaudeDesktopMcpServer("Smart Connector", bridge, arguments, claudeDesktopLegacyNames, configPath);
                            detected++;
                        }
                        catch (Exception exception)
                        {
                            desktopFailed = true;
                            registrationErrors.Add("Claude Desktop at " + configPath + ": " + exception.Message);
                            Warning("Could not update Claude config at " + configPath + "; continuing with other paths.");
                        }
                    }
                    Result("claude_desktop", desktopFailed ? "failed" : "ok", desktopFailed ? "see the setup log" : "Claude restarts to load it");
                    RestartClaudeDesktopIfRunning(claudeDesktopProcesses, claudeDesktopInstallation);
                }
                else
                {
                    Step("Claude Desktop was not detected. Its local MCP registration was skipped; Claude web and mobile require the separate remote connector.");
                    Result("claude_desktop", "skipped", "Claude Desktop is not installed");
                }
            }

            if (detected > 0 && File.Exists(compiled)) VerifyConnectorTools(compiled);

            if (registrationErrors.Count > 0)
                throw new EngineException("Some AI client registrations failed. Other registrations were still attempted. Repair these clients and run setup again: " + String.Join("; ", registrationErrors));

            if (detected == 0)
                Step("No supported AI client was detected. Connector files and skills were installed; run Install / Repair after installing Codex or Claude.");
        }

        // The checks at the end of Install, Test and Status.
        private void TestAutodeskRegistration()
        {
            string codex = FindCommand("codex");
            if (codex != null)
            {
                External registration = InvokeAllowFailure(codex, "mcp", "get", CliServerName);
                Step(registration.ExitCode == 0 ? "Codex has the Smart Connector registration." : "Smart Connector is not registered yet.");
            }
            else if (ConnectorStatus.ChatGptDesktopInstalled())
            {
                string config = Path.Combine(CodexHome, "config.toml");
                bool registered = File.Exists(config) && File.ReadAllLines(config).Any(line => Regex.IsMatch(line, @"^\s*\[mcp_servers\.(smart-connector|autodesk)\]", RegexOptions.IgnoreCase));
                Step(registered ? "ChatGPT Desktop has the Smart Connector registration (Codex settings)." : "Smart Connector is not registered for ChatGPT Desktop yet.");
            }
            else Step("Codex command was not detected.");

            string claude = FindCommand("claude");
            if (claude != null)
            {
                External registration = InvokeAllowFailure(claude, "mcp", "get", CliServerName);
                Step(registration.ExitCode == 0 ? "Claude Code has the Smart Connector registration." : "Smart Connector is not registered in Claude Code yet.");
            }
            else Step("Claude Code command was not detected.");

            if (GetClaudeDesktopInstallation() != null)
            {
                string configPath = ClaudeDesktopConfigPath;
                try
                {
                    OMap config = OJson.ReadFile(configPath) as OMap;
                    if (config == null) throw new EngineException("not an object");
                    OMap servers = config.Get("mcpServers") as OMap;
                    if (servers != null && servers.Has("Smart Connector")) Step("Claude Desktop has the Smart Connector registration at " + configPath + ".");
                    else Step("Smart Connector is not registered in Claude Desktop yet.");
                }
                catch (Exception) { Step("Claude Desktop was detected, but its local MCP configuration is missing or invalid."); }
            }
            else Step("Claude Desktop was not detected. Its local MCP registration is not installed.");
        }
    }
}
