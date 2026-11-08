using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

// Helpers shared by the Skills Sync commands (SmartConnector.exe skills ...): console output, option parsing, the
// JSON text PowerShell's ConvertTo-Json writes, the encrypted device token, HTTPS requests and child programs.
// The commands themselves are the C# port of release-preparation\beta17\source\runtime\scripts\*.ps1; see SkillsCommands.cs.
namespace SmartConnector
{
    // Standard output and error of the skills commands. The windows read the output through a pipe as UTF-8; a
    // console window shows it as it is. Written line by line, so a long sync shows progress as it happens.
    internal static class SkillConsole
    {
        private static StreamWriter _out, _error;

        private static StreamWriter Open(Stream stream)
        {
            StreamWriter writer = new StreamWriter(stream, new UTF8Encoding(false));
            writer.AutoFlush = true;
            writer.NewLine = Environment.NewLine;
            return writer;
        }

        internal static void Out(string text)
        {
            if (_out == null) _out = Open(Console.OpenStandardOutput());
            try { _out.WriteLine(text); } catch (Exception) { }  // no console to write to (started without pipes): nothing to show
        }

        internal static void Err(string text)
        {
            if (_error == null) _error = Open(Console.OpenStandardError());
            try { _error.WriteLine(text); } catch (Exception) { }
        }
    }

    // Where a command's output goes. When a list is given (Skills Sync collects the lines for its log and its
    // result file) both normal output and warnings are added to it, as `3>&1` did in the PowerShell runner.
    // Without a list, output goes to standard output and warnings to standard error as "WARNING: ...".
    internal sealed class SkillSink
    {
        private readonly List<string> _capture;
        internal SkillSink(List<string> capture) { _capture = capture; }
        internal void Out(string text) { if (_capture != null) _capture.Add(text); else SkillConsole.Out(text); }
        internal void Warn(string text) { if (_capture != null) _capture.Add(text); else SkillConsole.Err("WARNING: " + text); }
    }

    // --name value, --name (a flag) and repeated --name value for lists, matched without regard to case.
    internal sealed class SkillOptions
    {
        private readonly Dictionary<string, List<string>> _values = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);

        internal SkillOptions(string[] args)
        {
            for (int i = 0; i < args.Length; i++)
            {
                if (!args[i].StartsWith("--", StringComparison.Ordinal)) continue;
                string name = args[i].Substring(2);
                bool hasValue = i + 1 < args.Length && !args[i + 1].StartsWith("--", StringComparison.Ordinal);
                List<string> list;
                if (!_values.TryGetValue(name, out list)) { list = new List<string>(); _values[name] = list; }
                list.Add(hasValue ? args[++i] : "");
            }
        }

        internal bool Has(string name) { return _values.ContainsKey(name); }

        // The last value given, or the default when the option is absent or empty.
        internal string Get(string name, string fallback)
        {
            List<string> list;
            if (!_values.TryGetValue(name, out list) || list.Count == 0 || list[list.Count - 1].Length == 0) return fallback;
            return list[list.Count - 1];
        }

        internal string[] List(string name)
        {
            List<string> list;
            return _values.TryGetValue(name, out list) ? list.Where(v => v.Length > 0).ToArray() : new string[0];
        }

        // A switch parameter: present without a value, or with true/false.
        internal bool Flag(string name)
        {
            List<string> list;
            if (!_values.TryGetValue(name, out list) || list.Count == 0) return false;
            string last = list[list.Count - 1];
            return !String.Equals(last, "false", StringComparison.OrdinalIgnoreCase) && last != "0";
        }

        // A parameter with a ValidateSet: case-insensitive, and the listed spelling is used.
        internal string Choice(string name, string[] choices, string fallback)
        {
            string value = Get(name, fallback);
            foreach (string choice in choices)
                if (String.Equals(choice, value, StringComparison.OrdinalIgnoreCase)) return choice;
            throw new ArgumentException("The argument \"" + value + "\" does not belong to the set \"" + String.Join(",", choices) + "\" specified by the ValidateSet attribute of --" + name + ".");
        }
    }

    // The JSON text Windows PowerShell 5.1 writes with ConvertTo-Json: four-space indent, two spaces after the
    // colon, <, >, & and ' escaped. The windows and the log show these files; PowerShell and this program read them.
    internal static class PsJsonText
    {
        internal static string Pretty(object value)
        {
            StringBuilder text = new StringBuilder();
            Write(text, value, 0);
            return text.ToString();
        }

        internal static string Compact(object value)
        {
            StringBuilder text = new StringBuilder();
            WriteCompact(text, value);
            return text.ToString();
        }

        private static IEnumerable<object> Items(object value)
        {
            IEnumerable sequence = value as IEnumerable;
            if (sequence == null || value is string || value is IDictionary<string, object>) return null;
            return sequence.Cast<object>();
        }

        private static void Write(StringBuilder text, object value, int level)
        {
            string indent = new String(' ', 4 * (level + 1)), outer = new String(' ', 4 * level);
            IDictionary<string, object> dictionary = value as IDictionary<string, object>;
            IEnumerable<object> items = Items(value);
            if (dictionary != null)
            {
                text.Append("{\r\n");
                bool first = true;
                foreach (KeyValuePair<string, object> pair in dictionary)
                {
                    if (!first) text.Append(",\r\n");
                    first = false;
                    text.Append(indent);
                    Quote(text, pair.Key);
                    text.Append(":  ");
                    Write(text, pair.Value, level + 1);
                }
                text.Append("\r\n").Append(outer).Append("}");
            }
            else if (items != null)
            {
                text.Append("[\r\n");
                bool first = true;
                foreach (object item in items)
                {
                    if (!first) text.Append(",\r\n");
                    first = false;
                    text.Append(indent);
                    Write(text, item, level + 1);
                }
                text.Append("\r\n");
                text.Append(outer).Append("]");
            }
            else Scalar(text, value);
        }

        private static void WriteCompact(StringBuilder text, object value)
        {
            IDictionary<string, object> dictionary = value as IDictionary<string, object>;
            IEnumerable<object> items = Items(value);
            if (dictionary != null)
            {
                text.Append("{");
                bool first = true;
                foreach (KeyValuePair<string, object> pair in dictionary)
                {
                    if (!first) text.Append(",");
                    first = false;
                    Quote(text, pair.Key);
                    text.Append(":");
                    WriteCompact(text, pair.Value);
                }
                text.Append("}");
            }
            else if (items != null)
            {
                text.Append("[");
                bool first = true;
                foreach (object item in items)
                {
                    if (!first) text.Append(",");
                    first = false;
                    WriteCompact(text, item);
                }
                text.Append("]");
            }
            else Scalar(text, value);
        }

        private static void Scalar(StringBuilder text, object value)
        {
            if (value == null) text.Append("null");
            else if (value is bool) text.Append((bool)value ? "true" : "false");
            else if (value is string) Quote(text, (string)value);
            else if (value is IFormattable) text.Append(((IFormattable)value).ToString(null, CultureInfo.InvariantCulture));
            else Quote(text, value.ToString());
        }

        private static void Quote(StringBuilder text, string value)
        {
            text.Append('"');
            foreach (char c in value)
            {
                switch (c)
                {
                    case '"': text.Append("\\\""); break;
                    case '\\': text.Append("\\\\"); break;
                    case '\n': text.Append("\\n"); break;
                    case '\r': text.Append("\\r"); break;
                    case '\t': text.Append("\\t"); break;
                    case '\b': text.Append("\\b"); break;
                    case '\f': text.Append("\\f"); break;
                    case '<': case '>': case '&': case '\'':
                        text.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture)); break;
                    default:
                        if (c < ' ') text.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                        else text.Append(c);
                        break;
                }
            }
            text.Append('"');
        }
    }

    // File and folder helpers with the behaviour of the PowerShell cmdlets the scripts used.
    internal static class SkillFiles
    {
        internal static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);
        // Set-Content -Encoding UTF8 in Windows PowerShell writes a byte order mark.
        internal static readonly UTF8Encoding Utf8Bom = new UTF8Encoding(true);

        internal static bool IsLink(string path)
        {
            return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
        }

        // Copy-Item -Recurse -Force of a folder to a new folder name.
        internal static void CopyFolder(string source, string destination)
        {
            Directory.CreateDirectory(destination);
            foreach (string file in Directory.GetFiles(source)) File.Copy(file, Path.Combine(destination, Path.GetFileName(file)), true);
            foreach (string folder in Directory.GetDirectories(source)) CopyFolder(folder, Path.Combine(destination, Path.GetFileName(folder)));
        }

        // Remove-Item -Recurse -Force: read-only files (a git checkout has them) are made writable first.
        internal static void DeleteFolder(string path)
        {
            if (!Directory.Exists(path)) return;
            foreach (string file in Directory.GetFiles(path, "*", SearchOption.AllDirectories))
            {
                try { File.SetAttributes(file, FileAttributes.Normal); } catch (Exception) { }
            }
            Directory.Delete(path, true);
        }

        // Move-Item -Force over an existing file.
        internal static void MoveOver(string from, string to)
        {
            if (File.Exists(to)) File.Delete(to);
            File.Move(from, to);
        }

        internal static void WriteText(string path, string text, Encoding encoding)
        {
            File.WriteAllText(path, text, encoding);
        }

        // Get-Content -Raw (UTF-8 with or without a byte order mark).
        internal static string ReadText(string path)
        {
            return File.ReadAllText(path, Encoding.UTF8);
        }

        // Get-Content -Raw | ConvertFrom-Json.
        internal static object ReadJson(string path)
        {
            return Json.Serializer.DeserializeObject(ReadText(path));
        }

        // The log files append "[<ISO time>] text" with CRLF line ends.
        internal static string Stamp { get { return DateTime.Now.ToString("o", CultureInfo.InvariantCulture); } }

        // A hashtable of strings saved with ConvertTo-Json (the ledgers): property name to text.
        internal static Dictionary<string, string> ReadStringMap(string path)
        {
            Dictionary<string, string> map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            IDictionary<string, object> values = ReadJson(path) as IDictionary<string, object>;
            if (values != null)
                foreach (KeyValuePair<string, object> pair in values)
                    map[pair.Key] = pair.Value == null ? "" : Convert.ToString(pair.Value, CultureInfo.InvariantCulture);
            return map;
        }

        // The lines of a text file as Get-Content returns them.
        internal static string[] ReadLines(string path)
        {
            return File.ReadAllLines(path, Encoding.UTF8);
        }

        // `Join-Path`, `New-Item -ItemType Directory`.
        internal static string Folder(string path)
        {
            Directory.CreateDirectory(path);
            return path;
        }
    }

    // The device token is stored encrypted for this Windows user (DPAPI), in the same text form that
    // ConvertFrom-SecureString writes and ConvertTo-SecureString reads, so the PowerShell and the compiled
    // versions read each other's service.json: the hex digits of the protected UTF-16 text.
    internal static class SkillSecrets
    {
        internal static string Protect(string secret)
        {
            byte[] plain = Encoding.Unicode.GetBytes(secret);
            try
            {
                byte[] protectedBytes = ProtectedData.Protect(plain, null, DataProtectionScope.CurrentUser);
                StringBuilder hex = new StringBuilder();
                foreach (byte b in protectedBytes) hex.Append(b.ToString("x2", CultureInfo.InvariantCulture));
                return hex.ToString();
            }
            finally { Array.Clear(plain, 0, plain.Length); }
        }

        internal static string Unprotect(string hex)
        {
            if (hex == null || hex.Length == 0 || hex.Length % 2 != 0) throw new FormatException("The protected token is not valid.");
            byte[] bytes = new byte[hex.Length / 2];
            for (int i = 0; i < bytes.Length; i++) bytes[i] = Byte.Parse(hex.Substring(i * 2, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            byte[] plain = ProtectedData.Unprotect(bytes, null, DataProtectionScope.CurrentUser);
            try { return Encoding.Unicode.GetString(plain); }
            finally { Array.Clear(plain, 0, plain.Length); }
        }
    }

    // The enrolled skill service: its address and this PC's token. The address must be HTTPS without credentials,
    // query or fragment. For the automated tests only, a loopback address over plain HTTP is also accepted when
    // SMART_CONNECTOR_ALLOW_LOOPBACK_HTTP=1 is set: that traffic never leaves the computer.
    internal sealed class SkillService
    {
        internal Uri Address;
        internal string Base { get { return Address.AbsoluteUri.TrimEnd('/'); } }

        internal static bool AllowedAddress(Uri uri)
        {
            if (uri == null || !uri.IsAbsoluteUri) return false;
            if (uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0) return false;
            if (uri.Scheme == "https") return true;
            return uri.Scheme == "http" && uri.IsLoopback && Environment.GetEnvironmentVariable("SMART_CONNECTOR_ALLOW_LOOPBACK_HTTP") == "1";
        }

        internal static Uri ParseAddress(object value, string message)
        {
            Uri uri;
            if (!Uri.TryCreate(PsJson.Text(value), UriKind.Absolute, out uri) || !AllowedAddress(uri)) throw new InvalidOperationException(message);
            return uri;
        }

        // service.json written by Initialize-SkillService: service_url, device_id and protected_token.
        internal static SkillService Read(string stateRoot, out string token)
        {
            object config = SkillFiles.ReadJson(Path.Combine(stateRoot, "service.json"));
            SkillService service = new SkillService();
            service.Address = ParseAddress(PsJson.Value(config, "service_url"), "Invalid skill service URL.");
            token = SkillSecrets.Unprotect(PsJson.Text(PsJson.Value(config, "protected_token")));
            return service;
        }

        internal static string ConnectorVersion(string repositoryRoot)
        {
            string path = Path.Combine(repositoryRoot ?? "", "VERSION");
            return repositoryRoot != null && File.Exists(path) ? SkillFiles.ReadText(path).Trim() : "unknown";
        }
    }

    // HTTPS requests with Invoke-RestMethod's behaviour: JSON answers are parsed, any other status than 2xx throws
    // the WebException with its usual message ("The remote server returned an error: (503) ...").
    internal static class SkillHttp
    {
        private static bool _prepared;

        // A program without an app.config uses the .NET Framework 4.0 defaults, which offer TLS 1.0 only. GitHub and
        // the skill service require TLS 1.2 or newer, so ask for them (TLS 1.3 where this Windows has it).
        private static void Prepare()
        {
            if (_prepared) return;
            _prepared = true;
            foreach (int protocols in new[] { 12288 | 3072 | 768, 3072 | 768, 3072 })
            {
                try { ServicePointManager.SecurityProtocol = (SecurityProtocolType)protocols; return; }
                catch (NotSupportedException) { }
                catch (ArgumentException) { }
            }
        }

        // method, headers and body as Invoke-RestMethod takes them. Returns the parsed JSON (null for an empty answer).
        internal static object Request(string method, string uri, IDictionary<string, string> headers, string userAgent, string contentType, byte[] body, int timeoutSeconds)
        {
            Prepare();
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(uri);
            request.Method = method;
            request.Timeout = timeoutSeconds * 1000;
            request.ReadWriteTimeout = timeoutSeconds * 1000;
            if (userAgent != null) request.UserAgent = userAgent;
            if (headers != null)
            {
                foreach (KeyValuePair<string, string> header in headers)
                {
                    if (String.Equals(header.Key, "Accept", StringComparison.OrdinalIgnoreCase)) request.Accept = header.Value;
                    else if (String.Equals(header.Key, "User-Agent", StringComparison.OrdinalIgnoreCase)) request.UserAgent = header.Value;
                    else request.Headers[header.Key] = header.Value;
                }
            }
            if (body != null)
            {
                request.ContentType = contentType;
                request.ContentLength = body.Length;
                using (Stream stream = request.GetRequestStream()) stream.Write(body, 0, body.Length);
            }
            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
            {
                string text = ReadBody(response);
                if (text.Trim().Length == 0) return null;
                try { return Json.Serializer.DeserializeObject(text); }
                catch (Exception) { return text; }
            }
        }

        // JSON is UTF-8 unless the answer says otherwise; HttpWebResponse would otherwise assume ISO-8859-1.
        private static string ReadBody(HttpWebResponse response)
        {
            Encoding encoding = Encoding.UTF8;
            Match charset = Regex.Match(response.ContentType ?? "", @"charset\s*=\s*""?([A-Za-z0-9_\-]+)", RegexOptions.IgnoreCase);
            if (charset.Success)
            {
                try { encoding = Encoding.GetEncoding(charset.Groups[1].Value); } catch (ArgumentException) { }
            }
            using (StreamReader reader = new StreamReader(response.GetResponseStream(), encoding)) return reader.ReadToEnd();
        }

        internal static int StatusOf(Exception exception)
        {
            WebException web = exception as WebException;
            HttpWebResponse response = web == null ? null : web.Response as HttpWebResponse;
            return response == null ? 0 : (int)response.StatusCode;
        }
    }

    internal sealed class ProcessResult
    {
        internal int ExitCode;
        internal string StdOut = "", StdErr = "";

        // stdout then stderr, the lines `& program 2>&1` collects.
        internal string[] Lines
        {
            get
            {
                // A trailing newline does not make an extra line.
                List<string> result = new List<string>();
                foreach (string block in new[] { StdOut, StdErr })
                {
                    string[] parts = block.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None);
                    int count = parts.Length > 0 && parts[parts.Length - 1].Length == 0 ? parts.Length - 1 : parts.Length;
                    for (int i = 0; i < count; i++) result.Add(parts[i]);
                }
                return result.ToArray();
            }
        }
    }

    // Child programs (git, powershell) started from a known path, with their output read.
    internal static class SkillProcess
    {
        // Get-Command: the first match on PATH (with the PATHEXT extensions on Windows).
        internal static string Find(string name)
        {
            string[] extensions = new[] { "" };
            if (Path.DirectorySeparatorChar == '\\')
            {
                string pathExt = Environment.GetEnvironmentVariable("PATHEXT");
                extensions = (String.IsNullOrEmpty(pathExt) ? ".COM;.EXE;.BAT;.CMD" : pathExt).Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries);
                if (Path.HasExtension(name)) extensions = new[] { "" }.Concat(extensions).ToArray();
            }
            foreach (string directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
            {
                if (directory.Trim().Length == 0) continue;
                foreach (string extension in extensions)
                {
                    try
                    {
                        string candidate = Path.Combine(directory.Trim().Trim('"'), name + extension);
                        if (File.Exists(candidate)) return candidate;
                    }
                    catch (ArgumentException) { }
                }
            }
            return null;
        }

        // One argument as CommandLineToArgvW reads it back.
        internal static string Quote(string argument)
        {
            if (argument.Length > 0 && argument.IndexOfAny(new[] { ' ', '\t', '"', '\n' }) < 0) return argument;
            StringBuilder text = new StringBuilder("\"");
            int backslashes = 0;
            foreach (char c in argument)
            {
                if (c == '\\') { backslashes++; continue; }
                if (c == '"') { text.Append('\\', backslashes * 2 + 1).Append('"'); }
                else { text.Append('\\', backslashes).Append(c); }
                backslashes = 0;
            }
            text.Append('\\', backslashes * 2).Append('"');
            return text.ToString();
        }

        internal static string CommandLine(IEnumerable<string> arguments)
        {
            return String.Join(" ", arguments.Select(Quote).ToArray());
        }

        // Runs the program with the given text on its standard input, in a hidden window, and waits for it.
        internal static ProcessResult Run(string file, string[] arguments, string input, IDictionary<string, string> environment, string workingDirectory)
        {
            System.Diagnostics.ProcessStartInfo info = new System.Diagnostics.ProcessStartInfo(file, CommandLine(arguments));
            info.UseShellExecute = false; info.CreateNoWindow = true;
            info.RedirectStandardOutput = true; info.RedirectStandardError = true; info.RedirectStandardInput = true;
            info.StandardOutputEncoding = Encoding.UTF8; info.StandardErrorEncoding = Encoding.UTF8;
            if (workingDirectory != null) info.WorkingDirectory = workingDirectory;
            if (environment != null) foreach (KeyValuePair<string, string> pair in environment) info.EnvironmentVariables[pair.Key] = pair.Value;
            ProcessResult result = new ProcessResult();
            using (System.Diagnostics.Process process = System.Diagnostics.Process.Start(info))
            {
                // Both pipes are read at once so a chatty program never blocks on a full pipe.
                System.Threading.Tasks.Task<string> output = process.StandardOutput.ReadToEndAsync();
                System.Threading.Tasks.Task<string> error = process.StandardError.ReadToEndAsync();
                try { if (input != null) process.StandardInput.Write(input); process.StandardInput.Close(); }
                catch (IOException) { }
                process.WaitForExit();
                result.StdOut = output.Result; result.StdErr = error.Result;
                result.ExitCode = process.ExitCode;
            }
            return result;
        }
    }
}
