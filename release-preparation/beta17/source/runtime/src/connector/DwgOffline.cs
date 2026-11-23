using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;

// Offline DWG tools: read and convert a closed .dwg file with the LibreDWG programs bundled in bin\libredwg\, without
// AutoCAD running. LibreDWG (https://github.com/libredwg/libredwg) is GPL-3.0-or-later and is only ever started as a
// separate program here (never linked into SmartConnector.exe); its licence text and source offer ship beside the
// programs (bin\libredwg\COPYING and SOURCE.txt). The pack is added to the release ZIP and the setup .exe by build.ps1
// -LibreDwgPack and is never committed. C# 5 only (see setup\build-connector-exe.ps1).
//   dwg_inspect  read-only: layers, text search
//   dwg_convert  writes a NEW file next to the source (or in output_dir): DXF, JSON, older DWG version, thumbnail.
//                An existing file is never overwritten and the source is never changed.
// LibreDWG is not AutoCAD: a rewritten DWG can lose dynamic blocks, proxy objects, solids or annotative detail, and a
// DWG that goes to an authority must be opened, audited and saved in AutoCAD first. Every conversion says so.
namespace SmartConnector
{
    internal static class DwgOffline
    {
        internal const string InspectTool = "dwg_inspect";
        internal const string ConvertTool = "dwg_convert";

        private const int DefaultTimeoutSeconds = 120;
        private const int MaxTimeoutSeconds = 600;
        private const int MaxListed = 500;
        private const int MaxStderr = 1500;
        private const string FidelityNote = "Converted by LibreDWG, not AutoCAD. Check the result against the source before relying on it; a rewritten DWG can lose dynamic blocks, proxy objects, solids and annotative detail. Open it in AutoCAD, audit it and save it there before it goes to an authority or consultant.";
        private static readonly string[] Versions = { "r12", "r14", "r2000", "r2004", "r2007", "r2010", "r2013", "r2018" };

        internal static string ToolFolder { get { return Path.Combine(Paths.Root, "bin", "libredwg"); } }

        internal static List<Dictionary<string, object>> Tools
        {
            get
            {
                List<Dictionary<string, object>> tools = new List<Dictionary<string, object>>();
                tools.Add(Schema.Tool(InspectTool,
                    "Read a CLOSED .dwg file without AutoCAD (LibreDWG, bundled). action layers lists the layer names (with_flags adds on/off, frozen and locked); action search finds a text string in the drawing's text, table names and optionally block definitions. Read-only: nothing is written. For the drawing that is open in AutoCAD use drawing_info and list_layers instead.",
                    Json.Object(
                        "action", Json.Object("type", "string", "enum", new object[] { "layers", "search" }, "description", "layers or search"),
                        "file", Json.Object("type", "string", "minLength", 1, "maxLength", 520, "description", "Absolute path of an existing .dwg file"),
                        "pattern", Json.Object("type", "string", "minLength", 1, "maxLength", 200, "description", "search only: the text to find (plain text, not a regular expression)"),
                        "ignore_case", Json.Object("type", "boolean", "description", "search only: ignore upper and lower case (default true)"),
                        "include_blocks", Json.Object("type", "boolean", "description", "search only: also look inside block definitions (default false)"),
                        "with_flags", Json.Object("type", "boolean", "description", "layers only: add the on/off, frozen and locked state of each layer (default false)")),
                    new string[] { "action", "file" }, true));
                tools.Add(Schema.Tool(ConvertTool,
                    "Convert a CLOSED .dwg file without AutoCAD (LibreDWG, bundled) into a NEW file. action to_dxf writes a DXF; to_json writes JSON; save_as_version writes a DWG saved as an older or newer version (version r12 to r2018); thumbnail extracts the preview image when the file has one. The source is never changed and an existing file is never overwritten: a numbered name is used instead. The result is reported with its path; check it before relying on it.",
                    Json.Object(
                        "action", Json.Object("type", "string", "enum", new object[] { "to_dxf", "to_json", "save_as_version", "thumbnail" }, "description", "to_dxf, to_json, save_as_version or thumbnail"),
                        "file", Json.Object("type", "string", "minLength", 1, "maxLength", 520, "description", "Absolute path of an existing .dwg file"),
                        "output_dir", Json.Object("type", "string", "minLength", 1, "maxLength", 520, "description", "Absolute path of an existing folder for the new file; defaults to the source file's folder"),
                        "version", Json.Object("type", "string", "enum", new object[] { "r12", "r14", "r2000", "r2004", "r2007", "r2010", "r2013", "r2018" }, "description", "save_as_version only: the DWG version to write"),
                        "timeout_seconds", Json.Object("type", "integer", "minimum", 5, "maximum", MaxTimeoutSeconds, "description", "Stop the conversion after this long (default 120)")),
                    new string[] { "action", "file" }, false));
                return tools;
            }
        }

        internal static object Invoke(string name, object arguments)
        {
            IDictionary<string, object> values = Schema.Check(Tools, name, arguments, false);
            string action = Convert.ToString(values["action"]);
            string source = ValidSource(Convert.ToString(values["file"]));
            if (name == InspectTool)
            {
                if (action == "layers") return Layers(source, Flag(values, "with_flags", false));
                return Search(source, values);
            }
            return ConvertFile(action, source, values);
        }

        // ---- inspect ----------------------------------------------------------------------------------------------

        private static object Layers(string source, bool withFlags)
        {
            List<string> args = new List<string>();
            if (withFlags) args.Add("-f");
            args.Add(source);
            Run result = Start("dwglayers.exe", args, Path.GetTempPath(), DefaultTimeoutSeconds);
            if (result.ExitCode != 0) throw new ToolException(Failure("The layer list", source, result));
            List<object> layers = new List<object>();
            foreach (string line in Lines(result.Output))
            {
                if (!withFlags) { layers.Add(line); continue; }
                // " + \tName": three flag characters (f frozen, + on or - off, l locked), a tab, the name.
                int tab = line.IndexOf('\t');
                string flags = tab > 0 ? line.Substring(0, tab) : "";
                string layerName = tab >= 0 ? line.Substring(tab + 1) : line;
                layers.Add(Json.Object("name", layerName, "on", flags.IndexOf('+') >= 0, "frozen", flags.IndexOf('f') >= 0, "locked", flags.IndexOf('l') >= 0));
            }
            return Json.Object("action", "layers", "file", Path.GetFileName(source), "count", layers.Count, "layers", layers, "warnings", Tail(result.Error));
        }

        private static object Search(string source, IDictionary<string, object> values)
        {
            string pattern = values.ContainsKey("pattern") ? Convert.ToString(values["pattern"]) : "";
            if (String.IsNullOrWhiteSpace(pattern)) throw new ToolException("Missing argument: pattern");
            List<string> args = new List<string>();
            if (Flag(values, "ignore_case", true)) args.Add("-i");
            if (Flag(values, "include_blocks", false)) args.Add("-b");
            args.Add("--");
            args.Add(pattern);
            args.Add(source);
            Run result = Start("dwggrep.exe", args, Path.GetTempPath(), DefaultTimeoutSeconds);
            // dwggrep exits 1 when nothing matches; that is an answer, not a failure. A file it could not read is reported
            // on its error output ("Error: Could not read DWG file ..."); warnings about unhandled objects are not errors.
            bool unreadable = result.Error.IndexOf("Error:", StringComparison.Ordinal) >= 0 || result.Error.IndexOf("ERROR", StringComparison.Ordinal) >= 0;
            if (result.ExitCode != 0 && !(result.ExitCode == 1 && !unreadable))
                throw new ToolException(Failure("The search", source, result));
            string prefix = source + " ";
            List<object> matches = new List<object>();
            bool truncated = false;
            foreach (string line in Lines(result.Output))
            {
                if (matches.Count >= MaxListed) { truncated = true; break; }
                matches.Add(line.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) ? line.Substring(prefix.Length) : line);
            }
            return Json.Object("action", "search", "file", Path.GetFileName(source), "count", matches.Count, "truncated", truncated, "matches", matches);
        }

        // ---- convert ----------------------------------------------------------------------------------------------

        private static object ConvertFile(string action, string source, IDictionary<string, object> values)
        {
            string folder = values.ContainsKey("output_dir") ? ValidFolder(System.Convert.ToString(values["output_dir"])) : Path.GetDirectoryName(source);
            int timeout = DefaultTimeoutSeconds;
            if (values.ContainsKey("timeout_seconds")) timeout = System.Convert.ToInt32(values["timeout_seconds"], System.Globalization.CultureInfo.InvariantCulture);
            string stem = Path.GetFileNameWithoutExtension(source);
            string target;
            Run result;
            if (action == "to_dxf")
            {
                target = NewName(folder, stem, ".dxf");
                result = Start("dwg2dxf.exe", new List<string> { "-o", target, source }, Path.GetTempPath(), timeout);
            }
            else if (action == "to_json")
            {
                target = NewName(folder, stem, ".json");
                result = Start("dwgread.exe", new List<string> { "-O", "json", "-o", target, source }, Path.GetTempPath(), timeout);
            }
            else if (action == "save_as_version")
            {
                string version = values.ContainsKey("version") ? System.Convert.ToString(values["version"]) : "";
                if (Array.IndexOf(Versions, version) < 0) throw new ToolException("save_as_version needs version: one of " + String.Join(", ", Versions) + ".");
                target = NewName(folder, stem + "-" + version, ".dwg");
                result = Start("dwgrewrite.exe", new List<string> { "--as", version, source, target }, Path.GetTempPath(), timeout);
            }
            else
            {
                return Thumbnail(source, folder, stem, timeout);
            }
            if (result.ExitCode != 0 || !File.Exists(target) || new FileInfo(target).Length == 0)
            {
                TryDelete(target);
                throw new ToolException(Failure("The conversion", source, result));
            }
            return Json.Object("action", action, "source", source, "output", target, "bytes", new FileInfo(target).Length,
                "warnings", Tail(result.Error), "note", FidelityNote);
        }

        // dwgbmp writes <name>.<bmp|wmf|png> into its working directory and exits 0 even when the file has no preview.
        // It runs in a fresh temporary folder, and the result is moved to a free name in the output folder.
        private static object Thumbnail(string source, string folder, string stem, int timeout)
        {
            string work = Path.Combine(Path.GetTempPath(), "SmartConnector-dwgbmp-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(work);
            try
            {
                Run result = Start("dwgbmp.exe", new List<string> { source }, work, timeout);
                if (result.ExitCode != 0) throw new ToolException(Failure("The thumbnail extraction", source, result));
                string[] produced = Directory.GetFiles(work);
                if (produced.Length == 0)
                    return Json.Object("action", "thumbnail", "source", source, "output", null, "message", "This drawing has no preview image.");
                string made = produced[0];
                string target = NewName(folder, stem + "-preview", Path.GetExtension(made));
                File.Move(made, target);
                return Json.Object("action", "thumbnail", "source", source, "output", target, "bytes", new FileInfo(target).Length);
            }
            finally
            {
                try { Directory.Delete(work, true); } catch (Exception) { }
            }
        }

        // ---- helpers ----------------------------------------------------------------------------------------------

        private static bool Flag(IDictionary<string, object> values, string key, bool fallback)
        {
            return values.ContainsKey(key) ? (bool)values[key] : fallback;
        }

        // The source must be an absolute path to an existing .dwg file. Names are checked here because the programs
        // are started with an argument list, never through a shell.
        private static string ValidSource(string path)
        {
            string full = FullPath(path, "file");
            if (!String.Equals(Path.GetExtension(full), ".dwg", StringComparison.OrdinalIgnoreCase))
                throw new ToolException("Only .dwg files are supported. For a DXF or a drawing open in AutoCAD use the AutoCAD tools.");
            if (!File.Exists(full)) throw new ToolException("The file was not found: " + Path.GetFileName(full));
            return full;
        }

        private static string ValidFolder(string path)
        {
            string full = FullPath(path, "output_dir");
            if (!Directory.Exists(full)) throw new ToolException("The output folder was not found: " + Path.GetFileName(full.TrimEnd('\\', '/')));
            return full;
        }

        private static string FullPath(string path, string argument)
        {
            if (String.IsNullOrWhiteSpace(path) || path.IndexOf('"') >= 0 || path.IndexOf('\0') >= 0)
                throw new ToolException("Invalid path: " + argument);
            // A drive path (C:\folder) or a network path (\\server\share\folder); not \folder and not C:folder.
            string root;
            try { root = Path.GetPathRoot(path); }
            catch (Exception) { throw new ToolException("Invalid path: " + argument); }
            if (!Path.IsPathRooted(path) || String.IsNullOrEmpty(root) || root.Length < 3 || path.StartsWith("-", StringComparison.Ordinal))
                throw new ToolException(argument + " must be an absolute path.");
            string full;
            try { full = Path.GetFullPath(path); }
            catch (Exception) { throw new ToolException("Invalid path: " + argument); }
            return full;
        }

        // A name that does not exist yet: stem.ext, then stem-1.ext, stem-2.ext. An existing file is never replaced.
        private static string NewName(string folder, string stem, string extension)
        {
            string candidate = Path.Combine(folder, stem + extension);
            for (int i = 1; File.Exists(candidate) || Directory.Exists(candidate); i++)
            {
                if (i > 999) throw new ToolException("Too many files named " + stem + " in the output folder.");
                candidate = Path.Combine(folder, stem + "-" + i + extension);
            }
            return candidate;
        }

        private static void TryDelete(string path)
        {
            try { if (File.Exists(path)) File.Delete(path); } catch (Exception) { }
        }

        private static IEnumerable<string> Lines(string text)
        {
            foreach (string line in text.Replace("\r\n", "\n").Split('\n'))
                if (line.Trim().Length > 0) yield return line.TrimEnd('\r');
        }

        private static string Tail(string text)
        {
            string trimmed = (text ?? "").Trim();
            return trimmed.Length <= MaxStderr ? trimmed : "..." + trimmed.Substring(trimmed.Length - MaxStderr);
        }

        // Messages carry the file name, never a folder path.
        private static string Failure(string what, string source, Run result)
        {
            string detail = Tail(result.Error);
            if (detail.Length == 0) detail = Tail(result.Output);
            if (detail.Length > 400) detail = detail.Substring(detail.Length - 400);
            detail = detail.Replace(source, Path.GetFileName(source));
            if (result.TimedOut) return what + " for " + Path.GetFileName(source) + " did not finish in time and was stopped.";
            return what + " failed for " + Path.GetFileName(source) + " (exit code " + result.ExitCode + "). The file may be damaged or use objects LibreDWG cannot read. " + detail;
        }

        private sealed class Run
        {
            internal int ExitCode;
            internal bool TimedOut;
            internal string Output = "";
            internal string Error = "";
        }

        // Starts one bundled program with an argument list (quoted for CreateProcess), no shell and no window. Output is
        // read while it runs so a full pipe cannot stall it, and the program is stopped when the time is up.
        private static Run Start(string program, List<string> arguments, string workingDirectory, int timeoutSeconds)
        {
            string folder = ToolFolder;
            string exe = Path.Combine(folder, program);
            if (!File.Exists(exe) || !File.Exists(Path.Combine(folder, "libredwg.dll")))
                throw new ToolException("The offline DWG tools are not installed. This connector was installed without the LibreDWG pack: update or repair Smart Connector from a release that includes it.");
            ProcessStartInfo info = new ProcessStartInfo(exe);
            info.Arguments = String.Join(" ", arguments.Select(a => Quote(a)).ToArray());
            info.WorkingDirectory = workingDirectory;
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;
            info.StandardOutputEncoding = Encoding.UTF8;
            info.StandardErrorEncoding = Encoding.UTF8;
            StringBuilder output = new StringBuilder();
            StringBuilder error = new StringBuilder();
            Run run = new Run();
            using (Process process = new Process())
            {
                process.StartInfo = info;
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) lock (output) { output.AppendLine(e.Data); } };
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) lock (error) { error.AppendLine(e.Data); } };
                process.Start();
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                if (!process.WaitForExit(Math.Min(timeoutSeconds, MaxTimeoutSeconds) * 1000))
                {
                    run.TimedOut = true;
                    try { process.Kill(); } catch (Exception) { }
                    process.WaitForExit();
                }
                else
                {
                    // The parameterless wait lets the asynchronous readers drain before the text is read.
                    process.WaitForExit();
                }
                run.ExitCode = run.TimedOut ? -1 : process.ExitCode;
            }
            lock (output) { run.Output = output.ToString(); }
            lock (error) { run.Error = error.ToString(); }
            return run;
        }

        // Quotes one argument for CreateProcess. Paths never contain a double quote (rejected above); a pattern may,
        // so backslashes before a quote are doubled and the quote is escaped.
        private static string Quote(string argument)
        {
            if (argument.Length > 0 && argument.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0) return argument;
            StringBuilder text = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in argument)
            {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { text.Append('\\', slashes * 2 + 1).Append('"'); }
                else { text.Append('\\', slashes).Append(c); }
                slashes = 0;
            }
            text.Append('\\', slashes * 2).Append('"');
            return text.ToString();
        }
    }
}
