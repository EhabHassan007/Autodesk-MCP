using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
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


        // The standard places (created when missing), then every other claude_desktop_config.json found under AppData.
        private static string[] ClaudeDesktopConfigPaths()
        {
            return ClaudeConfigFiles.Standard().Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
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

        // ---------- reading the registration back ----------

        // Whether Codex's config.toml has the [mcp_servers.<name>] table and its command starts this program. Codex,
        // ChatGPT Desktop and the Codex app all read this file, whoever wrote it.
        internal static bool CodexConfigHasConnector(string name, string command)
        {
            string configPath = Path.Combine(CodexHome, "config.toml");
            try
            {
                if (!File.Exists(configPath)) return false;
                string program = Path.GetFileName(command);
                bool inTable = false;
                foreach (string line in File.ReadAllLines(configPath))
                {
                    Match header = Regex.Match(line, @"^\s*\[(?!\[)\s*mcp_servers\.(""[^""]*""|'[^']*'|[A-Za-z0-9_-]+)\s*\]");
                    if (header.Success) { inTable = String.Equals(header.Groups[1].Value.Trim('"', '\''), name, StringComparison.OrdinalIgnoreCase); continue; }
                    if (Regex.IsMatch(line, @"^\s*\[")) { inTable = false; continue; }
                    if (inTable && Regex.IsMatch(line, @"^\s*command\s*=") && line.IndexOf(program, StringComparison.OrdinalIgnoreCase) >= 0) return true;
                }
            }
            catch (Exception) { }
            return false;
        }

        // Claude Code keeps user-level MCP servers in .claude.json in the home folder (or in CLAUDE_CONFIG_DIR when set).
        internal static string ClaudeCodeConfigPath
        {
            get
            {
                string folder = Env.Variable("CLAUDE_CONFIG_DIR");
                return Path.Combine(String.IsNullOrWhiteSpace(folder) ? Env.Home : folder, ".claude.json");
            }
        }

        internal static bool ClaudeCodeConfigHasConnector(string name, string command)
        {
            try
            {
                if (!File.Exists(ClaudeCodeConfigPath)) return false;
                OMap config = OJson.ReadFile(ClaudeCodeConfigPath) as OMap;
                OMap servers = config == null ? null : config.Get("mcpServers") as OMap;
                OMap entry = servers == null ? null : servers.Get(name) as OMap;
                return entry != null && Convert.ToString(entry.Get("command")).IndexOf(Path.GetFileName(command), StringComparison.OrdinalIgnoreCase) >= 0;
            }
            catch (Exception) { return false; }
        }

        // Claude Code's user-level entry written into .claude.json directly, as `claude mcp add --scope user` writes it,
        // for when the claude command failed or did not answer. Every other key of the file is kept; the new file is
        // written beside the old one, read back, then put in place.
        private void RegisterClaudeCodeConfigFile(string name, string bridge, string[] bridgeArguments, string[] legacyNames)
        {
            string configPath = ClaudeCodeConfigPath;
            Step("Registering the " + name + " MCP server in Claude Code's settings at " + configPath + "...");
            int id = Process.GetCurrentProcess().Id;
            string temporaryPath = configPath + ".smart-connector-" + id + ".tmp";
            bool hadConfig = File.Exists(configPath);
            try
            {
                OMap config = hadConfig ? OJson.ReadFile(configPath) as OMap : new OMap();
                if (config == null) throw new EngineException("Claude Code's settings file is not a JSON object.");
                if (!config.Has("mcpServers") || config.Get("mcpServers") == null) config.Set("mcpServers", new OMap());
                OMap servers = config.Get("mcpServers") as OMap;
                if (servers == null) throw new EngineException("Claude Code's settings file has an mcpServers value that is not an object.");
                foreach (string legacyName in legacyNames)
                    if (servers.Has(legacyName) && IsOwnConnectorEntry(OJson.Write(servers.Get(legacyName)))) servers.Remove(legacyName);
                McpLaunch launch = GetMcpLaunch(bridge, bridgeArguments);
                OMap entry = new OMap();
                entry.Set("type", "stdio");
                entry.Set("command", launch.Command);
                entry.Set("args", new List<object>(launch.Arguments.Cast<object>()));
                entry.Set("env", new OMap());
                servers.Set(name, entry);
                Directory.CreateDirectory(Path.GetDirectoryName(configPath));
                File.WriteAllText(temporaryPath, OJson.Write(config), EngineText.Utf8);
                OJson.ReadFile(temporaryPath);   // what was written must read back
                if (hadConfig) File.Copy(temporaryPath, configPath, true); else File.Move(temporaryPath, configPath);
                Step("Smart Connector is registered for Claude Code. Restart Claude Code to load it.");
            }
            finally { if (File.Exists(temporaryPath)) File.Delete(temporaryPath); }
        }

        // The command-line registration, then a read of the app's own settings file. When the command failed, did not
        // answer, or reported success without writing the entry, the entry is written into the file directly.
        private string RegisterCodexChecked(string bridge, string[] arguments, string[] legacyNames)
        {
            McpLaunch launch = GetMcpLaunch(bridge, arguments);
            string problem = null;
            try
            {
                WithCommandTimeout(AiCommandTimeoutMs, delegate
                {
                    RegisterMcpServer(CliServerName, bridge, arguments, legacyNames);
                    if (!bridge.EndsWith(".ps1", StringComparison.OrdinalIgnoreCase)) RemoveStaleBridgeCliEntries("Codex", FindCommand("codex"), CliServerName, new string[0]);
                });
            }
            catch (Exception exception) { problem = exception.Message; }
            if (problem == null && CodexConfigHasConnector(CliServerName, launch.Command))
            {
                Step("Checked Codex's settings file: the Smart Connector entry is there.");
                return "";
            }
            Warning(problem != null
                ? "The codex command could not register Smart Connector (" + problem.Split('\n')[0].Trim() + "). Writing Codex's settings file directly."
                : "The codex command reported success, but Codex's settings file has no Smart Connector entry. Writing it directly.");
            RegisterCodexConfigFile(CliServerName, bridge, arguments, legacyNames);
            if (!CodexConfigHasConnector(CliServerName, launch.Command)) throw new EngineException("Codex's settings file still has no Smart Connector entry after writing it.");
            return "written to Codex's settings file; restart Codex";
        }

        private string RegisterClaudeCodeChecked(string bridge, string[] arguments, string[] legacyNames)
        {
            McpLaunch launch = GetMcpLaunch(bridge, arguments);
            string problem = null;
            try
            {
                WithCommandTimeout(AiCommandTimeoutMs, delegate
                {
                    RegisterClaudeCodeMcpServer(CliServerName, bridge, arguments, legacyNames);
                    if (!bridge.EndsWith(".ps1", StringComparison.OrdinalIgnoreCase)) RemoveStaleBridgeCliEntries("Claude Code", FindCommand("claude"), CliServerName, new[] { "--scope", "user" });
                });
            }
            catch (Exception exception) { problem = exception.Message; }
            if (problem == null && ClaudeCodeConfigHasConnector(CliServerName, launch.Command))
            {
                Step("Checked Claude Code's settings file: the Smart Connector entry is there.");
                return "";
            }
            Warning(problem != null
                ? "The claude command could not register Smart Connector (" + problem.Split('\n')[0].Trim() + "). Writing Claude Code's settings file directly."
                : "The claude command reported success, but Claude Code's settings file has no Smart Connector entry. Writing it directly.");
            RegisterClaudeCodeConfigFile(CliServerName, bridge, arguments, legacyNames);
            if (!ClaudeCodeConfigHasConnector(CliServerName, launch.Command)) throw new EngineException("Claude Code's settings file still has no Smart Connector entry after writing it.");
            return "written to Claude Code's settings file; restart Claude Code";
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

            string configPath = ClaudeCodeConfigPath;
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

        // False for the quiet reconnect after an update (ConnectAiApps): it never closes Claude Desktop under the user.
        private bool _restartClaudeDesktop = true;

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
                    string note = RegisterCodexChecked(bridge, arguments, legacyNames);
                    detected++;
                    if (note.Length > 0) Result("codex", "ok", note); else Result("codex", "ok");
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
                    string note = RegisterClaudeCodeChecked(bridge, arguments, legacyNames);
                    detected++;
                    if (note.Length > 0) Result("claude_code", "ok", note); else Result("claude_code", "ok");
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
                    string[] standard = ClaudeDesktopConfigPaths();
                    foreach (string configPath in standard)
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
                    // Claude Desktop 6.x from the Microsoft Store was found reading a third copy, so every other
                    // claude_desktop_config.json under AppData gets the entry too. A found file that cannot be read is
                    // reported and left as it is; it does not fail the step, because it may not be the one Claude uses.
                    List<string> registered = new List<string>(standard.Where(File.Exists));
                    string[] others = ClaudeConfigFiles.Search().Where(found => !standard.Contains(found, StringComparer.OrdinalIgnoreCase)).ToArray();
                    if (others.Length > 0) Step("Found " + others.Length + " more Claude Desktop config file(s); adding Smart Connector there too.");
                    foreach (string configPath in others)
                    {
                        try
                        {
                            RegisterClaudeDesktopMcpServer("Smart Connector", bridge, arguments, claudeDesktopLegacyNames, configPath);
                            registered.Add(configPath);
                        }
                        catch (Exception exception) { Warning("Left the Claude Desktop config at " + configPath + " unchanged: " + exception.Message); }
                    }
                    ClaudeConfigFiles.Remember(registered);
                    if (_restartClaudeDesktop)
                    {
                        Result("claude_desktop", desktopFailed ? "failed" : "ok", desktopFailed ? "see the setup log" : "Claude restarts to load it");
                        RestartClaudeDesktopIfRunning(claudeDesktopProcesses, claudeDesktopInstallation);
                    }
                    else
                    {
                        Result("claude_desktop", desktopFailed ? "failed" : "ok", desktopFailed ? "see the setup log" : "loads the next time Claude starts");
                        if (claudeDesktopProcesses.Length > 0) Step("Claude Desktop is open and was left running; it loads Smart Connector the next time it starts.");
                    }
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

        // ---------- reconnecting the AI apps after an update ----------

        // An update is installed by the PREVIOUS version's program, which then connects the AI apps with its own code, so a
        // fix to that code reaches a PC only through this: the first time this version's program starts after the update
        // (the app, a Revit or AutoCAD button, the daily update check, or Claude starting the connector), it connects the
        // AI apps once more in the background with this version's code. It never closes Claude Desktop. The outcome is
        // kept in ai-apps-connected.json and the run in ai-apps.log (both in %LOCALAPPDATA%\AutodeskMcpConnector).
        private void ConnectAiApps()
        {
            using (Mutex mutex = new Mutex(false, @"Local\SmartConnector.ConnectAiApps"))
            {
                bool acquired;
                try { acquired = mutex.WaitOne(0); }
                catch (AbandonedMutexException) { acquired = true; }
                if (!acquired) { Step("The AI apps are already being reconnected."); return; }
                try
                {
                    // Lets an update or setup that started this program finish writing the same settings files first.
                    Thread.Sleep(15000);
                    AiAppsState.Save("started", "");
                    InstallChoices choices = GetInstallChoices("", "All", false, "", InstallChoicesPath);
                    Step("Reconnecting the AI apps for Smart Connector " + Paths.Version + ": " + (choices.AiClients.Length > 0 ? String.Join(", ", choices.AiClients) : "none") + ".");
                    _restartClaudeDesktop = false;
                    try
                    {
                        RegisterDetectedAiClients(Paths.Root, choices.AiClients);
                        AiAppsState.Save("ok", "");
                        Step("The AI apps are connected.");
                    }
                    catch (Exception exception)
                    {
                        AiAppsState.Save("failed", exception.Message);
                        Warning(exception.Message);
                        // Reported to the administrator like a failed tool (cleaned of names and paths, joined PCs only).
                        Failures.Failed("connect_ai_apps", "connector", exception.Message);
                    }
                }
                finally { mutex.ReleaseMutex(); }
            }
        }

        // Whether this version still has to reconnect the AI apps on this PC: only an install whose setup has run to the
        // end (its choices are saved and no setup is pending), and only once per version (a run that never finished is
        // tried again after a day).
        internal static bool AiAppsReconnectDue()
        {
            if (!File.Exists(Path.Combine(Paths.Root, "bin", "SmartConnector.exe"))) return false;
            // Only the installed program (setup's folder): a copy built elsewhere, such as a test build, must never point
            // this PC's AI apps at itself.
            string installRoot = Path.GetFullPath(Path.Combine(Paths.LocalAppData, "BIM-CAD-MCP")).TrimEnd('\\');
            if (!String.Equals(Path.GetFullPath(Paths.Root).TrimEnd('\\'), installRoot, StringComparison.OrdinalIgnoreCase)) return false;
            if (!File.Exists(InstallChoicesPath)) return false;
            if (File.Exists(Path.Combine(Paths.Root, "setup", "setup-pending.txt"))) return false;
            OMap state = AiAppsState.Read();
            if (state == null) return true;
            if (!String.Equals(Convert.ToString(state.Get("version")), Paths.Version, StringComparison.OrdinalIgnoreCase)) return true;
            if (!String.Equals(Convert.ToString(state.Get("state")), "started", StringComparison.Ordinal)) return false;
            DateTime at;
            return !DateTime.TryParse(Convert.ToString(state.Get("utc")), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out at) || DateTime.UtcNow - at.ToUniversalTime() > TimeSpan.FromDays(1);
        }

        // The checks at the end of Install, Test and Status.
        private void TestAutodeskRegistration()
        {
            WithCommandTimeout(AiCommandTimeoutMs, TestAiAppRegistration);
        }

        private void TestAiAppRegistration()
        {
            string codex = FindCommand("codex");
            if (codex != null)
            {
                External registration = InvokeAllowFailure(codex, "mcp", "get", CliServerName);
                Step(registration.ExitCode == 0 || ConnectorStatus.CodexConnected() ? "Codex has the Smart Connector registration." : "Smart Connector is not registered in Codex yet.");
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
                Step(registration.ExitCode == 0 || ConnectorStatus.ClaudeCodeConnected() ? "Claude Code has the Smart Connector registration." : "Smart Connector is not registered in Claude Code yet.");
            }
            else Step("Claude Code command was not detected.");

            if (GetClaudeDesktopInstallation() != null)
            {
                // Every config that exists, not only the first: Claude reads one of them, and which one depends on its version.
                string[] existing = ClaudeConfigFiles.Known().Where(File.Exists).ToArray();
                if (existing.Length == 0) Step("Claude Desktop was detected, but its local MCP configuration is missing.");
                foreach (string configPath in existing)
                {
                    try
                    {
                        OMap config = OJson.ReadFile(configPath) as OMap;
                        if (config == null) throw new EngineException("not an object");
                        OMap servers = config.Get("mcpServers") as OMap;
                        if (servers != null && servers.Has("Smart Connector")) Step("Claude Desktop has the Smart Connector registration at " + configPath + ".");
                        else Step("Smart Connector is not registered in the Claude Desktop config at " + configPath + " yet.");
                    }
                    catch (Exception) { Step("The Claude Desktop config at " + configPath + " is invalid."); }
                }
            }
            else Step("Claude Desktop was not detected. Its local MCP registration is not installed.");
        }
    }

    // ai-apps-connected.json: which version last connected the AI apps on this PC, and how it went.
    internal static class AiAppsState
    {
        internal static string FolderPath { get { return Path.Combine(Paths.LocalAppData, "AutodeskMcpConnector"); } }
        internal static string StatePath { get { return Path.Combine(FolderPath, "ai-apps-connected.json"); } }
        internal static string LogPath { get { return Path.Combine(FolderPath, "ai-apps.log"); } }

        internal static OMap Read()
        {
            try { return File.Exists(StatePath) ? OJson.ReadFile(StatePath) as OMap : null; }
            catch (Exception) { return null; }
        }

        internal static void Save(string state, string detail)
        {
            try
            {
                OMap map = new OMap();
                map.Set("version", Paths.Version);
                map.Set("state", state);
                map.Set("detail", detail ?? "");
                map.Set("utc", DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture));
                Directory.CreateDirectory(FolderPath);
                File.WriteAllText(StatePath, OJson.Write(map) + "\r\n", EngineText.Utf8);
            }
            catch (Exception) { }
        }

        // Called at every start of this program. The commands people and the AI apps start count; setup, the install
        // engine's own install and update, the update window and Skills Sync (which the previous version's updater runs
        // from the new files while it is still working) do not.
        internal static bool Counts(string[] args)
        {
            if (args.Contains("--smoke-test")) return false;
            string command = args.Length > 0 ? args[0] : "";
            if (command == "app" || command == "settings" || command == "mcp") return true;
            string action = "";
            for (int i = 1; i + 1 < args.Length; i++) if (args[i] == "--action") action = args[i + 1];
            if (command == "action") return action != "InstallUpdate";
            if (command == "engine") return action == "CheckUpdate" || action == "Status" || action == "Test";
            return false;
        }

        internal static void StartIfDue(string[] args)
        {
            try
            {
                if (!Counts(args) || !InstallEngine.AiAppsReconnectDue()) return;
                // Claimed before starting, so programs starting at the same moment do not each start one.
                Save("started", "");
                // Through the Windows shell, so the background run holds none of this program's handles (Claude's pipes
                // when this is the MCP server).
                ProcessStartInfo info = new ProcessStartInfo(System.Reflection.Assembly.GetExecutingAssembly().Location, "engine --action ConnectAiApps");
                info.UseShellExecute = true;
                info.WindowStyle = ProcessWindowStyle.Hidden;
                info.WorkingDirectory = Paths.LocalAppData;
                Process.Start(info).Dispose();
            }
            catch (Exception) { }
        }
    }
}
