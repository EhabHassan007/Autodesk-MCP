using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.IO.Pipes;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;

// Autodesk side of setup: the AutoCAD Add-ins panel (bundle, .cuix, trusted folder), the Revit 2024 add-in (compiled on
// this PC by the Windows compiler, as src\revit\build-revit-addin.ps1 does), the Start menu entry and the status checks.
namespace SmartConnector
{
    internal sealed partial class InstallEngine
    {
        // ---------- AutoCAD ----------

        private string[] GetAutoCadReleases()
        {
            if (_o.TestAutoCadReleases != null) return _o.TestAutoCadReleases;
            return ConnectorStatus.AutoCadReleasesInstalled();
        }

        private void TestAutoCadSetup()
        {
            string[] releases = GetAutoCadReleases();
            if (releases.Length > 0) Step("AutoCAD installation detected: " + String.Join(", ", releases));
            else Step("Full AutoCAD for Windows was not detected.");

            dynamic cad = null;
            foreach (string progId in AutoCadBridge.ProgIds())
            {
                try { cad = Marshal.GetActiveObject(progId); break; } catch (Exception) { }
            }
            if (cad != null)
            {
                if (Convert.ToInt32(cad.Documents.Count) > 0)
                {
                    dynamic document = cad.ActiveDocument;
                    Step("Live AutoCAD connection passed: version " + Convert.ToString(cad.Version) + "; " + Convert.ToString(document.Name) + "; " + Convert.ToString(document.Layers.Count) + " layer(s).");
                }
                else Step("AutoCAD is running, but no drawing is open.");
            }
            else Step("AutoCAD is not currently available for a live test. Start AutoCAD and open a drawing.");
        }

        private static string[] AutoCadButtonIcons(string assetsDirectory)
        {
            string[] images = Directory.Exists(assetsDirectory) ? Directory.GetFiles(assetsDirectory, "sac-*.png").OrderBy(f => Path.GetFileName(f), StringComparer.OrdinalIgnoreCase).ToArray() : new string[0];
            if (images.Length == 0) throw new EngineException("The AutoCAD button icons are missing from " + assetsDirectory + ".");
            return images;
        }

        // A .cuix is an OPC zip: the parts in the bundle's cuix-source folder plus the button icons from assets. Packed like
        // Autodesk's own AppManager.cuix, whose ribbon icons show: PNGs not compressed (deflate level 0) and every part
        // listed in Menu_Package_Info.xml. Without that list AutoCAD 2025 showed our buttons as plain text.
        internal static void NewAutoCadCuix(string sourceDirectory, string assetsDirectory, string destination)
        {
            string[] parts = { "[Content_Types].xml", "_rels/.rels", "Header.cui", "MenuGroup.cui", "RibbonRoot.cui" };
            string[] images = AutoCadButtonIcons(assetsDirectory);
            if (File.Exists(destination)) File.Delete(destination);
            string modified = DateTimeOffset.Now.ToString("o", System.Globalization.CultureInfo.InvariantCulture);
            List<string> listed = new List<string> { "Header.cui", "MenuGroup.cui", "RibbonRoot.cui" };
            listed.AddRange(images.Select(i => Path.GetFileName(i)));
            listed.Add("VirtualMNRRoot"); listed.Add("Menu_Package_Info.xml");
            string packageInfo = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n<MenuPackageParts>\r\n" +
                String.Join("\r\n", listed.Select(name => "  <PartData PartData_Name=\"/" + name + "\" PartData_Modified=\"" + modified + "\" />")) +
                "\r\n</MenuPackageParts>";
            using (ZipArchive zip = ZipFile.Open(destination, ZipArchiveMode.Create))
            {
                foreach (string part in parts)
                {
                    string source = Path.Combine(sourceDirectory, part.Replace('/', Path.DirectorySeparatorChar));
                    if (!File.Exists(source)) throw new EngineException("CUIX part " + part + " is missing from " + sourceDirectory + ".");
                    zip.CreateEntryFromFile(source, part, CompressionLevel.Optimal);
                }
                foreach (string image in images) zip.CreateEntryFromFile(image, Path.GetFileName(image), CompressionLevel.NoCompression);
                ZipArchiveEntry info = zip.CreateEntry("Menu_Package_Info.xml", CompressionLevel.Optimal);
                using (StreamWriter writer = new StreamWriter(info.Open(), EngineText.Utf8)) writer.Write(packageInfo);
            }
        }

        // AutoCAD keeps its own copy of a loaded partial menu in each release's roaming Support folder (seen on 2025). A
        // stale copy can keep the old panel, so remove ours by its exact name; AutoCAD takes the new one from the bundle.
        private void RemoveAutoCadMenuCopies(string roamingRoot)
        {
            // <roaming>\AutoCAD *\R*\*\Support\SmartAutodeskConnector.cuix
            if (!Directory.Exists(roamingRoot)) return;
            try
            {
                foreach (string product in Directory.GetDirectories(roamingRoot, "AutoCAD *"))
                    foreach (string release in Directory.GetDirectories(product, "R*"))
                        foreach (string language in Directory.GetDirectories(release))
                        {
                            string copy = Path.Combine(language, "Support", "SmartAutodeskConnector.cuix");
                            if (!File.Exists(copy)) continue;
                            try { File.Delete(copy); }
                            catch (Exception) { Warning("Could not replace the old panel menu " + copy + "; close AutoCAD and run setup again."); }
                        }
            }
            catch (Exception) { }
        }

        // AutoCAD keeps SECURELOAD and TRUSTEDPATHS per profile, in
        // HKCU\Software\Autodesk\AutoCAD\<release>\<product>\Profiles\<profile>\Variables; the Profiles key's default value
        // names the current profile (checked on AutoCAD 2025: <<Unnamed Profile>>). Returns the Variables keys of every
        // profile (as paths below HKCU), creating the current profile's key if AutoCAD has not written it yet.
        private static List<string> AutoCadProfileVariableKeys(string registryRoot)
        {
            List<string> result = new List<string>();
            using (RegistryKey root = Registry.CurrentUser.OpenSubKey(registryRoot))
            {
                if (root == null) return result;
                foreach (string release in root.GetSubKeyNames())
                {
                    using (RegistryKey releaseKey = root.OpenSubKey(release))
                    {
                        if (releaseKey == null) continue;
                        foreach (string product in releaseKey.GetSubKeyNames())
                        {
                            string productPath = registryRoot + "\\" + release + "\\" + product;
                            using (RegistryKey profiles = Registry.CurrentUser.OpenSubKey(productPath + "\\Profiles", true))
                            {
                                if (profiles == null) continue;
                                string currentProfile = Convert.ToString(profiles.GetValue(""));
                                if (currentProfile.Length > 0) profiles.CreateSubKey(currentProfile + "\\Variables").Dispose();
                                foreach (string profile in profiles.GetSubKeyNames())
                                {
                                    using (RegistryKey profileKey = profiles.OpenSubKey(profile))
                                    {
                                        if (profileKey != null && profileKey.GetSubKeyNames().Contains("Variables", StringComparer.OrdinalIgnoreCase))
                                            result.Add(productPath + "\\Profiles\\" + profile + "\\Variables");
                                    }
                                }
                            }
                        }
                    }
                }
            }
            return result;
        }

        private static List<string> TrustedPathEntries(RegistryKey key)
        {
            string value = Convert.ToString(key.GetValue("TRUSTEDPATHS"));
            return value.Split(';').Where(e => e.Length > 0).ToList();
        }

        // With SECURELOAD=1 AutoCAD asks before loading the LISP from %APPDATA% ("not located in a trusted folder", seen live
        // on AutoCAD 2025). Trusting only the bundle's Contents folder removes that prompt (approved by the owner). Existing
        // entries are kept; AutoCAD reads the value when it starts.
        internal static int AddAutoCadTrustedPath(string path, string registryRoot)
        {
            int updated = 0;
            foreach (string variables in AutoCadProfileVariableKeys(registryRoot))
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(variables, true))
                {
                    List<string> entries = TrustedPathEntries(key);
                    if (entries.Any(e => String.Equals(e.TrimEnd('\\'), path.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))) continue;
                    entries.Add(path);
                    key.SetValue("TRUSTEDPATHS", String.Join(";", entries), RegistryValueKind.String);
                    updated++;
                }
            }
            return updated;
        }

        internal static int RemoveAutoCadTrustedPath(string path, string registryRoot)
        {
            int updated = 0;
            foreach (string variables in AutoCadProfileVariableKeys(registryRoot))
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(variables, true))
                {
                    List<string> entries = TrustedPathEntries(key);
                    List<string> kept = entries.Where(e => !String.Equals(e.TrimEnd('\\'), path.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)).ToList();
                    if (kept.Count == entries.Count) continue;
                    key.SetValue("TRUSTEDPATHS", String.Join(";", kept), RegistryValueKind.String);
                    updated++;
                }
            }
            return updated;
        }

        private static string PluginsRoot { get { return Path.Combine(Env.AppData, "Autodesk", "ApplicationPlugins"); } }
        private static string RoamingAutodesk { get { return Path.Combine(Env.AppData, "Autodesk"); } }

        // Removes the panel and its trusted path. AutoCAD drops the panel at its next start.
        private void UninstallAutoCadBundle()
        {
            string target = Path.Combine(PluginsRoot, "SmartAutodeskConnector.bundle");
            RemoveAutoCadTrustedPath(Path.Combine(target, "Contents"), _o.AutoCadRegistryRoot);
            RemoveAutoCadMenuCopies(RoamingAutodesk);
            if (Directory.Exists(target)) Directory.Delete(target, true);
            Step("Removed the AutoCAD Add-ins panel and its trusted path. Restart AutoCAD to finish.");
        }

        private static void CopyFolderFiles(string from, string to)
        {
            foreach (string file in Directory.GetFiles(from)) File.Copy(file, Path.Combine(to, Path.GetFileName(file)), true);
        }

        // Adds the Smart Connector panel to the AutoCAD Add-ins tab for this user (no admin rights needed). AutoCAD loads it
        // at its next start.
        private void InstallAutoCadBundle(string root)
        {
            string source = Path.Combine(root, "src", "autocad", "SmartAutodeskConnector.bundle");
            string target = Path.Combine(PluginsRoot, "SmartAutodeskConnector.bundle");
            string staging = Path.Combine(Path.GetTempPath(), "SmartAutodeskConnector-" + Guid.NewGuid().ToString("N"));
            try
            {
                Directory.CreateDirectory(Path.Combine(staging, "Contents"));
                File.Copy(Path.Combine(source, "PackageContents.xml"), Path.Combine(staging, "PackageContents.xml"), true);
                CopyFolderFiles(Path.Combine(source, "Contents"), Path.Combine(staging, "Contents"));
                NewAutoCadCuix(Path.Combine(source, "Contents", "cuix-source"), Path.Combine(root, "assets"), Path.Combine(staging, "Contents", "SmartAutodeskConnector.cuix"));
                // Also beside the .cuix, in case AutoCAD looks the icons up as files on the bundle's paths.
                foreach (string icon in AutoCadButtonIcons(Path.Combine(root, "assets"))) File.Copy(icon, Path.Combine(staging, "Contents", Path.GetFileName(icon)), true);
                RemoveAutoCadMenuCopies(RoamingAutodesk);
                Directory.CreateDirectory(Path.Combine(target, "Contents"));
                // File by file, so a copy AutoCAD has open is reported instead of leaving a half-removed bundle.
                string stagingRoot = EngineText.Trimmed(staging);
                foreach (string file in Directory.GetFiles(staging, "*", SearchOption.AllDirectories))
                {
                    string destination = Path.Combine(target, file.Substring(stagingRoot.Length).TrimStart('\\', '/'));
                    Directory.CreateDirectory(Path.GetDirectoryName(destination));
                    File.Copy(file, destination, true);
                }
            }
            finally
            {
                try { if (Directory.Exists(staging)) Directory.Delete(staging, true); } catch (Exception) { }
            }
            int trusted = AddAutoCadTrustedPath(Path.Combine(target, "Contents"), _o.AutoCadRegistryRoot);
            if (trusted > 0) Step("Added the panel's folder to AutoCAD's trusted paths in " + trusted + " profile(s).");
            Step("Installed the AutoCAD Add-ins panel at " + target + ". Restart AutoCAD to load it.");
        }

        private void InstallAutoCadBundleStep(string root)
        {
            Phase("autocad");
            if (GetAutoCadReleases().Length == 0)
            {
                Step("AutoCAD was not detected, so its Add-ins panel was skipped.");
                Result("autocad", "skipped", "AutoCAD is not installed");
                return;
            }
            try
            {
                InstallAutoCadBundle(root);
                Result("autocad", "ok", "restart AutoCAD to load it");
            }
            catch (Exception exception)
            {
                // The connector itself works without the panel; report and carry on.
                Warning("The AutoCAD Add-ins panel could not be installed: " + exception.Message);
                Result("autocad", "failed", "close AutoCAD and run setup again");
            }
        }

        // ---------- Start menu ----------

        // Start menu entry for the Smart Connector app (this user only). Never fails setup.
        private void InstallStartMenuShortcut(string root)
        {
            try
            {
                string programs = Path.Combine(Env.AppData, "Microsoft", "Windows", "Start Menu", "Programs");
                Directory.CreateDirectory(programs);
                Type shellType = Type.GetTypeFromProgID("WScript.Shell");
                if (shellType == null) throw new InvalidOperationException("Windows Script Host is not available.");
                dynamic shell = Activator.CreateInstance(shellType);
                try
                {
                    dynamic shortcut = shell.CreateShortcut(Path.Combine(programs, "Smart Connector.lnk"));
                    // The compiled Smart Connector program when it is installed (the setup .exe already points the entry at it);
                    // otherwise the PowerShell app (an install taken from the repository). An entry already right is kept.
                    string program = Path.Combine(root, "bin", "SmartConnector.exe");
                    string app = Path.Combine(root, "installer", "SmartConnectorApp.ps1");
                    bool useProgram = File.Exists(program);
                    bool current = useProgram
                        ? String.Equals(Convert.ToString(shortcut.TargetPath), program, StringComparison.OrdinalIgnoreCase)
                        : Convert.ToString(shortcut.Arguments).IndexOf(app, StringComparison.OrdinalIgnoreCase) >= 0;
                    if (current)
                    {
                        Step("Smart Connector is in the Start menu.");
                        return;
                    }
                    if (useProgram)
                    {
                        shortcut.TargetPath = program;
                        shortcut.Arguments = "app";
                        shortcut.WindowStyle = 1;
                    }
                    else
                    {
                        shortcut.TargetPath = Path.Combine(Env.Windows, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
                        shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + app + "\"";
                        shortcut.WindowStyle = 7;
                    }
                    shortcut.WorkingDirectory = Paths.LocalAppData;
                    shortcut.IconLocation = Path.Combine(root, "assets", "logo.ico") + ",0";
                    shortcut.Description = "Smart Connector for Autodesk Revit and AutoCAD";
                    shortcut.Save();
                    Step("Added Smart Connector to the Start menu.");
                }
                finally { try { Marshal.ReleaseComObject((object)shell); } catch (Exception) { } }
            }
            catch (Exception exception) { Step("The Start menu shortcut could not be created: " + exception.Message); }
        }

        // ---------- Revit ----------

        private static bool TestRevit2024Installed()
        {
            return File.Exists(Path.Combine(Env.ProgramFiles, "Autodesk", "Revit 2024", "RevitAPI.dll"));
        }

        // Compiles the Revit add-in with the .NET Framework compiler that ships with Windows, against the installed Revit
        // API: what src\revit\build-revit-addin.ps1 does, as a child process of the compiler. Returns the DLL's path.
        internal string BuildRevitAddin(string root, string revitVersion, string outputPath)
        {
            int year;
            if (Int32.TryParse(revitVersion, out year) && year >= 2025)
                throw new EngineException("Revit 2025 and newer require a .NET 8 build. This source package currently builds Revit 2024 only.");
            string revitInstallPath = Path.Combine(Env.ProgramFiles, "Autodesk", "Revit " + revitVersion);
            string revitApi = Path.Combine(revitInstallPath, "RevitAPI.dll"), revitUiApi = Path.Combine(revitInstallPath, "RevitAPIUI.dll");
            string addin = Path.Combine(root, "src", "revit", "addin");
            string[] sources = { Path.Combine(addin, "RevitMcpApplication.cs"), Path.Combine(addin, "AdvancedControl.cs"), Path.Combine(addin, "ConnectorUi.cs") };
            string windir = Env.Get("WINDIR", Environment.SpecialFolder.Windows);
            string framework = Path.Combine(windir, "Microsoft.NET", "Framework64", "v4.0.30319");
            string compiler = Path.Combine(framework, "csc.exe");
            // WPF types for the ribbon icons, Microsoft.CSharp for dynamic, WinForms and Drawing for the Check Updates and Skills Sync dialogs.
            string[] references =
            {
                revitApi, revitUiApi, Path.Combine(framework, "WPF", "WindowsBase.dll"), Path.Combine(framework, "WPF", "PresentationCore.dll"),
                Path.Combine(framework, "Microsoft.CSharp.dll"), Path.Combine(framework, "System.Windows.Forms.dll"), Path.Combine(framework, "System.Drawing.dll")
            };
            foreach (string required in new[] { revitApi, revitUiApi }.Concat(sources).Concat(new[] { compiler }).Concat(references.Skip(2)))
                if (!File.Exists(required)) throw new EngineException("Required build file was not found: " + required);

            Directory.CreateDirectory(outputPath);
            string assembly = Path.Combine(outputPath, "BimCadMcp.Revit.dll");
            List<string> arguments = new List<string> { "/nologo", "/target:library", "/optimize+", "/platform:anycpu", "/out:" + assembly };
            arguments.AddRange(references.Select(r => "/reference:" + r));
            arguments.AddRange(sources);
            External built = Invoke(compiler, arguments.ToArray(), true, false, null);
            if (built.ExitCode != 0 || !File.Exists(assembly))
                throw new EngineException("Revit add-in compilation failed.\r\n" + String.Join("\r\n", built.Output));
            return assembly;
        }

        private void InstallRevitAddin(string root)
        {
            if (!TestRevit2024Installed()) throw new EngineException("Revit 2024 was not detected. Install Revit 2024 before installing its MCP add-in.");

            string buildOutput = Path.Combine(Path.GetTempPath(), "BimCadMcp-RevitBuild-" + Guid.NewGuid().ToString("N"));
            string assemblyDirectory = Path.Combine(root, "src", "revit", "bin", "2024");
            Directory.CreateDirectory(assemblyDirectory);
            string assembly;
            try
            {
                Step("Building the Revit 2024 add-in against the installed Revit API...");
                string builtAssembly = BuildRevitAddin(root, "2024", buildOutput);
                if (!File.Exists(builtAssembly)) throw new EngineException("The Revit add-in DLL was not produced.");

                // Revit locks loaded add-in DLLs. A content-addressed filename lets an update finish safely while Revit is
                // open; the manifest takes effect on next start.
                string assemblyHash = Sha256Hex(builtAssembly).Substring(0, 12).ToLowerInvariant();
                assembly = Path.Combine(assemblyDirectory, "BimCadMcp.Revit." + assemblyHash + ".dll");
                File.Copy(builtAssembly, assembly, true);
            }
            finally
            {
                try { if (Directory.Exists(buildOutput)) Directory.Delete(buildOutput, true); } catch (Exception) { }
            }

            string manifestDirectory = Path.Combine(Env.AppData, "Autodesk", "Revit", "Addins", "2024");
            Directory.CreateDirectory(manifestDirectory);
            string manifestPath = Path.Combine(manifestDirectory, "AutodeskMcpConnector.addin");
            string legacyManifestPath = Path.Combine(manifestDirectory, "BimCadMcp.addin");
            string manifest = String.Join("\r\n", new[]
            {
                "<?xml version=\"1.0\" encoding=\"utf-8\"?>",
                "<RevitAddIns>",
                "  <AddIn Type=\"Application\">",
                "    <Name>Smart Connector</Name>",
                "    <Assembly>" + SecurityElement.Escape(assembly) + "</Assembly>",
                "    <AddInId>2DCE7E67-4495-4F3B-A740-3D7C9D2DA124</AddInId>",
                "    <FullClassName>BimCadMcp.Revit.Application</FullClassName>",
                "    <VendorId>BIMC</VendorId>",
                "    <VendorDescription>Smart Connector for Codex and Claude</VendorDescription>",
                "  </AddIn>",
                "</RevitAddIns>"
            }) + "\r\n";
            File.WriteAllText(manifestPath, manifest, EngineText.Utf8Bom);
            if (File.Exists(legacyManifestPath)) File.Delete(legacyManifestPath);
            RemoveOldRevitAddinBuilds(assemblyDirectory, assembly);
            Step("Installed Revit add-in " + Path.GetFileName(assembly) + " and manifest " + manifestPath + ". Restart Revit to load it.");
        }

        // Every build gets a content-hashed name; older ones pile up. A copy Revit still has loaded is locked and simply
        // stays until the next install.
        internal static void RemoveOldRevitAddinBuilds(string directory, string keep)
        {
            if (!Directory.Exists(directory)) return;
            foreach (string old in Directory.GetFiles(directory, "BimCadMcp.Revit.*.dll"))
            {
                if (String.Equals(old, keep, StringComparison.OrdinalIgnoreCase)) continue;
                try { File.Delete(old); } catch (Exception) { }
            }
        }

        private void TestRevitSetup()
        {
            bool installed = TestRevit2024Installed();
            Step(installed ? "Revit 2024 installation detected." : "Revit 2024 was not detected.");

            string manifest = Path.Combine(Env.AppData, "Autodesk", "Revit", "Addins", "2024", "AutodeskMcpConnector.addin");
            Step(File.Exists(manifest) ? "Smart Connector add-in is installed for Revit 2024." : "Smart Connector add-in is not installed for Revit 2024 yet.");
            if (installed) Step("In Revit, open the Smart Connector ribbon tab and click Status.");

            string pipeName = "BimCadMcp.Revit.2024";
            string sessionDirectory = Paths.RevitSessions;
            if (Directory.Exists(sessionDirectory))
            {
                foreach (string sessionFile in Directory.GetFiles(sessionDirectory, "*.json"))
                {
                    try
                    {
                        object session = Json.Serializer.DeserializeObject(File.ReadAllText(sessionFile));
                        if (PsJson.Text(PsJson.Value(session, "revit_version")) == "2024")
                        {
                            using (Process.GetProcessById(PsJson.Int(PsJson.Value(session, "pid")))) { }
                            pipeName = PsJson.Text(PsJson.Value(session, "pipe_name"));
                            break;
                        }
                    }
                    catch (Exception) { }
                }
            }
            using (NamedPipeClientStream client = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut))
            {
                try
                {
                    client.Connect(250);
                    Step("Live Revit 2024 add-in connection is available on " + pipeName + ".");
                }
                catch (Exception) { Step("Live Revit connection is not available. Restart Revit 2024 after installation and open a project."); }
            }
        }
    }
}
