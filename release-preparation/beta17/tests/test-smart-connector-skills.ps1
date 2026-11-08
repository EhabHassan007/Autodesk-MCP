$ErrorActionPreference = 'Stop'
# SmartConnector.exe skills ...: Skills Sync and the skill scripts as compiled code. The compiled program must behave like
# the PowerShell scripts it replaces (they stay in the repository as the fallback and the reference): the same outcomes in
# every scenario of test-central-sync, test-central-preview, test-weekly, test-usage, test-skill-categories,
# test-skill-conflicts, test-skill-encoding, test-skill-exclusion, test-submission, test-sync-self-repair,
# test-task-bootstrap, test-lean-core and test-enrollment. Where it is practical the script and the program run on the
# same input and their results are compared. Windows only; the skill service and GitHub are stand-ins on this computer
# (plain HTTP on 127.0.0.1, which the program accepts only when SMART_CONNECTOR_ALLOW_LOOPBACK_HTTP=1), and git is a stub.
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
if ([Environment]::OSVersion.Platform -ne 'Win32NT') { 'SKIP: SmartConnector.exe needs Windows'; return }
$runtime = (Resolve-Path (Join-Path $PSScriptRoot '../source/runtime')).Path
$scripts = Join-Path $runtime 'scripts'
$t = Join-Path ([IO.Path]::GetTempPath()) ('skills-exe-' + [guid]::NewGuid().ToString('N'))
$root = Join-Path $t 'root'
$exe = Join-Path $root 'bin\SmartConnector.exe'
$savedLocal = $env:LOCALAPPDATA
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$token = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN12345'
$utf8 = New-Object Text.UTF8Encoding($false, $true)
$script:Sandbox = $t
$script:Port = 0
try {
    # 1. Build into an install-shaped folder, as the release does: <root>\bin\SmartConnector.exe beside VERSION and the skills.
    New-Item -ItemType Directory -Force $t | Out-Null
    $null = & (Join-Path $PSScriptRoot '../setup/build-connector-exe.ps1') -OutputPath $exe
    Copy-Item (Join-Path $runtime 'VERSION') $root

    function ConvertTo-ArgumentLine([string[]]$Arguments) {
        (@($Arguments) | ForEach-Object { if ($_ -eq '' -or $_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    }
    # Runs a program with redirected pipes and waits, in the environment of the current sandbox (its own LOCALAPPDATA,
    # USERPROFILE and CODEX_HOME, so the real user's folders are never touched).
    function Invoke-Program([string]$File, [string]$ArgumentLine, [hashtable]$ExtraEnvironment = @{}, $InputText = $null) {
        $info = New-Object Diagnostics.ProcessStartInfo($File, $ArgumentLine)
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true; $info.RedirectStandardInput = $true
        $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
        $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
        $info.WorkingDirectory = $script:Sandbox
        $info.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $script:Sandbox 'local'
        $info.EnvironmentVariables['USERPROFILE'] = Join-Path $script:Sandbox 'user'
        $info.EnvironmentVariables['CODEX_HOME'] = Join-Path $script:Sandbox 'codex'
        $info.EnvironmentVariables['SMART_CONNECTOR_ALLOW_LOOPBACK_HTTP'] = '1'
        foreach ($key in $ExtraEnvironment.Keys) { $info.EnvironmentVariables[[string]$key] = [string]$ExtraEnvironment[$key] }
        $process = [Diagnostics.Process]::Start($info)
        try {
            $outTask = $process.StandardOutput.ReadToEndAsync(); $errTask = $process.StandardError.ReadToEndAsync()
            if ($null -ne $InputText) { $process.StandardInput.Write([string]$InputText) }
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(240000)) { $process.Kill(); throw "$File $ArgumentLine did not finish." }
            [pscustomobject]@{ Code = $process.ExitCode; Out = $outTask.Result; Err = $errTask.Result }
        }
        finally { $process.Dispose() }
    }
    function Invoke-Skills([string[]]$Arguments, [hashtable]$ExtraEnvironment = @{}) {
        Invoke-Program $exe (ConvertTo-ArgumentLine (@('skills') + $Arguments)) $ExtraEnvironment
    }
    function Invoke-Script([string]$Script, [string[]]$Arguments, [hashtable]$ExtraEnvironment = @{}) {
        Invoke-Program $powershell ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $Script + '" ' + (ConvertTo-ArgumentLine $Arguments)) $ExtraEnvironment
    }
    function New-Sandbox([string]$Name) {
        $path = Join-Path $t $Name
        New-Item -ItemType Directory -Force (Join-Path $path 'local'), (Join-Path $path 'user'), (Join-Path $path 'repo\.agents\skills'), (Join-Path $path 'state') | Out-Null
        $script:Sandbox = $path
        $path
    }
    function New-Skill([string]$Root, [string]$Folder, [string]$Name, [string]$Body, [string]$Category = '') {
        $dir = Join-Path $Root $Folder; New-Item -ItemType Directory $dir -Force | Out-Null
        $lines = @('---', "name: $Name"); if ($Category) { $lines += "category: $Category" }; $lines += @('description: test skill', '---', $Body)
        [IO.File]::WriteAllText((Join-Path $dir 'SKILL.md'), ($lines -join "`n"))
    }
    function Read-Json([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    function Get-StateRoot { Join-Path (Join-Path $script:Sandbox 'local') 'AutodeskMcpSkillCollection' }
    # The JSON a script printed: its warnings (printed to the same console output) come before the first line "{".
    function Get-JsonText([string]$Output) { $lines = @($Output -split "`r?`n"); $start = [array]::IndexOf($lines, '{'); ($lines[$start..($lines.Count - 1)]) -join "`n" }
    function Get-ResultLine($Output) { $line = @(($Output -split "`r?`n") | Where-Object { $_.StartsWith('[SYNC_RESULT] ') })[0]; $line.Substring(14) | ConvertFrom-Json }

    # The skill service and the GitHub API, as one stand-in on 127.0.0.1: it records every request and answers like them.
    $standInSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
public static class SkillStandIn
{
    public static string LibraryJson = "{\"commit\":\"test\",\"skills\":[]}";
    public static bool FailUsage, FailPullRequest;
    // Usage requests after this many accepted ones fail with 503 (-1: never).
    public static int FailUsageAfter = -1;
    private static readonly List<string[]> Requests = new List<string[]>();
    private static HttpListener _listener;
    private static int _usageAccepted;

    public static int Start()
    {
        Random random = new Random();
        for (int attempt = 0; attempt < 60; attempt++)
        {
            int port = random.Next(20000, 60000);
            HttpListener listener = new HttpListener();
            listener.Prefixes.Add("http://127.0.0.1:" + port + "/");
            try { listener.Start(); }
            catch (HttpListenerException) { continue; }
            _listener = listener;
            Thread thread = new Thread(Loop);
            thread.IsBackground = true;
            thread.Start();
            return port;
        }
        throw new InvalidOperationException("No free port.");
    }

    public static void Stop() { try { _listener.Close(); } catch (Exception) { } }
    public static void Reset() { lock (Requests) { Requests.Clear(); } _usageAccepted = 0; }
    // method, path, Authorization, X-Connector-Version, User-Agent, Content-Type, body
    public static string[][] Snapshot() { lock (Requests) { return Requests.ToArray(); } }

    private static void Loop()
    {
        while (true)
        {
            HttpListenerContext context;
            try { context = _listener.GetContext(); } catch (Exception) { return; }
            try { Handle(context); } catch (Exception) { try { context.Response.Abort(); } catch (Exception) { } }
        }
    }

    private static void Handle(HttpListenerContext context)
    {
        HttpListenerRequest request = context.Request;
        string body = "";
        using (StreamReader reader = new StreamReader(request.InputStream, new UTF8Encoding(false))) body = reader.ReadToEnd();
        string path = request.Url.PathAndQuery, method = request.HttpMethod;
        lock (Requests)
        {
            Requests.Add(new string[] { method, path, request.Headers["Authorization"], request.Headers["X-Connector-Version"], request.UserAgent, request.ContentType, body });
        }
        int code = 200;
        string answer = "{}";
        if (method == "GET" && path == "/v1/library") answer = LibraryJson;
        else if (method == "POST" && path == "/v1/submissions") answer = "{\"status\":\"submitted_for_approval\",\"pull_request\":\"https://example.test/pull/1\"}";
        else if (method == "POST" && path == "/v1/usage")
        {
            if (FailUsage || (FailUsageAfter >= 0 && _usageAccepted >= FailUsageAfter)) { code = 503; answer = "{\"error\":\"down\"}"; }
            else { _usageAccepted++; answer = "{\"accepted\":1}"; }
        }
        else if (method == "GET" && path == "/user") answer = "{\"login\":\"test-user\",\"id\":12345}";
        else if (method == "GET" && path.Contains("/pulls")) answer = "[]";
        else if (method == "POST" && path.EndsWith("/requested_reviewers")) answer = "{}";
        else if (method == "POST" && path.EndsWith("/pulls"))
        {
            if (FailPullRequest) { code = 500; answer = "{\"error\":\"outage\"}"; }
            else { code = 201; answer = "{\"html_url\":\"https://github.com/example/test/pull/1\",\"number\":1}"; }
        }
        else code = 404;
        byte[] bytes = new UTF8Encoding(false).GetBytes(answer);
        context.Response.StatusCode = code;
        context.Response.ContentType = "application/json; charset=utf-8";
        context.Response.ContentLength64 = bytes.Length;
        context.Response.OutputStream.Write(bytes, 0, bytes.Length);
        context.Response.Close();
    }
}
'@
    if (-not ('SkillStandIn' -as [type])) { Add-Type -TypeDefinition $standInSource -Language CSharp }
    $script:Port = [SkillStandIn]::Start()
    function Get-Requests { @([SkillStandIn]::Snapshot() | ForEach-Object { [pscustomobject]@{ Method = $_[0]; Path = $_[1]; Auth = $_[2]; Version = $_[3]; Agent = $_[4]; ContentType = $_[5]; Body = $_[6] } }) }

    # This PC's enrollment: the token is encrypted by Initialize-SkillService.ps1 (the PowerShell script), so the program
    # has to read what the script writes. service.json then points at the stand-in.
    $savedLocal = $env:LOCALAPPDATA
    $enrollRoot = Join-Path $t 'enroll'; New-Item -ItemType Directory -Force $enrollRoot | Out-Null
    $env:LOCALAPPDATA = $enrollRoot
    $enrollFile = Join-Path $enrollRoot 'enroll.json'
    @{ service_url = 'https://skills.example.test'; device_id = '0123456789abcdef0123456789abcdef'; device_token = $token } | ConvertTo-Json | Set-Content $enrollFile
    $null = & (Join-Path $scripts 'Initialize-SkillService.ps1') -ConfigPath $enrollFile
    $env:LOCALAPPDATA = $savedLocal
    $protected = (Read-Json (Join-Path $enrollRoot 'AutodeskMcpSkillCollection\service.json')).protected_token
    function Enable-Enrollment {
        $folder = Get-StateRoot; New-Item -ItemType Directory -Force $folder | Out-Null
        @{ service_url = "http://127.0.0.1:$($script:Port)"; device_id = '0123456789abcdef0123456789abcdef'; protected_token = $protected } | ConvertTo-Json | Set-Content (Join-Path $folder 'service.json') -Encoding UTF8
    }
    'PASS: SkillsExe built; the skill service and GitHub stand-in are listening'

    # 2. Approved skills installed and updated, local edits preserved, invalid path rejected (test-central-sync).
    $s = New-Sandbox 'central'
    $state = Join-Path $s 'state'; $client = Join-Path $s 'client'
    function Install-Library([string]$Content, [string[]]$More = @(), [string]$StateRoot = $state) {
        $library = @{ commit = 'abc'; skills = @(@{ name = 'revit-test'; files = @{ 'SKILL.md' = $Content } }) } | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText((Join-Path $s 'library.json'), $library)
        Invoke-Skills (@('install-library', '--library-file', (Join-Path $s 'library.json'), '--state-root', $StateRoot, '--repository-root', (Join-Path $s 'repo'), '--client-root', $client) + $More)
    }
    $file = Join-Path $client 'revit-test\SKILL.md'
    $null = Install-Library 'version one'
    Assert ((Get-Content $file -Raw) -eq 'version one') 'Approved skill missing'
    # The ledger holds the hashes the PowerShell scripts compute, so copies installed by either are recognised by both.
    $validation = New-Module -ArgumentList (Join-Path $scripts 'submit-team-knowledge.ps1'), (Join-Path $s 'repo') -ScriptBlock { param($p, $r); . $p -RepositoryRoot $r -LibraryOnly; Export-ModuleMember -Function Get-DirectoryHash }
    $ledger = Read-Json (Join-Path $state 'managed-skill-hashes.json')
    $installedHash = & $validation { Get-DirectoryHash $args[0] } (Join-Path $client 'revit-test')
    $names = @($ledger.PSObject.Properties | ForEach-Object { $_.Name })
    Assert ($names.Count -eq 1 -and $names[0] -eq (Join-Path $client 'revit-test') -and $ledger.PSObject.Properties[$names[0]].Value -eq $installedHash) 'The managed-skill ledger differs from the PowerShell directory hash'
    $null = Install-Library 'version two'
    Assert ((Get-Content $file -Raw) -eq 'version two') 'Unmodified skill not updated'
    Set-Content $file 'personal edits'
    $run = Install-Library 'version three'
    Assert ((Get-Content $file -Raw).Trim() -eq 'personal edits') 'Personal edits lost'
    Assert ((Get-Content (Join-Path $state 'approved-skills\revit-test\SKILL.md') -Raw) -eq 'version three') 'MCP approved cache not updated'
    Assert ($run.Err -match 'Preserved locally edited skill: revit-test') ('The preserved skill was not named: ' + $run.Err)
    $bad = '{"commit":"x","skills":[{"name":"revit-test","files":{"SKILL.md":"ok","../escape.md":"bad"}}]}'
    [IO.File]::WriteAllText((Join-Path $s 'bad.json'), $bad)
    $run = Invoke-Skills @('install-library', '--library-file', (Join-Path $s 'bad.json'), '--state-root', $state, '--repository-root', (Join-Path $s 'repo'), '--client-root', $client)
    Assert ($run.Code -eq 1 -and $run.Err -match 'Invalid approved file path') ("Approved path traversal accepted: $($run.Code) $($run.Err)")
    'PASS: approved skills installed and updated; local edits preserved; MCP cache refreshed; invalid path rejected; ledger hashes match the scripts'

    # 2b. Skills Sync by software (test-central-sync).
    $mixed = '{"commit":"def","skills":[{"name":"revit-one","category":"revit","files":{"SKILL.md":"revit one"}},{"name":"autocad-one","category":"autocad","files":{"SKILL.md":"autocad one"}},{"name":"office-one","category":"general","files":{"SKILL.md":"office one"}},{"name":"shipped-revit","category":null,"files":{"SKILL.md":"shipped revit v2"}}]}'
    [IO.File]::WriteAllText((Join-Path $s 'mixed.json'), $mixed)
    New-Skill (Join-Path $s 'repo\.agents\skills') 'revit\shipped-revit' 'shipped-revit' 'shipped'
    $byProduct = Join-Path $s 'by-product'
    New-Skill $byProduct 'autocad-one' 'autocad-one' 'older autocad copy already installed'
    $before = [IO.File]::ReadAllText((Join-Path $byProduct 'autocad-one\SKILL.md'))
    $run = Invoke-Skills @('install-library', '--library-file', (Join-Path $s 'mixed.json'), '--state-root', (Join-Path $s 'state2'), '--repository-root', (Join-Path $s 'repo'), '--client-root', $byProduct, '--category', 'revit')
    $folders = @(Get-ChildItem $byProduct -Directory | ForEach-Object Name | Sort-Object)
    Assert (($folders -join ',') -eq 'autocad-one,revit-one,shipped-revit') ('Revit sync installed the wrong skills: ' + ($folders -join ','))
    Assert ([IO.File]::ReadAllText((Join-Path $byProduct 'autocad-one\SKILL.md')) -eq $before) 'Revit sync changed an installed AutoCAD skill'
    $summary = ($run.Out.Trim() -split "`r?`n")[-1] | ConvertFrom-Json
    Assert ($summary.total -eq 2 -and $summary.added -eq 2) "Revit sync summary wrong: $($run.Out)"
    $run = Invoke-Skills @('install-library', '--library-file', (Join-Path $s 'mixed.json'), '--state-root', (Join-Path $s 'state3'), '--repository-root', (Join-Path $s 'repo'), '--client-root', (Join-Path $s 'all'))
    Assert ((($run.Out.Trim() -split "`r?`n")[-1] | ConvertFrom-Json).total -eq 4) 'Without categories every approved skill should be downloaded'
    function Get-Categories([string[]]$Arguments) { Invoke-Skills (@('categories') + $Arguments) }
    Assert ((Get-Categories @('--product', 'Revit', '--installed-product', 'AutoCAD')).Out.Trim() -eq 'revit') 'Revit button categories wrong'
    Assert ((Get-Categories @('--product', 'AutoCAD')).Out.Trim() -eq 'autocad') 'AutoCAD button categories wrong'
    Assert ((Get-Categories @('--installed-product', 'Revit', '--installed-product', 'AutoCAD')).Out.Trim() -eq 'revit,autocad,general') 'Weekly categories wrong'
    Assert ((Get-Categories @()).Out.Trim() -eq 'general') 'With no Autodesk product only General should be downloaded'
    $unknown = Get-Categories @('--product', 'Photoshop')
    Assert ($unknown.Code -eq 1 -and $unknown.Err -match 'Unknown product') 'Unknown product accepted'
    $programs = Join-Path $s 'programs'; New-Item -ItemType Directory (Join-Path $programs 'Autodesk\Revit 2024') -Force | Out-Null
    'x' | Set-Content (Join-Path $programs 'Autodesk\Revit 2024\RevitAPI.dll')
    $machine = 'HKCU:\Software\SmartAutodeskConnectorSkillsTest-' + [guid]::NewGuid().ToString('N')
    try {
        New-Item -Path "$machine\AutoCAD\R25.0" -Force | Out-Null; New-Item -Path "$machine\3dsMax" -Force | Out-Null
        $found = (Invoke-Skills @('products', '--program-files', $programs, '--machine-root', $machine)).Out.Trim()
        Assert ($found -eq 'Revit,AutoCAD') "Installed products wrong: $found"
    }
    finally { Remove-Item -LiteralPath $machine -Recurse -Force -ErrorAction SilentlyContinue }
    'PASS: Skills Sync downloads only the chosen categories, keeps other installed skills, and picks categories by product'

    # 3. Category folders and legacy flat skills (test-skill-categories): discovery, flat installs, duplicate names refused.
    $s = New-Sandbox 'categories'
    $lib = Join-Path $s 'lib'
    New-Skill $lib 'revit\revit-a' 'revit-a' 'Guidance.' 'revit'
    New-Skill $lib 'linkedin-marketing\linkedin-b' 'linkedin-b' 'Guidance.' 'linkedin-marketing'
    New-Skill $lib 'legacy-c' 'legacy-c' 'Guidance.'
    New-Item -ItemType Directory (Join-Path $lib '3ds-max') -Force | Out-Null; '# 3ds Max' | Set-Content (Join-Path $lib '3ds-max\README.md')
    New-Item -ItemType Directory (Join-Path $lib 'not-a-category\x') -Force | Out-Null
    $run = Invoke-Skills @('library', '--root', $lib)
    # Windows PowerShell 5.1 hands a JSON array on as one object, so loop over its items instead of piping it.
    $discovered = $run.Out | ConvertFrom-Json
    $found = @(foreach ($item in $discovered) { $item.category + ':' + $item.name }) | Sort-Object
    Assert (($found -join ',') -eq ':legacy-c,linkedin-marketing:linkedin-b,revit:revit-a') ('Discovery wrong: ' + ($found -join ','))
    $repo = Join-Path $s 'repo'
    # Copy the contents explicitly: Windows PowerShell 5.1 copies a folder INTO an existing destination folder.
    function Copy-Contents([string]$From, [string]$To) { New-Item -ItemType Directory -Force $To | Out-Null; Copy-Item (Join-Path $From '*') $To -Recurse -Force }
    Copy-Contents $lib (Join-Path $repo '.agents\skills')
    Remove-Item (Join-Path $repo '.agents\skills\not-a-category') -Recurse
    $dest = Join-Path $s 'claude-skills'
    $run = Invoke-Skills @('codex-sync', '--action', 'Install', '--repository-root', $repo, '--destination', $dest)
    Assert ($run.Code -eq 0) ("Install from a categorised library failed: $($run.Err)")
    Assert ((@(Get-ChildItem $dest -Directory | ForEach-Object Name | Sort-Object) -join ',') -eq 'legacy-c,linkedin-b,revit-a') 'Skills not installed flat'
    Assert ($run.Out -match 'Installed skill: revit-a' -and $run.Out -match 'Skill library installed at: ') 'Install output differs from sync-codex-skills.ps1'
    New-Skill (Join-Path $repo '.agents\skills') 'general\revit-a' 'revit-a' 'Guidance.' 'general'
    $run = Invoke-Skills @('codex-sync', '--action', 'Install', '--repository-root', $repo, '--destination', (Join-Path $s 'dup'))
    Assert ($run.Code -eq 1 -and $run.Err -match 'unique across categories') 'Duplicate skill names across categories were accepted'
    # The collector sees a local copy identical to a categorised library skill as IDENTICAL, not NEW.
    $collectRepo = Join-Path $s 'collect-repo'; Copy-Contents $lib (Join-Path $collectRepo '.agents\skills')
    $local = Join-Path $s 'local-skills'; Copy-Contents (Join-Path $lib 'revit\revit-a') (Join-Path $local 'revit-a')
    $run = Invoke-Skills @('collect', '--repository-root', $collectRepo, '--output-root', (Join-Path $s 'review'), '--additional-skill-root', $local, '--only-additional-skill-roots', '--exclusion-list-path', (Join-Path $s 'none.txt'))
    Assert ($run.Code -eq 0 -and $run.Out -match 'Candidates requiring a decision: 0') ('Categorised library skill reported as new: ' + $run.Out + $run.Err)
    'PASS: category folders and legacy flat skills discovered; installs stay flat; duplicate names refused; collector recognises categorised skills'

    # 4. Preview, exclusion and the collector, compared with the scripts on the same input (test-central-preview,
    #    test-skill-exclusion, test-weekly).
    $s = New-Sandbox 'preview'
    $repo = Join-Path $s 'repo'; $extra = Join-Path $s 'extra'; $state = Join-Path $s 'state'
    New-Skill $extra 'demo' 'demo' 'Inspect a blank test document.'
    New-Skill $extra 'revit-demo' 'revit-demo' 'Inspect a blank test document.'
    New-Skill $extra 'linkedin-profile-optimizer' 'linkedin-profile-optimizer' 'Inspect a blank test document.'
    New-Skill $extra 'renamed-folder' 'personal-notes' 'Inspect a blank test document.'
    [IO.File]::WriteAllText((Join-Path $state 'excluded-skills.txt'), "# personal skills`nLinkedIn-Profile-Optimizer`n`npersonal-notes`n")
    $run = Invoke-Skills @('preview', '--repository-root', $repo, '--state-root', $state, '--additional-skill-root', $extra)
    Assert ($run.Code -eq 0) ("preview failed: $($run.Out) $($run.Err)")
    $result = Read-Json (Join-Path $state 'last-result.json')
    Assert ($result.status -eq 'completed' -and $result.details -match 'demo') 'Central preview did not collect the custom skill'
    Assert (-not (Test-Path (Join-Path $state 'service.json'))) 'Preview created a device credential'
    $preview = ($result.details -split "`r?`n", 2)[1] | ConvertFrom-Json
    $names = @($preview.skills)
    Assert ($names -notcontains 'linkedin-profile-optimizer' -and $names -notcontains 'personal-notes' -and $names -contains 'revit-demo') ('Central exclusion failed: ' + ($names -join ','))
    $sameScript = Invoke-Script (Join-Path $scripts 'weekly-skill-collection.ps1') @('-Action', 'Preview', '-RepositoryRoot', $repo, '-StateRoot', (Join-Path $s 'state-ps'), '-AdditionalSkillRoots', $extra)
    $scriptNames = @(((Get-JsonText ((Read-Json (Join-Path $s 'state-ps\last-result.json')).details -split "`r?`n", 2)[1]) | ConvertFrom-Json).skills | Sort-Object)
    Assert ((@($names | Sort-Object) -join ',') -eq ($scriptNames -join ',') -and $scriptNames.Count -gt 0) ('Preview differs from the script: ' + ($names -join ',') + ' / ' + ($scriptNames -join ','))
    # The collector: listed folders are neither copied nor named in REVIEW.md; the review table equals the script's.
    $list = Join-Path $state 'excluded-skills.txt'
    $run = Invoke-Skills @('collect', '--repository-root', $repo, '--output-root', (Join-Path $s 'review'), '--additional-skill-root', $extra, '--only-additional-skill-roots', '--exclusion-list-path', $list)
    $review = Get-ChildItem (Join-Path $s 'review') -Directory | Select-Object -First 1
    $copied = @(Get-ChildItem (Join-Path $review.FullName 'candidates') -Directory | ForEach-Object { $_.Name -replace '-[0-9a-f]{8}$', '' })
    Assert ($copied -notcontains 'linkedin-profile-optimizer' -and $copied -contains 'revit-demo') ('Collector exclusion failed: ' + ($copied -join ','))
    Assert ((Get-Content (Join-Path $review.FullName 'REVIEW.md') -Raw) -notmatch 'linkedin') 'Excluded skill named in REVIEW.md'
    Assert ($run.Out -match 'exclusion list: 1') 'Excluded count not reported'
    Assert (@(Get-ChildItem (Join-Path $s 'review') -Filter '*.zip').Count -eq 1) 'No review package'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead((Get-ChildItem (Join-Path $s 'review') -Filter '*.zip').FullName)
    try { $entries = @($archive.Entries | ForEach-Object FullName) } finally { $archive.Dispose() }
    Assert (($entries -contains 'REVIEW.md') -and -not ($entries -match 'sources.json')) ('The review package holds the wrong files: ' + ($entries -join ','))
    $psRun = Invoke-Script (Join-Path $scripts 'collect-skills-for-review.ps1') @('-RepositoryRoot', $repo, '-OutputRoot', (Join-Path $s 'review-ps'), '-AdditionalSkillRoots', $extra, '-OnlyAdditionalSkillRoots', '-ExclusionListPath', $list)
    $psReview = Get-ChildItem (Join-Path $s 'review-ps') -Directory | Select-Object -First 1
    $rows = { param($directory) @(Get-Content (Join-Path $directory.FullName 'REVIEW.md') | Where-Object { $_.StartsWith('| ') }) }
    Assert (((& $rows $review) -join "`n") -eq ((& $rows $psReview) -join "`n")) ("REVIEW.md rows differ from the script:`n" + ((& $rows $review) -join "`n") + "`n--`n" + ((& $rows $psReview) -join "`n"))
    Assert ((@($psRun.Out -split "`r?`n") | Where-Object { $_ -like 'Candidates requiring*' }) -eq (@($run.Out -split "`r?`n") | Where-Object { $_ -like 'Candidates requiring*' })) 'Collector summary differs from the script'
    $run = Invoke-Skills @('collect', '--repository-root', $repo, '--output-root', (Join-Path $s 'review2'), '--additional-skill-root', $extra, '--only-additional-skill-roots', '--exclusion-list-path', (Join-Path $s 'none.txt'), '--exclude-skill', 'revit-demo')
    $review2 = Get-ChildItem (Join-Path $s 'review2') -Directory | Select-Object -First 1
    Assert (-not @(Get-ChildItem (Join-Path $review2.FullName 'candidates') -Directory | Where-Object Name -like 'revit-demo-*').Count) '--exclude-skill ignored'
    'PASS: preview collects without credentials or network; excluded skills are not collected, listed or submitted; the review table matches the script'

    # 4b. Candidates for the team intake, compared with the script (test-weekly): the same names, nothing marked submitted.
    $s = New-Sandbox 'weekly'
    $repo = Join-Path $s 'repo'; $extra = Join-Path $s 'extra'; $state = Join-Path $s 'state'; $user = Join-Path $s 'user'
    New-Skill (Join-Path $repo '.agents\skills') 'approved' 'approved' 'already shared'
    New-Skill (Join-Path $user '.claude\skills') 'approved' 'approved' 'already shared'
    New-Skill (Join-Path $user '.claude\skills') 'new-claude' 'new-claude' 'safe workflow'
    New-Skill (Join-Path $user '.agents\skills') 'new-agent' 'new-agent' 'safe workflow'
    New-Skill $extra 'extra-skill' 'extra-skill' 'safe workflow'
    New-Skill $extra 'secret-skill' 'secret-skill' 'password=do-not-upload'
    New-Skill $extra 'new-claude' 'new-claude' 'safe workflow'
    $submitArguments = @('--repository-root', $repo, '--state-root', $state, '--candidate-root', (Join-Path $repo 'team-candidates'), '--include-saved-skills', '--additional-skill-root', $extra, '--dry-run')
    $run = Invoke-Skills (@('submit') + $submitArguments)
    Assert ($run.Code -eq 0) ("dry run failed: $($run.Out) $($run.Err)")
    $names = @(($run.Out | ConvertFrom-Json).candidates | ForEach-Object name | Sort-Object)
    Assert (($names -join ',') -eq 'extra-skill,new-agent,new-claude') ('Incorrect candidates: ' + ($names -join ','))
    Assert (-not (Test-Path (Join-Path $state 'submitted-hashes.json'))) 'Preview marked skills submitted'
    Assert ($run.Err -match 'Skipped candidate secret-skill') 'The skill with a credential was not reported as skipped'
    $psRun = Invoke-Script (Join-Path $scripts 'submit-team-knowledge.ps1') @('-RepositoryRoot', $repo, '-StateRoot', (Join-Path $s 'state-ps'), '-CandidateRoot', (Join-Path $repo 'team-candidates'), '-IncludeSavedSkills', '-AdditionalSkillRoots', $extra, '-DryRun')
    $psData = (Get-JsonText $psRun.Out) | ConvertFrom-Json
    Assert ((@($psData.candidates | ForEach-Object { $_.name + ':' + $_.hash } | Sort-Object) -join ',') -eq (@(($run.Out | ConvertFrom-Json).candidates | ForEach-Object { $_.name + ':' + $_.hash } | Sort-Object) -join ',')) 'Candidates or hashes differ from the script'
    # A nested link must be skipped before any contents can be copied.
    $linked = Join-Path $extra 'linked-skill'; New-Skill $extra 'linked-skill' 'linked-skill' 'safe'
    $linkMade = $true
    try { New-Item -ItemType SymbolicLink -Path (Join-Path $linked 'outside') -Target $user | Out-Null } catch { $linkMade = $false; "SKIP: symbolic links cannot be created here: $($_.Exception.Message)" }
    if ($linkMade) {
        $run = Invoke-Skills (@('submit') + $submitArguments)
        Assert (@(($run.Out | ConvertFrom-Json).candidates | Where-Object name -eq 'linked-skill').Count -eq 0) 'Symlink accepted'
    }
    # A conflicting same-name revision is refused instead of selecting a source arbitrarily.
    New-Skill $extra 'new-claude' 'new-claude' 'conflicting variant'
    $run = Invoke-Skills (@('submit') + $submitArguments)
    Assert ($run.Code -eq 1 -and $run.Err -match 'Conflicting candidates') 'Conflicting skill not rejected'
    'PASS: Claude/agent/custom roots; skip identical and sensitive; duplicate elimination; links and conflicting revisions refused; same candidates and hashes as the script'

    # 5. Two different saved copies of one skill hold back only that skill (test-skill-conflicts).
    $s = New-Sandbox 'conflicts'
    $repo = Join-Path $s 'repo'; $codexSkills = Join-Path $s 'codex\skills'; $claudeSkills = Join-Path $s 'user\.claude\skills'
    function Write-Skill([string]$Root, [string]$Name, [string]$Text) {
        New-Item -ItemType Directory (Join-Path $Root $Name) -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $Root "$Name\SKILL.md"), "---`nname: $Name`ndescription: $Name workflow`n---`n$Text`n")
    }
    Write-Skill $codexSkills 'plain-skill' 'Only one copy.'
    Write-Skill $codexSkills 'split-skill' 'Edited in Codex.'
    Write-Skill $claudeSkills 'split-skill' 'Edited in Claude.'
    # An older approved version, still recorded in the ledger as installed by Skills Sync.
    Write-Skill $claudeSkills 'old-approved' 'Approved last month.'
    $stateDir = Get-StateRoot; New-Item -ItemType Directory -Force $stateDir | Out-Null
    $validation = New-Module -ArgumentList (Join-Path $scripts 'submit-team-knowledge.ps1'), $repo -ScriptBlock { param($p, $r); . $p -RepositoryRoot $r -LibraryOnly; Export-ModuleMember -Function Get-DirectoryHash }
    @{ (Join-Path $claudeSkills 'old-approved') = (& $validation { Get-DirectoryHash $args[0] } (Join-Path $claudeSkills 'old-approved')) } | ConvertTo-Json | Set-Content (Join-Path $stateDir 'managed-skill-hashes.json') -Encoding UTF8
    Enable-Enrollment
    [SkillStandIn]::Reset()
    $run = Invoke-Skills @('central', '--repository-root', $repo, '--state-root', $stateDir)
    Assert ($run.Code -eq 0) ("central sync failed: $($run.Out) $($run.Err)")
    $submission = @(Get-Requests | Where-Object { $_.Path -eq '/v1/submissions' })
    Assert ($submission.Count -eq 1) 'The skill without a conflict was not sent'
    $sent = @(($submission[0].Body | ConvertFrom-Json).skills.name)
    Assert (($sent -join ',') -eq 'plain-skill') ('Unexpected submissions: ' + ($sent -join ','))
    $result = Get-ResultLine $run.Out
    Assert ($result.status -eq 'partial' -and $result.submitted -eq 1 -and $result.withheld -eq 1) ('Unexpected result: ' + ($result | ConvertTo-Json -Compress))
    foreach ($part in 'split-skill', 'Codex user skills', 'Claude Code user skills') { Assert ($result.reason -like "*$part*") "Reason does not mention $part : $($result.reason)" }
    Assert ($result.reason -notlike '*old-approved*') 'Unedited approved copy was treated as a saved skill'
    # The request carries the device token the PowerShell script encrypted, and the connector headers.
    Assert ($submission[0].Auth -eq ('Bearer ' + $token) -and $submission[0].Version -eq 'unknown') ('Wrong authorization or version header: ' + $submission[0].Auth + ' ' + $submission[0].Version)
    Assert ($submission[0].ContentType -eq 'application/json; charset=utf-8') 'Submission must be labelled charset=utf-8'
    'PASS: a conflicting skill is held back alone and named with both locations; unedited approved copies are not sent; the device token written by the script is read'

    # 6. Dashes, quotation marks and Arabic reach the service byte-exact; mojibake is repaired (test-skill-encoding).
    $s = New-Sandbox 'encoding'
    $repo = Join-Path $s 'repo'; $extra = Join-Path $s 'extra'
    $latin1 = [Text.Encoding]::GetEncoding(28591); $windows1252 = [Text.Encoding]::GetEncoding(1252)
    $dash = [string][char]0x2014; $open = [string][char]0x201C; $close = [string][char]0x201D
    $arabic = -join ([char[]]@(0x0627, 0x0644, 0x0646, 0x0635, 0x0020, 0x0627, 0x0644, 0x0639, 0x0631, 0x0628, 0x064A))
    $cafe = 'Caf' + [char]0x00E9 + ' at 50 ' + [char]0x00B0 + 'C; a lone ' + [char]0x00C3 + ' stays'
    function Body([string]$Name) { "---`nname: $Name`ndescription: Encoding round trip`n---`nUse a blank model $dash keep ${open}quoted${close} text.`n$arabic`n$cafe`n" }
    function Once([string]$Text, $Encoding) { $Encoding.GetString($utf8.GetBytes($Text)) }
    function Write-EncodedSkill([string]$Root, [string]$Name, [string]$Text) {
        $folder = Join-Path $Root $Name
        New-Item -ItemType Directory (Join-Path $folder 'references') -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $folder 'SKILL.md'), $utf8.GetBytes($Text))
        [IO.File]::WriteAllBytes((Join-Path $folder 'references\notes.md'), $utf8.GetBytes($Text.Replace('name:', 'topic:')))
    }
    New-Item -ItemType Directory (Join-Path $repo '.agents\skills\revit') -Force | Out-Null
    Write-EncodedSkill $extra 'clean-skill' (Body 'clean-skill')
    Write-EncodedSkill $extra 'twice-latin1-skill' (Once (Once (Body 'twice-latin1-skill') $latin1) $latin1)
    Write-EncodedSkill $extra 'once-windows1252-skill' (Once (Body 'once-windows1252-skill') $windows1252)
    # An approved skill whose local copy was corrupted by a download is not proposed again.
    Write-EncodedSkill (Join-Path $repo '.agents\skills\revit') 'approved-skill' (Body 'approved-skill')
    Write-EncodedSkill $extra 'approved-skill' (Once (Once (Body 'approved-skill') $latin1) $latin1)
    Enable-Enrollment
    [SkillStandIn]::Reset()
    $run = Invoke-Skills @('central', '--repository-root', $repo, '--state-root', (Get-StateRoot), '--additional-skill-root', $extra)
    Assert ($run.Code -eq 0) ("central sync failed: $($run.Out) $($run.Err)")
    $submission = @(Get-Requests | Where-Object { $_.Path -eq '/v1/submissions' })
    Assert ($submission.Count -eq 1) 'Nothing was submitted'
    Assert ($submission[0].ContentType -eq 'application/json; charset=utf-8') 'Submission must be UTF-8 labelled charset=utf-8'
    # The collector copies files byte for byte.
    $candidate = Get-ChildItem (Get-StateRoot) -Recurse -Directory | Where-Object { $_.Name -like 'clean-skill-*' -and $_.Parent.Name -eq 'candidates' }
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $candidate.FullName 'SKILL.md'))) -ceq [Convert]::ToBase64String($utf8.GetBytes((Body 'clean-skill')))) 'Collector changed the bytes'
    $payload = $submission[0].Body | ConvertFrom-Json
    $byName = @{}; foreach ($skill in $payload.skills) { $byName[$skill.name] = $skill.files }
    Assert (-not $byName.ContainsKey('approved-skill')) 'Corrupted copy of an approved skill was submitted'
    foreach ($name in @('clean-skill', 'twice-latin1-skill', 'once-windows1252-skill')) {
        Assert ($byName.ContainsKey($name)) "Missing $name"
        $expected = Body $name
        foreach ($pair in @(@('SKILL.md', $expected), @('references/notes.md', $expected.Replace('name:', 'topic:')))) {
            $actual = [string]$byName[$name].($pair[0])
            Assert ([Convert]::ToBase64String($utf8.GetBytes($actual)) -ceq [Convert]::ToBase64String($utf8.GetBytes($pair[1]))) "$name/$($pair[0]) is not byte-exact: $actual"
        }
    }
    Assert (@($payload.skills).Count -eq 3) ('Unexpected submissions: ' + (@($payload.skills.name) -join ','))
    'PASS: dashes, quotation marks and Arabic reach the service byte-exact; Latin-1 and Windows-1252 mojibake is repaired; repaired copies of approved skills are not resubmitted'

    # 7. Usage counts (test-usage): aggregated by kind, name and day; malformed and expired lines dropped; batches of 500.
    $s = New-Sandbox 'usage'
    $stateDir = Get-StateRoot; Enable-Enrollment
    $usage = Join-Path $stateDir 'usage.jsonl'; $pending = Join-Path $stateDir 'usage-pending.jsonl'
    function Read-Lines([string]$Path) { if (Test-Path $Path) { @(Get-Content $Path | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() } }
    function Add-Usage([string[]]$Lines) { [IO.File]::AppendAllText($usage, (($Lines -join "`n") + "`n")) }
    $today = (Get-Date).ToString('yyyy-MM-dd'); $old = (Get-Date).AddDays(-90).ToString('yyyy-MM-dd')
    function Get-UsageLine([string]$Kind, [string]$Name, [string]$Day) { '{"kind":"' + $Kind + '","name":"' + $Name + '","day":"' + $Day + '"}' }
    Add-Usage @((Get-UsageLine 'skill' 'revit-read-write' $today), (Get-UsageLine 'skill' 'revit-read-write' $today), (Get-UsageLine 'tool' 'drawing_info' $today), 'not json',
        (Get-UsageLine 'skill' 'old-skill' $old), (Get-UsageLine 'bad' 'x' $today))
    [SkillStandIn]::Reset()
    $run = Invoke-Skills @('usage', '--state-root', $stateDir)
    Assert ($run.Code -eq 0 -and $run.Out.Trim() -eq 'Reported 2 usage record(s).') ("Unexpected send result: $($run.Out) $($run.Err)")
    $calls = @(Get-Requests | Where-Object { $_.Path -eq '/v1/usage' })
    Assert ($calls.Count -eq 1) 'One request expected'
    $call = $calls[0]
    Assert ($call.Auth -eq ('Bearer ' + $token) -and $call.Version -and $call.Agent -like 'Autodesk-MCP-Connector/*') ('Wrong usage request: ' + $call.Auth + ' ' + $call.Agent)
    Assert ($call.ContentType -eq 'application/json; charset=utf-8') 'Usage body must be UTF-8'
    $events = @(($call.Body | ConvertFrom-Json).events)
    $skillEvent = $events | Where-Object { $_.kind -eq 'skill' }; $toolEvent = $events | Where-Object { $_.kind -eq 'tool' }
    Assert ($events.Count -eq 2 -and $skillEvent.name -eq 'revit-read-write' -and $skillEvent.count -eq 2 -and $skillEvent.day -eq $today -and $toolEvent.name -eq 'drawing_info' -and $toolEvent.count -eq 1) ('Wrong aggregation: ' + ($events | ConvertTo-Json -Compress))
    Assert (-not (Test-Path $usage) -and -not (Test-Path $pending) -and @(Get-ChildItem $stateDir -Filter 'usage-taking-*').Count -eq 0) 'Sent lines were not removed'
    $run = Invoke-Skills @('usage', '--state-root', $stateDir)
    Assert ($run.Out.Trim() -eq 'No new usage to report.' -and @(Get-Requests | Where-Object { $_.Path -eq '/v1/usage' }).Count -eq 1) 'Empty run sent a request'
    # A failed upload keeps the counts and merges them with new uses on the next run.
    Add-Usage @((Get-UsageLine 'tool' 'list_layers' $today))
    [SkillStandIn]::FailUsage = $true
    $run = Invoke-Skills @('usage', '--state-root', $stateDir)
    Assert ($run.Code -eq 1 -and $run.Err -match 'Usage report failed \(HTTP 503\); unsent counts are kept for the next run\.' -and (Read-Lines $pending).Count -eq 1) ("Failed upload lost the counts: $($run.Code) $($run.Err)")
    Assert ((Get-Content (Join-Path $stateDir 'usage-upload.log') -Raw) -match 'Usage report failed \(HTTP 503\)') 'The failure was not logged'
    [SkillStandIn]::FailUsage = $false
    Add-Usage @((Get-UsageLine 'tool' 'list_layers' $today))
    $null = Invoke-Skills @('usage', '--state-root', $stateDir)
    $last = @((@(Get-Requests | Where-Object { $_.Path -eq '/v1/usage' })[-1].Body | ConvertFrom-Json).events)
    Assert ($last.Count -eq 1 -and $last[0].count -eq 2 -and -not (Test-Path $pending)) 'Retried counts not merged and cleared'
    # More than 500 events go in batches; a failed later batch keeps only the unsent part.
    Add-Usage @(1..600 | ForEach-Object { Get-UsageLine 'tool' ('tool-' + $_) $today })
    [SkillStandIn]::Reset(); [SkillStandIn]::FailUsageAfter = 1
    $run = Invoke-Skills @('usage', '--state-root', $stateDir)
    $calls = @(Get-Requests | Where-Object { $_.Path -eq '/v1/usage' })
    Assert ($run.Code -eq 1 -and @(($calls[0].Body | ConvertFrom-Json).events).Count -eq 500 -and (Read-Lines $pending).Count -eq 100) 'Batching or partial truncation wrong'
    [SkillStandIn]::FailUsageAfter = -1
    $null = Invoke-Skills @('usage', '--state-root', $stateDir)
    $calls = @(Get-Requests | Where-Object { $_.Path -eq '/v1/usage' })
    Assert (@(($calls[-1].Body | ConvertFrom-Json).events).Count -eq 100 -and -not (Test-Path $pending)) 'Remaining batch not sent'
    Remove-Item (Join-Path $stateDir 'service.json')
    Add-Usage @((Get-UsageLine 'tool' 'x' $today))
    Assert ((Invoke-Skills @('usage', '--state-root', $stateDir)).Out.Trim() -eq 'This PC is not enrolled; usage is not reported.') 'A PC that has not joined reported usage'
    'PASS: usage aggregates by kind/name/day, drops malformed and expired lines, batches 500, removes only sent counts, retries the rest'

    # 8. Daily team intake: a draft pull request through a stubbed GitHub API and a stubbed git (test-submission).
    $s = New-Sandbox 'submission'
    $repo = Join-Path $s 'repo'; $state = Join-Path $s 'state'; $candidates = Join-Path $repo 'team-candidates'
    New-Skill $candidates 'new-skill' 'new-skill' 'Use a blank test model.'
    $stubSource = @'
using System;
using System.IO;
public static class StubGit
{
    public static int Main(string[] args)
    {
        string dir = Environment.GetEnvironmentVariable("GIT_STUB_DIR");
        File.AppendAllText(Path.Combine(dir, "git.log"), string.Join(" ", args) + "\n");
        if (args.Length > 0 && args[0] == "credential") { Console.In.ReadToEnd(); Console.Out.Write("username=test\npassword=test-placeholder\n"); return 0; }
        string last = args.Length > 0 ? args[args.Length - 1] : "";
        foreach (string a in args)
        {
            if (a == "clone") { Directory.CreateDirectory(last); return 0; }
            if (a == "ls-remote") { if (File.Exists(Path.Combine(dir, "remote-exists"))) Console.Out.Write("fakehash refs/heads/existing\n"); return 0; }
            if (a == "diff") return 1;
            if (a == "push") { File.WriteAllText(Path.Combine(dir, "remote-exists"), "1"); File.AppendAllText(Path.Combine(dir, "pushes.log"), last + "\n"); return 0; }
        }
        return 0;
    }
}
'@
    $bin = Join-Path $s 'bin'; New-Item -ItemType Directory $bin | Out-Null
    $stubFile = Join-Path $s 'stub-git.cs'; [IO.File]::WriteAllText($stubFile, $stubSource)
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $compiled = & $csc /nologo /target:exe ('/out:' + (Join-Path $bin 'git.exe')) $stubFile 2>&1
    Assert (Test-Path (Join-Path $bin 'git.exe')) ('The stub git did not compile: ' + ($compiled -join "`n"))
    $temp = Join-Path $s 'tmp'; New-Item -ItemType Directory $temp | Out-Null
    $extraEnvironment = @{ PATH = ($bin + ';' + $env:PATH); GIT_STUB_DIR = $s; SMART_CONNECTOR_GITHUB_API = "http://127.0.0.1:$($script:Port)"; TEMP = $temp; TMP = $temp }
    $arguments = @('submit', '--repository-root', $repo, '--state-root', $state, '--candidate-root', $candidates)
    [SkillStandIn]::Reset(); [SkillStandIn]::FailPullRequest = $true
    $run = Invoke-Skills $arguments $extraEnvironment
    Assert ($run.Code -eq 1 -and $run.Err -match 'The remote server returned an error: \(500\)') ("A GitHub outage after the push must fail the run: $($run.Code) $($run.Err)")
    Assert (-not (Test-Path (Join-Path $state 'submitted-hashes.json'))) 'Failed submission advanced ledger'
    [SkillStandIn]::FailPullRequest = $false
    $run = Invoke-Skills $arguments $extraEnvironment
    Assert ($run.Code -eq 0) ("Retry failed: $($run.Out) $($run.Err)")
    $outcome = $run.Out | ConvertFrom-Json
    Assert ($outcome.status -eq 'submitted_for_approval' -and $outcome.pull_request -eq 'https://github.com/example/test/pull/1' -and $outcome.reviewer -eq 'EhabHassan007' -and @($outcome.skills)[0] -eq 'new-skill') ('No PR result: ' + $run.Out)
    $pushes = @(Get-Content (Join-Path $s 'pushes.log'))
    Assert ($pushes.Count -eq 2 -and $pushes[0] -eq $pushes[1] -and $pushes[0] -like 'skill-intake/*') 'Retry created a different branch'
    Assert (@((Read-Json (Join-Path $state 'submitted-hashes.json')).PSObject.Properties).Count -eq 1) 'Wrong ledger count'
    $gitLog = Get-Content (Join-Path $s 'git.log') -Raw
    Assert ($gitLog.Contains('config --local user.email 12345+test-user@users.noreply.github.com')) 'No automatic account identity'
    Assert (-not $gitLog.Contains('--global') -and -not $gitLog.Contains(' merge ')) 'Global configuration or a merge was used'
    $requests = @(Get-Requests)
    $pullRequest = $requests | Where-Object { $_.Method -eq 'POST' -and $_.Path -like '*/pulls' } | Select-Object -Last 1
    $payload = $pullRequest.Body | ConvertFrom-Json
    Assert ($payload.draft -eq $true -and $payload.base -eq 'main' -and $payload.head -like 'skill-intake/*' -and $payload.title -eq 'Team skill review: new-skill') 'The pull request must be a draft against main from a skill-intake branch'
    Assert (@($requests | Where-Object { $_.Path -like '*/requested_reviewers' }).Count -eq 1) 'The owner review was not requested'
    Assert (@($requests | Where-Object { $_.Auth -ne 'Bearer test-placeholder' }).Count -eq 0) 'The GitHub requests did not use the credential manager token'
    Assert (@(Get-ChildItem $temp -Directory | Where-Object Name -like 'BimCadMcp-intake-*').Count -eq 0) 'The temporary checkout was not removed'
    $again = (Invoke-Skills $arguments $extraEnvironment).Out | ConvertFrom-Json
    Assert ($again.status -eq 'no_new_candidates') 'A submitted skill was proposed again'
    'PASS: private GitHub author identity without global configuration; failed PR leaves ledger unchanged; retry reuses branch; creates a draft PR and requests owner review; successful PR records the hash'

    # 9. Skills Sync end to end against the stand-in, its settings, log and result file (test-weekly, test-lean-core,
    #    test-sync-self-repair), and the window's reading of the result.
    $s = New-Sandbox 'sync'
    $repo = Join-Path $s 'repo'; $stateDir = Get-StateRoot
    Copy-Item (Join-Path $runtime 'VERSION') $repo
    New-Skill (Join-Path $repo '.agents\skills') 'revit\shipped-revit' 'shipped-revit' 'shipped' 'revit'
    New-Skill (Join-Path $s 'user\.claude\skills') 'new-claude' 'new-claude' 'safe workflow'
    $library = '{"commit":"abc123","skills":[{"name":"revit-one","category":"revit","files":{"SKILL.md":"revit one"}},{"name":"autocad-one","category":"autocad","files":{"SKILL.md":"autocad one"}},{"name":"office-one","category":"general","files":{"SKILL.md":"office"}}]}'
    [SkillStandIn]::LibraryJson = $library
    Enable-Enrollment
    [SkillStandIn]::Reset()
    $run = Invoke-Skills @('sync', '--action', 'Configure', '--repository-root', $repo)
    Assert ($run.Code -eq 0 -and $run.Out -match 'Skills Sync reminder is on') ("Configure failed: $($run.Out) $($run.Err)")
    $run = Invoke-Skills @('sync', '--action', 'Sync', '--product', 'Revit', '--state-root', $stateDir)
    Assert ($run.Code -eq 0) ("Skills Sync failed: $($run.Out) $($run.Err)")
    Assert ($run.Out -match 'Downloading approved skills in: revit' -and $run.Out -match 'Approved skill library synchronized\. Commit: abc123' -and $run.Out -match '\[SYNC_RESULT\] ') ("Unexpected Skills Sync output: $($run.Out)")
    $result = Read-Json (Join-Path $stateDir 'last-result.json')
    Assert ($result.status -eq 'completed' -and $result.action -eq 'Sync' -and $result.product -eq 'Revit' -and $result.sync_status -eq 'ok' -and $result.sync_submitted -eq 1 -and $result.sync_added -eq 1 -and $result.sync_approved_total -eq 1) ('Result file wrong: ' + ($result | ConvertTo-Json -Compress))
    Assert (Test-Path (Join-Path $s 'user\.claude\skills\revit-one\SKILL.md')) 'The approved Revit skill was not installed for Claude'
    Assert (Test-Path (Join-Path $s 'codex\skills\revit-one\SKILL.md')) 'The approved Revit skill was not installed for Codex'
    Assert (-not (Test-Path (Join-Path $s 'codex\skills\autocad-one'))) 'A Revit sync downloaded an AutoCAD skill'
    Assert ((Get-Content (Join-Path $stateDir 'weekly.log') -Raw) -match '\] Sync') 'The sync was not logged'
    Assert ([double]::Parse((Get-Content (Join-Path $stateDir 'last-sync.txt') -Raw).Trim(), [Globalization.CultureInfo]::InvariantCulture) -gt 20000) 'The last sync day was not recorded'
    # The same run through the window's own reading of the result (ConnectorActions.SkillsSync).
    $outcomeRun = Invoke-Program $exe 'action --outcome SkillsSync' @{} $run.Out
    $shown = $outcomeRun.Out | ConvertFrom-Json
    Assert ($shown.Title -eq 'Skills are in sync' -and $shown.Kind -eq 'Good' -and $shown.Body -match 'Sent for review:  1 saved skill' -and $shown.Body -match '1 new and 0 updated approved AutoCAD skill') ('The window does not read the result: ' + $outcomeRun.Out)
    $requests = @(Get-Requests)
    Assert (@($requests | Where-Object { $_.Path -eq '/v1/submissions' }).Count -eq 1 -and @($requests | Where-Object { $_.Path -eq '/v1/library' }).Count -eq 1) 'One submission and one library download expected'
    # The Skills Sync window reads this state; a second run while the first holds the lock reports it.
    $lock = [IO.File]::Open((Join-Path $stateDir 'run.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $busy = Invoke-Skills @('sync', '--action', 'Sync', '--product', 'Revit', '--state-root', $stateDir)
        Assert ($busy.Code -eq 0 -and $busy.Out -match 'A collection run is already active\.') 'A second run did not report the active one'
    }
    finally { $lock.Dispose() }
    # Failures always carry a reason the window can show (test-sync-self-repair), and a PC that has not joined says so.
    $s2 = New-Sandbox 'sync-failure'
    $run = Invoke-Skills @('sync', '--action', 'Preview', '--product', 'Revit', '--repository-root', (Join-Path $s2 'missing'), '--state-root', (Get-StateRoot))
    $failed = Read-Json (Join-Path (Get-StateRoot) 'last-result.json')
    Assert ($run.Code -eq 1 -and $failed.sync_status -eq 'failed' -and $failed.sync_reason -match 'The installed connector skill library is missing\.') ('A failed run has no reason: ' + ($failed | ConvertTo-Json -Compress))
    Assert ((Get-Content (Join-Path (Get-StateRoot) 'weekly.log') -Raw) -match 'FAILED: The installed connector skill library is missing\.') 'The failure was not logged'
    $s3 = New-Sandbox 'sync-not-enrolled'
    $run = Invoke-Skills @('sync', '--product', 'Revit', '--repository-root', (Join-Path $s3 'repo'), '--state-root', (Get-StateRoot))
    $failed = Read-Json (Join-Path (Get-StateRoot) 'last-result.json')
    Assert ($run.Code -eq 1 -and $failed.sync_status -eq 'not_enrolled' -and $failed.status -eq 'failed' -and $failed.details -match 'administrator enrollment' -and $failed.sync_reason) 'A PC without enrollment is not reported'
    # Settings and the last sync day (test-lean-core 3): a PC updated from an earlier version keeps its last sync.
    $s4 = New-Sandbox 'settings'
    $repo = Join-Path $s4 'repo'; $stateDir = Join-Path $s4 'state'
    $yesterday = (Get-Date).AddDays(-1).ToString('o')
    @{ completed_at = $yesterday; action = 'Sync'; sync_status = 'ok' } | ConvertTo-Json | Set-Content (Join-Path $stateDir 'last-result.json')
    $run = Invoke-Skills @('sync', '--action', 'Configure', '--repository-root', $repo, '--state-root', $stateDir)
    Assert ($run.Code -eq 0) 'Configure failed'
    $settings = Read-Json (Join-Path $stateDir 'settings.json')
    Assert ($settings.enabled -eq $true -and -not $settings.PSObject.Properties['task_name'] -and $settings.repository_root -eq $repo) 'Reminder not on by default, or a task name was saved'
    $day = [double]::Parse((Get-Content (Join-Path $stateDir 'last-sync.txt') -Raw).Trim(), [Globalization.CultureInfo]::InvariantCulture)
    $expected = ([DateTime]::Parse($yesterday).ToUniversalTime() - [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).TotalDays
    Assert ([Math]::Abs($day - $expected) -lt 0.01) "Last sync day not carried over: $day vs $expected"
    $run = Invoke-Skills @('sync', '--action', 'Disable', '--state-root', $stateDir)
    $settings = Read-Json (Join-Path $stateDir 'settings.json')
    Assert ($settings.enabled -eq $false -and $settings.repository_root -eq $repo -and $run.Out -match 'reminder is off') 'Disable lost the reminder choice or the connector folder'
    $null = Invoke-Skills @('sync', '--action', 'Configure', '--repository-root', $repo, '--state-root', $stateDir)
    Assert ((Read-Json (Join-Path $stateDir 'settings.json')).enabled -eq $false) 'Repair switched the reminder back on'
    # The settings file has the same fields and values as the script writes.
    $scriptState = Join-Path $s4 'state-ps'; New-Item -ItemType Directory $scriptState | Out-Null
    $null = Invoke-Script (Join-Path $scripts 'weekly-skill-collection.ps1') @('-Action', 'Configure', '-RepositoryRoot', $repo, '-StateRoot', $scriptState)
    $psSettings = Read-Json (Join-Path $scriptState 'settings.json')
    $programState = Join-Path $s4 'state-program'; New-Item -ItemType Directory $programState | Out-Null
    $null = Invoke-Skills @('sync', '--action', 'Configure', '--repository-root', $repo, '--state-root', $programState)
    $programSettings = Read-Json (Join-Path $programState 'settings.json')
    foreach ($field in 'repository_root', 'repository_url', 'reviewer', 'enabled') { Assert ([string]$programSettings.$field -eq [string]$psSettings.$field) "Setting $field differs from the script: $($programSettings.$field) / $($psSettings.$field)" }
    Assert (@($programSettings.additional_skill_roots).Count -eq @($psSettings.additional_skill_roots).Count) 'Skill folders differ from the script'
    'PASS: Skills Sync downloads by product, sends saved skills, logs and records its result, shows the active run, reports failures with a reason and keeps the reminder settings'

    # 10. Enrollment both ways, and the cleanup of earlier background tasks (test-enrollment, test-lean-core).
    $s = New-Sandbox 'enroll'
    $stateDir = Get-StateRoot
    function Write-EnrollmentFile([string]$Name, [string]$Text) { $path = Join-Path $s $Name; [IO.File]::WriteAllText($path, $Text); $path }
    function Valid([string]$Secret, [string]$Url = 'https://skills.example.test') { @{ service_url = $Url; device_id = '0123456789abcdef0123456789abcdef'; device_token = $Secret } | ConvertTo-Json }
    $run = Invoke-Skills @('initialize', '--config-path', (Write-EnrollmentFile 'a.json' (Valid $token)))
    Assert ($run.Code -eq 0 -and $run.Out -match 'Central skill sharing is configured for this Windows user') ("Enrollment failed: $($run.Out) $($run.Err)")
    $text = Get-Content (Join-Path $stateDir 'service.json') -Raw
    $config = $text | ConvertFrom-Json
    Assert ($config.service_url -eq 'https://skills.example.test' -and -not $text.Contains($token)) 'service.json is wrong or holds the plaintext token'
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $config.protected_token))
    try { Assert ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) -eq $token) 'The token the program encrypted does not decrypt with ConvertTo-SecureString' }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    $run = Invoke-Skills @('initialize', '--config-path', (Write-EnrollmentFile 'b.json' (Valid 'short')))
    Assert ($run.Code -eq 1 -and $run.Err -match 'Invalid device enrollment token\.') 'An invalid token was accepted'
    $run = Invoke-Skills @('initialize', '--config-path', (Write-EnrollmentFile 'c.json' (Valid $token 'http://skills.example.test')))
    Assert ($run.Code -eq 1 -and $run.Err -match 'HTTPS URL') 'A plain HTTP service address was accepted'
    $run = Invoke-Skills @('initialize', '--config-path', (Write-EnrollmentFile 'd.json' (Valid $token 'https://user:secret@skills.example.test')))
    Assert ($run.Code -eq 1 -and $run.Err -match 'HTTPS URL') 'A service address with credentials was accepted'
    'PASS: the enrollment file becomes service.json with the token encrypted for this user, readable by ConvertTo-SecureString; invalid files refused'

    # The same cleanup, on the same files, by the script and by the program.
    function New-OldInstall([string]$Folder) {
        New-Item -ItemType Directory -Force (Join-Path $Folder 'old-state\scripts'), (Join-Path $Folder 'old-connector\remote'), (Join-Path $Folder 'startup'), (Join-Path $Folder 'install\installer'), (Join-Path $Folder 'install\scripts'), (Join-Path $Folder 'install\src\autodesk') | Out-Null
        'x' | Set-Content (Join-Path $Folder 'old-state\scripts\connector-agent.ps1')
        'x' | Set-Content (Join-Path $Folder 'old-state\scripts\send-usage.ps1')
        'token' | Set-Content (Join-Path $Folder 'old-connector\remote\cloudflare-token.dpapi')
        '{"gateway":{"pid":999999,"started_at":"2026-01-01T00:00:00Z"}}' | Set-Content (Join-Path $Folder 'old-connector\remote\runtime.json')
        'x' | Set-Content (Join-Path $Folder 'old-connector\update-requested.flag')
        '@echo off' | Set-Content (Join-Path $Folder 'startup\Autodesk MCP Remote Connector.cmd')
        'x' | Set-Content (Join-Path $Folder 'startup\Other.cmd')
        'x' | Set-Content (Join-Path $Folder 'install\installer\Setup-BimCad.ps1')
        foreach ($oldFile in 'scripts\connector-agent.ps1', 'src\autodesk\autodesk-http-gateway.ps1', 'src\autodesk\Start-AutodeskMcpRemote.ps1', 'REMOTE-CLAUDE.md') { 'x' | Set-Content (Join-Path $Folder "install\$oldFile") }
        'x' | Set-Content (Join-Path $Folder 'install\src\autodesk\autodesk-bridge.ps1')
    }
    function Get-FileList([string]$Folder) { @(Get-ChildItem $Folder -Recurse -File | ForEach-Object { $_.FullName.Substring($Folder.Length) } | Sort-Object) -join '|' }
    $s = New-Sandbox 'retire'
    $mine = Join-Path $s 'program'; $theirs = Join-Path $s 'script'
    New-OldInstall $mine; New-OldInstall $theirs
    $run = Invoke-Skills @('retire-tasks', '--state-root', (Join-Path $mine 'old-state'), '--connector-state', (Join-Path $mine 'old-connector'), '--startup-folder', (Join-Path $mine 'startup'), '--install-root', (Join-Path $mine 'install'))
    Assert ($run.Code -eq 0) ("retire-tasks failed: $($run.Out) $($run.Err)")
    $psRun = Invoke-Script (Join-Path $scripts 'retire-background-tasks.ps1') @('-StateRoot', (Join-Path $theirs 'old-state'), '-ConnectorState', (Join-Path $theirs 'old-connector'), '-StartupFolder', (Join-Path $theirs 'startup'), '-InstallRoot', (Join-Path $theirs 'install'))
    Assert ((Get-FileList $mine) -eq (Get-FileList $theirs)) ("The files left differ from the script:`n" + (Get-FileList $mine) + "`n" + (Get-FileList $theirs))
    $mineLines = @($run.Out -split "`r?`n" | Where-Object { $_ }); $theirLines = @($psRun.Out -split "`r?`n" | Where-Object { $_ })
    Assert (($mineLines -join '|') -eq ($theirLines -join '|')) ("The cleanup report differs from the script:`n" + ($mineLines -join "`n") + "`n--`n" + ($theirLines -join "`n"))
    Assert (-not (Test-Path (Join-Path $mine 'old-state\scripts\connector-agent.ps1')) -and (Test-Path (Join-Path $mine 'old-state\scripts\send-usage.ps1'))) 'Agent restart copy not removed, or a Skills Sync helper removed'
    Assert (-not (Test-Path (Join-Path $mine 'startup\Autodesk MCP Remote Connector.cmd')) -and (Test-Path (Join-Path $mine 'startup\Other.cmd'))) 'Remote start-up entry left, or another start-up entry removed'
    function Test-Task([string]$Name, [string]$TaskArguments = '') {
        $arguments = @('retire-tasks', '--match-task', $Name); if ($TaskArguments) { $arguments += @('--match-arguments', $TaskArguments) }
        (Invoke-Skills $arguments).Out.Trim() -eq 'True'
    }
    Assert ((Test-Task 'Smart Autodesk Connector Agent - S-1-5-21-1') -and (Test-Task 'Autodesk MCP Usage Report - S-1-5-21-1') -and (Test-Task 'Autodesk MCP Weekly Skills - S-1-5-21-1') -and (Test-Task 'Autodesk MCP Connector Update Alerts')) 'A task of an earlier version is not recognised'
    Assert (Test-Task 'Renamed' '-File "C:\Users\a\AppData\Local\AutodeskMcpSkillCollection\scripts\connector-agent.ps1" -Action Run') 'An agent task found by its action is not recognised'
    Assert (-not (Test-Task 'OneDrive Standalone Update Task' '/reporting') -and -not (Test-Task 'Other' '-File C:\Tools\connector-agent.ps1')) 'Another program''s task would be removed'
    'PASS: earlier tasks, agent copy, remote gateway and its files are removed exactly as the script does; nothing else is touched'

    # A real scheduled task of an earlier version is unregistered (test-lean-core 5), and so is the usage task.
    if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) {
        $taskName = 'Autodesk MCP Usage Report - skills-exe-test'
        $registered = $false
        try {
            $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit 0'
            $null = Register-ScheduledTask -TaskName $taskName -Action $action -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(1)) -Force
            $registered = $true
        }
        catch { "SKIP: scheduled tasks cannot be created here: $($_.Exception.Message)" }
        if ($registered) {
            try {
                $run = Invoke-Skills @('retire-tasks', '--state-root', (Join-Path $s 'x1'), '--connector-state', (Join-Path $s 'x2'), '--startup-folder', (Join-Path $s 'x3'), '--install-root', (Join-Path $s 'x4'))
                Assert ($run.Out -match 'Removed scheduled tasks from an earlier version: .*skills-exe-test' -and -not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) ("The earlier usage task was not unregistered: $($run.Out) $($run.Err)")
                'PASS: a scheduled task from an earlier version is unregistered'
            }
            finally { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
            $usageTask = 'Autodesk MCP Usage Report - ' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            try {
                $null = Register-ScheduledTask -TaskName $usageTask -Action (New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit 0') -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(1)) -Force
                $run = Invoke-Skills @('usage', '--action', 'Unregister', '--state-root', (Join-Path $s 'x5'))
                Assert ($run.Code -eq 0 -and $run.Out.Trim() -eq 'Usage reporting task removed.' -and -not (Get-ScheduledTask -TaskName $usageTask -ErrorAction SilentlyContinue)) ("The usage task was not unregistered: $($run.Out) $($run.Err)")
                'PASS: usage --action Unregister removes the usage task of earlier versions'
            }
            finally { Unregister-ScheduledTask -TaskName $usageTask -Confirm:$false -ErrorAction SilentlyContinue }
        }
    }

    # 11. configure-connector-tasks.ps1 (test-task-bootstrap): nothing is registered, the helpers are refreshed, the
    #     reminder choice and the folders are kept, and update checks stay off when the person turned them off.
    $s = New-Sandbox 'configure'
    $repo = Join-Path $s 'repo'
    New-Item -ItemType Directory (Join-Path $repo 'scripts'), (Join-Path $repo '.agents\skills') -Force | Out-Null
    foreach ($name in 'send-usage.ps1', 'weekly-skill-collection.ps1', 'SkillLibrary.ps1') { '# helper' | Set-Content (Join-Path $repo "scripts\$name") }
    $stateDir = Get-StateRoot; New-Item -ItemType Directory -Force $stateDir | Out-Null
    @{ enabled = $false; additional_skill_roots = @('custom') } | ConvertTo-Json | Set-Content (Join-Path $stateDir 'settings.json')
    $connectorState = Join-Path (Join-Path $s 'local') 'AutodeskMcpConnector'; New-Item -ItemType Directory -Force $connectorState | Out-Null
    '{"notifications_enabled":false,"notifications_user_disabled":true}' | Set-Content (Join-Path $connectorState 'update-state.json')
    $run = Invoke-Skills @('configure', '--repository-root', $repo)
    Assert ($run.Code -eq 0) ("configure failed: $($run.Out) $($run.Err)")
    $settings = Read-Json (Join-Path $stateDir 'settings.json')
    Assert ($settings.enabled -eq $false -and @($settings.additional_skill_roots)[0] -eq 'custom') 'Reminder choice or skill folders lost'
    Assert ((Test-Path (Join-Path $stateDir 'scripts\send-usage.ps1')) -and -not (Test-Path (Join-Path $stateDir 'scripts\connector-agent.ps1'))) 'Helpers not copied, or the agent copied again'
    Assert ($run.Out -match 'Nothing runs in the background' -and $run.Out -match 'Update checks remain off in Settings\.') ("Unexpected configure output: $($run.Out)")
    'PASS: configure registers nothing, removes earlier tasks, refreshes the helpers and keeps the reminder choice, the skill folders and the update-check choice'

    # 12. The windows start the program, and fall back to the script only where the program is not installed.
    $actions = Get-Content (Join-Path $runtime 'src\connector\ConnectorActions.cs') -Raw
    $app = Get-Content (Join-Path $runtime 'src\connector\SmartConnectorApp.cs') -Raw
    $revit = Get-Content (Join-Path $runtime 'src\revit\addin\ConnectorUi.cs') -Raw
    Assert ($actions.Contains('"skills sync --action Sync --product AutoCAD --state-root "') -and $actions.Contains('weekly-skill-collection.ps1')) 'The Skills Sync window does not start the program, or lost the script fallback'
    Assert ($app.Contains('"skills sync --action "') -and $app.Contains('weekly-skill-collection.ps1')) 'The reminder switch does not start the program, or lost the script fallback'
    Assert ($revit.Contains('"skills sync --action Sync --product Revit --state-root "') -and $revit.Contains('weekly-skill-collection.ps1')) 'Revit Skills Sync does not start the program, or lost the script fallback'
    $main = Get-Content (Join-Path $runtime 'src\connector\McpServer.cs') -Raw
    Assert ($main.Contains('SkillsCommands.TryRun(args, out skillsCode)')) 'Program.Main does not hand the skills command on'
    'PASS: the Skills Sync windows, the reminder switch and Revit start bin\SmartConnector.exe skills ..., with the script as the fallback'
}
finally {
    $env:LOCALAPPDATA = $savedLocal
    try { [SkillStandIn]::Stop() } catch { }
    Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
}
