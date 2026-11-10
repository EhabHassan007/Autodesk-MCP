using System;
using System.CodeDom.Compiler;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using Microsoft.CSharp;

namespace SmartConnector
{
    // The compile-and-run part of execute_autocad. No AutoCAD calls here: the code is compiled before AutoCAD is
    // contacted, so mistakes are reported without touching the drawing. The code is the body of
    // string Run(dynamic cad, dynamic doc), the same idea as Revit's execute_csharp.
    // This is not a sandbox: the compiled code runs with the user's Windows permissions.
    internal static class AutoCadScript
    {
        internal const int MaxCodeLength = 100000;
        internal const int MaxResultLength = 100000;
        private const int MaxCached = 50;
        private const int MaxReportedErrors = 10;

        private static readonly Dictionary<string, MethodInfo> Cache = new Dictionary<string, MethodInfo>();
        private static readonly object CacheLock = new object();

        // #line makes compiler messages count from the first line of the supplied code.
        private const string Header =
            "using System;\n" +
            "using System.Collections.Generic;\n" +
            "using System.Globalization;\n" +
            "using System.Linq;\n" +
            "using System.Text;\n" +
            "public static class McpAutoCadEntry {\n" +
            "  public static string Run(dynamic cad, dynamic doc) {\n" +
            "#line 1 \"mcp_code.cs\"\n";
        private const string Footer = "\n#line default\n  }\n}\n";

        internal static MethodInfo Compile(string code)
        {
            if (String.IsNullOrWhiteSpace(code)) throw new ToolException("C# code is required.");
            if (code.Length > MaxCodeLength) throw new ToolException("C# code exceeds the 100,000 character limit.");

            string key = Hash(code);
            lock (CacheLock)
            {
                MethodInfo cached;
                if (Cache.TryGetValue(key, out cached)) return cached;
            }

            CompilerParameters parameters = new CompilerParameters();
            parameters.GenerateExecutable = false;
            parameters.GenerateInMemory = true;
            parameters.IncludeDebugInformation = false;
            parameters.TreatWarningsAsErrors = false;
            parameters.CompilerOptions = "/optimize";
            foreach (string location in new[] { typeof(object).Assembly.Location, typeof(Enumerable).Assembly.Location, typeof(Uri).Assembly.Location, typeof(Microsoft.CSharp.RuntimeBinder.Binder).Assembly.Location })
                if (!String.IsNullOrEmpty(location) && !parameters.ReferencedAssemblies.Contains(location)) parameters.ReferencedAssemblies.Add(location);

            CompilerResults results;
            using (CSharpCodeProvider provider = new CSharpCodeProvider(new Dictionary<string, string> { { "CompilerVersion", "v4.0" } }))
                results = provider.CompileAssemblyFromSource(parameters, Header + code + Footer);

            if (results.Errors.HasErrors)
            {
                StringBuilder message = new StringBuilder("C# compilation failed:");
                int shown = 0;
                foreach (CompilerError error in results.Errors)
                {
                    if (error.IsWarning) continue;
                    if (shown++ >= MaxReportedErrors) { message.Append("\n(more errors not listed)"); break; }
                    message.Append("\nLine ").Append(error.Line.ToString(CultureInfo.InvariantCulture)).Append(": ").Append(error.ErrorText);
                }
                throw new ToolException(message.ToString());
            }

            MethodInfo run = results.CompiledAssembly.GetType("McpAutoCadEntry", true).GetMethod("Run", BindingFlags.Public | BindingFlags.Static);
            if (run == null) throw new ToolException("Compiled C# entry point was not found.");
            lock (CacheLock)
            {
                // A loaded assembly cannot be unloaded, so the cache is bounded and simply restarted when full.
                if (Cache.Count >= MaxCached) Cache.Clear();
                Cache[key] = run;
            }
            return run;
        }

        // Runs the compiled code. cad and doc are the AutoCAD Application and the active Document.
        internal static string Run(MethodInfo run, object cad, object doc)
        {
            try
            {
                object result = run.Invoke(null, new object[] { cad, doc });
                return result == null ? "" : Convert.ToString(result, CultureInfo.InvariantCulture);
            }
            catch (TargetInvocationException exception)
            {
                Exception inner = exception.InnerException ?? exception;
                throw new ToolException("C# execution failed: " + inner.GetType().Name + ": " + inner.Message);
            }
        }

        internal static string Limit(string text, out bool truncated)
        {
            truncated = text.Length > MaxResultLength;
            return truncated ? text.Substring(0, MaxResultLength) : text;
        }

        private static string Hash(string code)
        {
            using (SHA256 sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(code)));
        }
    }
}
