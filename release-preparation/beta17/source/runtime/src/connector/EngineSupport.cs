using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

// Helpers of the install engine (EngineCore.cs and the other Engine*.cs files): JSON that keeps property order,
// and the small file and text rules the PowerShell setup script relied on.
namespace SmartConnector
{
    // A JSON object whose properties keep their order and whose names match without regard to case, like the
    // objects ConvertFrom-Json returns. Claude Desktop's config and the update state are edited through it so
    // everything the connector does not own is written back exactly as it was read.
    internal sealed class OMap
    {
        private readonly List<string> _keys = new List<string>();
        private readonly List<object> _values = new List<object>();

        internal int Count { get { return _keys.Count; } }
        internal string KeyAt(int index) { return _keys[index]; }
        internal object ValueAt(int index) { return _values[index]; }

        internal int IndexOf(string name)
        {
            for (int i = 0; i < _keys.Count; i++) if (String.Equals(_keys[i], name, StringComparison.OrdinalIgnoreCase)) return i;
            return -1;
        }

        internal bool Has(string name) { return IndexOf(name) >= 0; }

        internal object Get(string name)
        {
            int index = IndexOf(name);
            return index < 0 ? null : _values[index];
        }

        // An existing property keeps the spelling it has; a new one is added at the end.
        internal void Set(string name, object value)
        {
            int index = IndexOf(name);
            if (index < 0) { _keys.Add(name); _values.Add(value); }
            else _values[index] = value;
        }

        internal bool Remove(string name)
        {
            int index = IndexOf(name);
            if (index < 0) return false;
            _keys.RemoveAt(index); _values.RemoveAt(index);
            return true;
        }
    }

    // A JSON number, kept as written so rewriting a file never changes a value.
    internal sealed class JsonRaw
    {
        internal readonly string Text;
        internal JsonRaw(string text) { Text = text; }
    }

    internal static class OJson
    {
        // Parses one JSON document: OMap, List<object>, string, JsonRaw, bool or null. Throws FormatException; the
        // message never quotes the input, which can hold a token.
        internal static object Parse(string text)
        {
            if (text == null) throw new FormatException("The JSON is empty.");
            int position = 0;
            SkipSpace(text, ref position);
            if (position >= text.Length) throw new FormatException("The JSON is empty.");
            object value = ReadValue(text, ref position, 0);
            SkipSpace(text, ref position);
            if (position < text.Length) throw new FormatException("The JSON is not valid.");
            return value;
        }

        internal static object ReadFile(string path) { return Parse(File.ReadAllText(path)); }

        private static void SkipSpace(string text, ref int position)
        {
            while (position < text.Length && (text[position] == ' ' || text[position] == '\t' || text[position] == '\r' || text[position] == '\n' || text[position] == '﻿')) position++;
        }

        private static FormatException Bad() { return new FormatException("The JSON is not valid."); }

        private static object ReadValue(string text, ref int position, int depth)
        {
            if (depth > 200) throw Bad();
            SkipSpace(text, ref position);
            if (position >= text.Length) throw Bad();
            char c = text[position];
            if (c == '{')
            {
                position++;
                OMap map = new OMap();
                SkipSpace(text, ref position);
                if (position < text.Length && text[position] == '}') { position++; return map; }
                while (true)
                {
                    SkipSpace(text, ref position);
                    if (position >= text.Length || text[position] != '"') throw Bad();
                    string key = ReadString(text, ref position);
                    SkipSpace(text, ref position);
                    if (position >= text.Length || text[position] != ':') throw Bad();
                    position++;
                    object value = ReadValue(text, ref position, depth + 1);
                    // A repeated name replaces the earlier value, as it does in PowerShell.
                    map.Set(key, value);
                    SkipSpace(text, ref position);
                    if (position >= text.Length) throw Bad();
                    if (text[position] == ',') { position++; continue; }
                    if (text[position] == '}') { position++; return map; }
                    throw Bad();
                }
            }
            if (c == '[')
            {
                position++;
                List<object> list = new List<object>();
                SkipSpace(text, ref position);
                if (position < text.Length && text[position] == ']') { position++; return list; }
                while (true)
                {
                    list.Add(ReadValue(text, ref position, depth + 1));
                    SkipSpace(text, ref position);
                    if (position >= text.Length) throw Bad();
                    if (text[position] == ',') { position++; continue; }
                    if (text[position] == ']') { position++; return list; }
                    throw Bad();
                }
            }
            if (c == '"') return ReadString(text, ref position);
            if (String.CompareOrdinal(text, position, "true", 0, 4) == 0) { position += 4; return true; }
            if (String.CompareOrdinal(text, position, "false", 0, 5) == 0) { position += 5; return false; }
            if (String.CompareOrdinal(text, position, "null", 0, 4) == 0) { position += 4; return null; }
            int start = position;
            while (position < text.Length && "+-0123456789.eE".IndexOf(text[position]) >= 0) position++;
            if (position == start) throw Bad();
            double ignored;
            string number = text.Substring(start, position - start);
            if (!Double.TryParse(number, NumberStyles.Float, CultureInfo.InvariantCulture, out ignored)) throw Bad();
            return new JsonRaw(number);
        }

        private static string ReadString(string text, ref int position)
        {
            StringBuilder result = new StringBuilder();
            position++;   // opening quote
            while (position < text.Length)
            {
                char c = text[position++];
                if (c == '"') return result.ToString();
                if (c != '\\') { result.Append(c); continue; }
                if (position >= text.Length) break;
                char escape = text[position++];
                switch (escape)
                {
                    case '"': result.Append('"'); break;
                    case '\\': result.Append('\\'); break;
                    case '/': result.Append('/'); break;
                    case 'b': result.Append('\b'); break;
                    case 'f': result.Append('\f'); break;
                    case 'n': result.Append('\n'); break;
                    case 'r': result.Append('\r'); break;
                    case 't': result.Append('\t'); break;
                    case 'u':
                        if (position + 4 > text.Length) throw Bad();
                        int code;
                        if (!Int32.TryParse(text.Substring(position, 4), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out code)) throw Bad();
                        result.Append((char)code);
                        position += 4;
                        break;
                    default: throw Bad();
                }
            }
            throw Bad();
        }

        // JSON text in the shape ConvertTo-Json writes: indented by four spaces, or on one line when compact.
        internal static string Write(object value, bool compact)
        {
            StringBuilder text = new StringBuilder();
            WriteValue(text, value, 0, compact);
            return text.ToString();
        }

        internal static string Write(object value) { return Write(value, false); }

        private static void WriteString(StringBuilder text, string value)
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
                    default:
                        if (c < ' ' || c == (char)0x2028 || c == (char)0x2029) text.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                        else text.Append(c);
                        break;
                }
            }
            text.Append('"');
        }

        private static void WriteValue(StringBuilder text, object value, int depth, bool compact)
        {
            string indent = compact ? "" : new string(' ', 4 * (depth + 1));
            string closing = compact ? "" : new string(' ', 4 * depth);
            string newline = compact ? "" : "\n";
            if (value == null) { text.Append("null"); return; }
            if (value is bool) { text.Append((bool)value ? "true" : "false"); return; }
            string s = value as string;
            if (s != null) { WriteString(text, s); return; }
            JsonRaw raw = value as JsonRaw;
            if (raw != null) { text.Append(raw.Text); return; }
            if (value is double) { text.Append(((double)value).ToString("R", CultureInfo.InvariantCulture)); return; }
            if (value is int || value is long || value is short || value is byte || value is uint || value is ulong || value is decimal) { text.Append(Convert.ToString(value, CultureInfo.InvariantCulture)); return; }
            OMap map = value as OMap;
            IDictionary<string, object> dictionary = value as IDictionary<string, object>;
            if (map != null || dictionary != null)
            {
                int count = map != null ? map.Count : dictionary.Count;
                if (count == 0) { text.Append("{}"); return; }
                text.Append("{").Append(newline);
                int index = 0;
                IEnumerable<KeyValuePair<string, object>> pairs = map != null ? Pairs(map) : dictionary;
                foreach (KeyValuePair<string, object> pair in pairs)
                {
                    text.Append(indent);
                    WriteString(text, pair.Key);
                    text.Append(compact ? ":" : ": ");
                    WriteValue(text, pair.Value, depth + 1, compact);
                    text.Append(++index < count ? "," : "").Append(newline);
                }
                text.Append(closing).Append("}");
                return;
            }
            IEnumerable items = value as IEnumerable;
            if (items != null)
            {
                List<object> list = new List<object>();
                foreach (object item in items) list.Add(item);
                if (list.Count == 0) { text.Append("[]"); return; }
                text.Append("[").Append(newline);
                for (int i = 0; i < list.Count; i++)
                {
                    text.Append(indent);
                    WriteValue(text, list[i], depth + 1, compact);
                    text.Append(i + 1 < list.Count ? "," : "").Append(newline);
                }
                text.Append(closing).Append("]");
                return;
            }
            WriteString(text, Convert.ToString(value, CultureInfo.InvariantCulture));
        }

        private static IEnumerable<KeyValuePair<string, object>> Pairs(OMap map)
        {
            for (int i = 0; i < map.Count; i++) yield return new KeyValuePair<string, object>(map.KeyAt(i), map.ValueAt(i));
        }
    }

    // Text rules shared by the engine's files.
    internal static class EngineText
    {
        // Set-Content -Encoding UTF8 in Windows PowerShell writes a byte-order mark; the state files keep it.
        internal static readonly Encoding Utf8Bom = new UTF8Encoding(true);
        internal static readonly Encoding Utf8 = new UTF8Encoding(false);

        // Version comparison without System.Numerics: digit strings of any length, compared as numbers.
        internal static int CompareDigits(string left, string right)
        {
            left = left.TrimStart('0'); right = right.TrimStart('0');
            if (left.Length != right.Length) return left.Length < right.Length ? -1 : 1;
            return Math.Sign(String.CompareOrdinal(left, right));
        }

        internal static bool IsDigits(string value)
        {
            if (value.Length == 0) return false;
            foreach (char c in value) if (c < '0' || c > '9') return false;
            return true;
        }

        internal static string Hex(byte[] bytes, bool upper)
        {
            StringBuilder text = new StringBuilder(bytes.Length * 2);
            foreach (byte b in bytes) text.Append(b.ToString(upper ? "X2" : "x2", CultureInfo.InvariantCulture));
            return text.ToString();
        }

        // Full path without a trailing separator, to compare folders the way the script did.
        internal static string Trimmed(string path)
        {
            string full = Path.GetFullPath(path);
            string root = Path.GetPathRoot(full);
            return full.Length > root.Length ? full.TrimEnd('\\', '/') : full;
        }

        internal static bool SamePath(string a, string b)
        {
            return String.Equals(Trimmed(a), Trimmed(b), StringComparison.OrdinalIgnoreCase);
        }

        internal static bool IsInside(string folder, string path)
        {
            string prefix = Trimmed(folder) + Path.DirectorySeparatorChar;
            return Trimmed(path).StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
        }
    }
}
