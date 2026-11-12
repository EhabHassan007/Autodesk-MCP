using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;

namespace SmartConnector
{
    // The dry-run rule, enforced in code. A real (not dry) apply_plan or generate_detail run is refused unless a dry run of the SAME
    // plan on the SAME drawing passed earlier in this connector session, within a time window. "Same" is a hash of the drawing and the
    // plan. A successful real run uses the approval up, so an identical plan cannot be drawn twice by accident, and a changed plan needs
    // a new dry run. The guard proves a dry run happened; it cannot prove the user approved it, which stays the AI's duty (see the skills).
    internal static class DryRunGuard
    {
        internal static bool Enabled = true;                              // tests of other features switch it off
        internal static TimeSpan Window = TimeSpan.FromMinutes(30);
        internal static Func<DateTime> Now = delegate { return DateTime.UtcNow; };
        internal const string Refusal = "Run dry_run first and get the user's approval.";

        private static readonly object Gate = new object();
        private static readonly Dictionary<string, DateTime> Passed = new Dictionary<string, DateTime>();

        // Hash of the drawing and everything that decides what would be drawn.
        internal static string Key(string drawing, params object[] parts)
        {
            StringBuilder text = new StringBuilder((drawing ?? "").ToLowerInvariant());
            foreach (object part in parts) text.Append('\n').Append(Json.Serializer.Serialize(part));
            using (SHA256 sha = SHA256.Create())
            {
                byte[] hash = sha.ComputeHash(Encoding.UTF8.GetBytes(text.ToString()));
                StringBuilder hex = new StringBuilder();
                foreach (byte b in hash) hex.Append(b.ToString("x2"));
                return hex.ToString();
            }
        }

        internal static void Passed_(string key)
        {
            lock (Gate) { Prune(); Passed[key] = Now(); }
        }

        // Throws unless a dry run of this plan passed within the window.
        internal static void Require(string key)
        {
            if (!Enabled) return;
            lock (Gate)
            {
                Prune();
                if (!Passed.ContainsKey(key))
                    throw new ToolException(Refusal + " (No passed dry run of this exact plan on this drawing in the last " + ((int)Window.TotalMinutes).ToString(System.Globalization.CultureInfo.InvariantCulture) + " minutes.)");
            }
        }

        internal static void Used(string key)
        {
            lock (Gate) { Passed.Remove(key); }
        }

        internal static void Reset() { lock (Gate) { Passed.Clear(); } }

        private static void Prune()
        {
            DateTime limit = Now() - Window;
            List<string> old = new List<string>();
            foreach (KeyValuePair<string, DateTime> pair in Passed) if (pair.Value < limit) old.Add(pair.Key);
            foreach (string key in old) Passed.Remove(key);
        }
    }
}
