<#
Convert DXF files to DWG (AutoCAD 2018 format) through AutoCAD COM and verify by reopening the DWG.
Prints entity, hatch, gradient-hatch and true-colour (ByRGB) counts for the DXF and the saved DWG; they must match.
Skips any DWG that already exists. Opens each file read-only and closes it without saving the DXF.

  .\dxf-to-dwg.ps1 -Files C:\path\a.dxf, C:\path\b.dxf
#>
param([Parameter(Mandatory)][string[]]$Files, [string]$ProgId = 'AutoCAD.Application.25')
$ErrorActionPreference = 'Stop'

function Retry([scriptblock]$Action) {
    for ($i = 0; $i -lt 40; $i++) {
        try { return & $Action } catch { if ($_.Exception.HResult -ne -2147418111) { throw }; Start-Sleep -Milliseconds 500 }   # RPC_E_CALL_REJECTED
    }
    throw 'AutoCAD stayed busy.'
}
function Get-Stats($doc) {
    $s = [ordered]@{ entities = 0; hatches = 0; gradients = 0; trueColorEntities = 0 }
    foreach ($e in $doc.ModelSpace) {
        $s.entities++
        if ($e.ObjectName -eq 'AcDbHatch') { $s.hatches++; if ($e.HatchObjectType -eq 1) { $s.gradients++ } }
        if ($e.TrueColor.ColorMethod -eq 194) { $s.trueColorEntities++ }
    }
    [pscustomobject]$s
}

try { $acad = [Runtime.InteropServices.Marshal]::GetActiveObject($ProgId) } catch { $acad = New-Object -ComObject $ProgId }
try {
    Retry { $acad.Visible = $true } | Out-Null
    foreach ($f in $Files) {
        $dwg = [IO.Path]::ChangeExtension($f, '.dwg')
        if (Test-Path $dwg) { Write-Output "SKIP exists: $dwg"; continue }
        $doc = Retry { $acad.Documents.Open($f, $true) }
        $before = Retry { Get-Stats $doc }
        Retry { $doc.SaveAs($dwg, 64) } | Out-Null   # 64 = ac2018_dwg
        Retry { $doc.Close($false) } | Out-Null
        $doc = Retry { $acad.Documents.Open($dwg, $true) }
        $after = Retry { Get-Stats $doc }
        Retry { $doc.Close($false) } | Out-Null
        [pscustomobject]@{ file = (Split-Path $dwg -Leaf); match = (($before | ConvertTo-Json) -eq ($after | ConvertTo-Json)); dxf = $before; dwg = $after } | ConvertTo-Json -Depth 3
    }
}
finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($acad) }
