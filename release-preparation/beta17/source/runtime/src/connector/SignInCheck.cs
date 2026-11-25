using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

// The update reminder at Windows sign-in, so people hear about a new version before they open Revit or AutoCAD.
//   SmartConnector.exe signin-check             what Windows starts at sign-in (registered under
//                                               HKCU\Software\Microsoft\Windows\CurrentVersion\Run)
//   SmartConnector.exe signin-check --report    the same decision without waiting, without asking, printed as one line
// It is one short run, not a background program: it waits for the network, makes at most one update check a day (the
// same day stamp Revit, AutoCAD and the Smart Connector app use, so a person is asked once a day wherever they are first),
// asks only when a newer version exists, and exits. Nothing is scheduled and nothing stays running.
// The entry follows the Update checks switch: EnableNotifications adds it, DisableNotifications removes it.
namespace SmartConnector
{
    internal static class SignInCheck
    {
        internal const string ValueName = "Smart Connector update check";
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

        // Tests name their own key under HKCU, so a test never touches the Run key of the PC it runs on.
        private static string TestKey { get { return Env.Variable("SMARTCONNECTOR_TEST_RUN_KEY"); } }

        // The real Run key is written only by the installed program (%LOCALAPPDATA%\BIM-CAD-MCP\bin, from the profile
        // folder Windows reports, not from the LOCALAPPDATA variable a test sets), so a build in a temporary folder never
        // adds a sign-in entry pointing at itself.
        private static string KeyPath(out bool allowed)
        {
            if (TestKey.Length > 0) { allowed = true; return TestKey; }
            string installed = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BIM-CAD-MCP");
            allowed = String.Equals(Path.GetFullPath(Paths.Root).TrimEnd('\\'), Path.GetFullPath(installed).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
            return RunKey;
        }

        internal static string CommandLine { get { return "\"" + Launch.InstalledProgram + "\" signin-check"; } }

        // Returns the line for the install log; never throws (the entry is a convenience, not part of a working install).
        internal static string Register()
        {
            try
            {
                bool allowed;
                string path = KeyPath(out allowed);
                if (!allowed) return "Update reminder at Windows sign-in: not added (this copy of Smart Connector is not the installed one).";
                if (!File.Exists(Launch.InstalledProgram)) return "Update reminder at Windows sign-in: not added (bin\\SmartConnector.exe is missing).";
                using (RegistryKey key = Registry.CurrentUser.CreateSubKey(path))
                {
                    key.SetValue(ValueName, CommandLine, RegistryValueKind.String);
                }
                return "Update reminder at Windows sign-in: on (once a day, only when a new version is ready).";
            }
            catch (Exception exception) { return "Update reminder at Windows sign-in could not be added: " + exception.Message; }
        }

        internal static string Unregister()
        {
            try
            {
                bool allowed;
                string path = KeyPath(out allowed);
                if (!allowed) return "Update reminder at Windows sign-in: left as it is (this copy of Smart Connector is not the installed one).";
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(path, true))
                {
                    if (key != null && key.GetValue(ValueName) != null) key.DeleteValue(ValueName, false);
                }
                return "Update reminder at Windows sign-in: off.";
            }
            catch (Exception exception) { return "Update reminder at Windows sign-in could not be removed: " + exception.Message; }
        }

        // At the starts that count (the app, a Revit or AutoCAD button, Claude or Codex starting the connector): add the
        // entry when update checks are on and it is missing or points elsewhere. An update from 1.2.3 runs that version's
        // installer, which does not know the entry, so the first start of this version adds it. Cheap: one registry read.
        internal static void EnsureRegistered(string[] args)
        {
            try
            {
                if (!AiAppsState.Counts(args) || !UpdatesOn()) return;
                bool allowed;
                string path = KeyPath(out allowed);
                if (!allowed || !File.Exists(Launch.InstalledProgram)) return;
                string current = null;
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(path, false))
                {
                    if (key != null) current = key.GetValue(ValueName) as string;
                }
                if (!String.Equals(current, CommandLine, StringComparison.OrdinalIgnoreCase)) Register();
            }
            catch (Exception) { }
        }

        private static string UpdateStatePath { get { return Path.Combine(ConnectorStatus.ConnectorState, "update-state.json"); } }

        private static bool UpdatesOn()
        {
            object state = PsJson.Read(UpdateStatePath);
            return !PsJson.Truthy(PsJson.Value(state, "notifications_user_disabled"));
        }

        internal static int Run(string[] args)
        {
            bool report = Array.IndexOf(args, "--report") >= 0;
            if (report) Program.AttachConsole();
            Action<string> say = delegate(string line) { if (report) Console.WriteLine(line); };
            try
            {
                if (!UpdatesOn()) { say("off: update checks are switched off in Settings"); return 0; }
                double last = ConnectorStatus.ReadDay(ConnectorStatus.OpenCheckPath);
                if (last >= 0 && ConnectorStatus.Today - last < 0.8) { say("not due: checked less than a day ago"); return 0; }

                // Sign-in is busy and the network is often not up yet: wait a little, then try up to three times.
                if (!report) Thread.Sleep(TimeSpan.FromSeconds(45));
                bool checkedOnline = false;
                for (int attempt = 0; attempt < 3 && !checkedOnline; attempt++)
                {
                    if (attempt > 0 && !report) Thread.Sleep(TimeSpan.FromSeconds(60));
                    // Revit or the app may have checked while this one waited.
                    last = ConnectorStatus.ReadDay(ConnectorStatus.OpenCheckPath);
                    if (last >= 0 && ConnectorStatus.Today - last < 0.8) { say("not due: checked less than a day ago"); return 0; }
                    // The install engine's own check: reads latest.json and records available_version in update-state.json.
                    checkedOnline = InstallEngine.RunCommand(new[] { "--action", "CheckUpdate", "--repository-path", Paths.Root }) == 0;
                }
                if (!checkedOnline) { say("offline: the release manifest could not be read"); return 0; }
                // Only a check that reached the release counts for today, so an offline sign-in leaves Revit's check due.
                ConnectorStatus.WriteDay(ConnectorStatus.OpenCheckPath);

                object state = PsJson.Read(UpdateStatePath);
                string available = PsJson.Text(PsJson.Value(state, "available_version"));
                string installed = Paths.Version;
                if (available.Length == 0 || installed.Length == 0 || InstallEngine.CompareVersions(available, installed) <= 0)
                {
                    say("up to date: " + installed);
                    return 0;
                }
                say("available: " + available + " (installed " + installed + ")");
                if (report) return 0;
                if (Ask(available, installed)) Launch.UpdateWindow();
                return 0;
            }
            catch (Exception exception)
            {
                say("error: " + exception.Message);
                return report ? 1 : 0;
            }
        }

        // The same question Revit asks (ConnectorUi.cs AskUpdate), on top of whatever opened at sign-in.
        private static bool Ask(string available, string installed)
        {
            using (Form owner = new Form())
            {
                owner.TopMost = true; owner.ShowInTaskbar = false; owner.FormBorderStyle = FormBorderStyle.None;
                owner.StartPosition = FormStartPosition.CenterScreen; owner.Size = new System.Drawing.Size(1, 1); owner.Opacity = 0;
                owner.Show();
                DialogResult answer = MessageBox.Show(owner,
                    "Smart Connector " + available + " is available. You have version " + installed + ".\n\n" +
                    "Update now? The update installs when Revit and AutoCAD are closed and takes about a minute. " +
                    "Save your work first.\n\nChoose No to be asked again tomorrow. Check Updates in Smart Connector works any time.",
                    "Smart Connector update", MessageBoxButtons.YesNo, MessageBoxIcon.Information, MessageBoxDefaultButton.Button1);
                return answer == DialogResult.Yes;
            }
        }
    }
}
