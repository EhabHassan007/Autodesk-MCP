using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

// Joining the team skill service: the administrator's enrollment file (or an open join with name and email), the device
// token kept encrypted for this Windows user (DPAPI), and the secure deletion of the plaintext. The C# port of
// Import-SkillServiceEnrollment, Register-SkillServiceDevice and Remove-PlaintextFileSecurely in Setup-BimCad.ps1 and of
// scripts\Initialize-SkillService.ps1 (which Skills Sync's own scripts read the result of: service.json).
namespace SmartConnector
{
    internal sealed partial class InstallEngine
    {
        private static string SkillServiceState { get { return Path.Combine(Paths.LocalAppData, "AutodeskMcpSkillCollection"); } }

        // The token as Windows PowerShell's ConvertFrom-SecureString writes it without a key: the DPAPI blob (current user)
        // of the token's UTF-16 text, in hex. PowerShell's ConvertTo-SecureString, as Skills Sync uses it, reads it back.
        internal static string ProtectToken(string token)
        {
            byte[] plain = Encoding.Unicode.GetBytes(token);
            try { return EngineText.Hex(ProtectedData.Protect(plain, null, DataProtectionScope.CurrentUser), false); }
            finally { Array.Clear(plain, 0, plain.Length); }
        }

        // Overwrite before deleting so the token does not stay in freed disk space. SSD wear levelling can still retain old
        // blocks, so deployment tools must not keep their own copies either.
        internal static void RemovePlaintextFileSecurely(string path)
        {
            FileInfo item = new FileInfo(path);
            if (item.IsReadOnly) item.IsReadOnly = false;
            long remaining = item.Length;
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.None))
            using (RandomNumberGenerator random = RandomNumberGenerator.Create())
            {
                byte[] buffer = new byte[4096];
                while (remaining > 0)
                {
                    int count = (int)Math.Min(remaining, buffer.Length);
                    random.GetBytes(buffer);
                    stream.Write(buffer, 0, count);
                    remaining -= count;
                }
                stream.Flush(true);
            }
            File.Delete(path);
        }

        // scripts\Initialize-SkillService.ps1: checks the enrollment and stores it for this Windows user.
        private string InitializeSkillService(string configPath)
        {
            OMap data = OJson.ReadFile(configPath) as OMap;
            if (data == null) throw new EngineException("The enrollment file is not valid JSON.");
            Uri uri;
            if (!Uri.TryCreate(PsJson.Text(data.Get("service_url")), UriKind.Absolute, out uri) || !EngineNet.IsSecure(uri) || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0)
                throw new EngineException("The skill service must use an HTTPS URL without embedded credentials.");
            string token = PsJson.Text(data.Get("device_token"));
            if (!Regex.IsMatch(token, "^[A-Za-z0-9_-]{40,100}$")) throw new EngineException("Invalid device enrollment token.");
            Directory.CreateDirectory(SkillServiceState);
            OMap service = new OMap();
            service.Set("service_url", uri.AbsoluteUri.TrimEnd('/'));
            service.Set("device_id", PsJson.Text(data.Get("device_id")));
            service.Set("protected_token", ProtectToken(token));
            File.WriteAllText(Path.Combine(SkillServiceState, "service.json"), OJson.Write(service) + "\r\n", EngineText.Utf8Bom);
            return "Central skill sharing is configured for this Windows user. No GitHub sign-in is needed.";
        }

        // Imports an enrollment file: the given one, or enrollment.json / skill-service-device.json from the folders. Returns
        // Enrolled, AlreadyEnrolled, Missing or Failed; failures are logged and never stop setup. The plaintext file is
        // always overwritten and deleted.
        private string ImportSkillServiceEnrollment(string root, string path, string[] searchDirectories)
        {
            string serviceConfig = Path.Combine(SkillServiceState, "service.json");
            bool explicitPath = !String.IsNullOrWhiteSpace(path);
            List<string> candidates = new List<string>();
            if (explicitPath) candidates.Add(path);
            else foreach (string directory in searchDirectories) foreach (string name in new[] { "enrollment.json", "skill-service-device.json" }) candidates.Add(Path.Combine(directory, name));
            string file = candidates.FirstOrDefault(File.Exists);
            if (file == null)
            {
                if (explicitPath) Step("[ENROLLMENT_MISSING] Enrollment file not found: " + path + ". Central skill sharing stays pending.");
                else if (File.Exists(serviceConfig))
                {
                    Step("[ENROLLMENT_UNCHANGED] No enrollment file supplied. The existing central skill sharing enrollment is kept.");
                    return "AlreadyEnrolled";
                }
                else Step("[ENROLLMENT_PENDING] No enrollment file supplied. Central skill sharing waits for administrator enrollment.");
                return "Missing";
            }

            Step("Importing central skill sharing enrollment from " + Path.GetFileName(file) + "...");
            string status = "Failed";
            try
            {
                // Parse here first: JSON errors must not quote the input, which would copy the token into setup.log.
                try { OJson.ReadFile(file); }
                catch (Exception) { throw new EngineException("The enrollment file is not valid JSON."); }
                string output = InitializeSkillService(file);
                if (!File.Exists(serviceConfig)) throw new EngineException("The initializer did not write service.json.");
                Step(output);
                Step("[ENROLLMENT_OK] Central skill sharing is enrolled for this Windows user.");
                status = "Enrolled";
            }
            catch (Exception exception)
            {
                Step("[ENROLLMENT_FAILED] " + exception.Message + " Central skill sharing stays pending. Ask your administrator for a new enrollment file.");
            }
            finally
            {
                // The plaintext token must not stay on disk, even when the import failed.
                try
                {
                    RemovePlaintextFileSecurely(file);
                    Step("[ENROLLMENT_FILE_REMOVED] The plaintext enrollment file was overwritten and deleted.");
                }
                catch (Exception exception)
                {
                    Step("[ENROLLMENT_FILE_NOT_REMOVED] Delete the plaintext enrollment file manually: " + file + " (" + exception.Message + ")");
                }
            }
            return status;
        }

        // Joining the team: this PC sends the name and email typed in the setup window to the skill service (no team code
        // needed); the service answers with this PC's own device token, which is stored like an administrator's enrollment
        // file (so the same logging and secure deletion apply).
        private string RegisterSkillServiceDevice(string root)
        {
            string joinConfigPath = Path.Combine(Paths.Root, "installer", "team-join.json");
            string state = SkillServiceState;
            if (File.Exists(Path.Combine(state, "service.json")))
            {
                Step("[ENROLLMENT_UNCHANGED] This PC already belongs to the team skill service.");
                return "AlreadyEnrolled";
            }
            try
            {
                // Joining needs no team code. The setup window writes the service address into team-join.json; without
                // the file (a scripted install) the built-in address is used. A code in an older TEAM build is still sent.
                OMap join;
                if (!File.Exists(joinConfigPath)) { join = new OMap(); join.Set("service_url", TeamJoin.ServiceUrl); }
                else
                {
                    try { join = OJson.ReadFile(joinConfigPath) as OMap; if (join == null) throw new FormatException(); }
                    catch (Exception) { throw new EngineException("The team join file in this installer is damaged."); }
                }
                Uri uri;
                if (!Uri.TryCreate(PsJson.Text(join.Get("service_url")), UriKind.Absolute, out uri) || !EngineNet.IsSecure(uri) || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0)
                    throw new EngineException("The team join file has an invalid service address.");
                string versionPath = Path.Combine(root, "VERSION");
                string version = File.Exists(versionPath) ? File.ReadAllText(versionPath).Trim() : "unknown";
                OMap profile = new OMap();
                profile.Set("name", _o.JoinName.Trim());
                profile.Set("email", _o.JoinEmail.Trim());
                profile.Set("pc_name", Env.Variable("COMPUTERNAME"));
                profile.Set("windows_user", Env.Variable("USERNAME"));
                profile.Set("connector_version", version);
                if (Regex.IsMatch(_o.TermsVersion, "^[0-9A-Za-z.-]{1,20}$")) profile.Set("terms_version", _o.TermsVersion);
                byte[] body = EngineText.Utf8.GetBytes(OJson.Write(profile, true));
                Step("Joining the team skill service as " + _o.JoinName.Trim() + "...");
                OMap device = PostEnrollment(new Uri(uri.AbsoluteUri.TrimEnd('/') + "/v1/enroll"), PsJson.Text(join.Get("join_code")), version, body);
                Directory.CreateDirectory(state);
                string file = Path.Combine(state, "enrollment-" + Guid.NewGuid().ToString("N") + ".json");
                OMap enrollment = new OMap();
                enrollment.Set("service_url", uri.AbsoluteUri.TrimEnd('/'));
                enrollment.Set("device_id", PsJson.Text(device.Get("device_id")));
                enrollment.Set("device_token", PsJson.Text(device.Get("device_token")));
                File.WriteAllText(file, OJson.Write(enrollment) + "\r\n", EngineText.Utf8Bom);
                device = null;
                // Reuses the admin-file path: DPAPI import, [ENROLLMENT_*] logging and secure deletion.
                return ImportSkillServiceEnrollment(root, file, new string[0]);
            }
            catch (Exception exception)
            {
                Step("[ENROLLMENT_FAILED] " + exception.Message + " Installation continues without central skill sharing.");
                return "Failed";
            }
            finally
            {
                // Don't leave the team code in the permanent install; the installer itself is the only copy.
                try
                {
                    string installedCopy = Path.Combine(_o.RepositoryPath, "installer", "team-join.json");
                    if (File.Exists(installedCopy)) File.Delete(installedCopy);
                }
                catch (Exception) { }
            }
        }

        // POST /v1/enroll. The service's error detail never contains secrets; it explains validation problems.
        private static OMap PostEnrollment(Uri uri, string joinCode, string version, byte[] body)
        {
            EngineNet.PrepareTls();
            try
            {
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(uri);
                request.Method = "POST";
                request.UserAgent = "Autodesk-MCP-Connector/" + version;
                request.ContentType = "application/json; charset=utf-8";
                if (!String.IsNullOrWhiteSpace(joinCode)) request.Headers["Authorization"] = "Bearer " + joinCode;
                request.Headers["X-Connector-Version"] = version;
                request.Timeout = 60000;
                request.ServicePoint.Expect100Continue = false;
                request.ContentLength = body.Length;
                using (Stream stream = request.GetRequestStream()) stream.Write(body, 0, body.Length);
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                using (StreamReader reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
                {
                    OMap device = OJson.Parse(reader.ReadToEnd()) as OMap;
                    if (device == null) throw new EngineException("The team skill service sent an unreadable answer.");
                    return device;
                }
            }
            catch (WebException exception)
            {
                HttpWebResponse response = exception.Response as HttpWebResponse;
                int code = response == null ? 0 : (int)response.StatusCode;
                string detail = "";
                if (response != null)
                {
                    try
                    {
                        using (StreamReader reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
                        {
                            OMap error = OJson.Parse(reader.ReadToEnd()) as OMap;
                            if (error != null) detail = PsJson.Text(error.Get("detail"));
                        }
                    }
                    catch (Exception) { }
                }
                string reason;
                if (code == 0) reason = "The team skill service could not be reached. Check the internet connection and run setup again.";
                else if (code == 403) reason = "The team join code was not accepted; this installer may be out of date. Ask your administrator for the current team installer.";
                else if (code == 429) reason = "Too many join attempts from this network. Wait an hour and run setup again.";
                else reason = detail.Length > 0 ? detail : "The team skill service refused the request (HTTP " + code + ").";
                throw new EngineException(reason);
            }
        }
    }
}
