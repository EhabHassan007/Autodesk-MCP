param([switch]$LibraryOnly)
$ErrorActionPreference = 'Stop'

function New-Tool($name, $description, $properties, $required, [bool]$readOnly) {
    @{ name=$name; description=$description; inputSchema=@{type='object';properties=$properties;required=@($required);additionalProperties=$false}; annotations=@{readOnlyHint=$readOnly;openWorldHint=$false;destructiveHint=(!$readOnly);idempotentHint=$readOnly} }
}
$str = @{type='string';minLength=1}
$num = @{type='number'}
$point = @{type='array';items=$num;minItems=3;maxItems=3;description='World coordinates [x,y,z], in drawing units.'}
$target = @{type='string';minLength=1;description='Exact drawing path returned by drawing_info (name for an unsaved drawing).'}
$toolList = @(
    (New-Tool 'drawing_info' 'Read active drawing identity, units, layouts, object count and save state. Call before writes.' @{} @() $true),
    (New-Tool 'list_layers' 'Read all layers in the active drawing.' @{} @() $true),
    (New-Tool 'list_entities' 'Read paginated top-level model-space or named-layout objects, including geometry/text where available. Does not expand blocks or xrefs. Offset refers to collection index.' @{layout=$str;layer=$str;offset=@{type='integer';minimum=0};limit=@{type='integer';minimum=1;maximum=200}} @() $true),
    (New-Tool 'get_entity' 'Read an object by handle from the expected drawing.' @{expected_drawing=$target;handle=$str} @('expected_drawing','handle') $true),
    (New-Tool 'create_entity' 'Create a line, circle or single-line text in model space or a named layout. Requires an existing unlocked layer. Coordinates are WCS, lengths are drawing units. Does not save.' @{expected_drawing=$target;kind=@{type='string';enum=@('line','circle','text')};layer=$str;layout=$str;point=$point;end=$point;radius=@{type='number';exclusiveMinimum=0};text=$str;height=@{type='number';exclusiveMinimum=0}} @('expected_drawing','kind','layer','point') $false),
    (New-Tool 'edit_entity' 'Edit a top-level entity by handle. Actions: move by WCS displacement, change_layer, replace_text (TEXT/MTEXT), set_radius (circle), delete. One Undo group per call. Does not edit inside block definitions or xrefs; does not save.' @{expected_drawing=$target;handle=$str;action=@{type='string';enum=@('move','change_layer','replace_text','set_radius','delete')};displacement=$point;layer=$str;text=@{type='string'};radius=@{type='number';exclusiveMinimum=0}} @('expected_drawing','handle','action') $false),
    (New-Tool 'set_layer' 'Create a layer or set exactly one layer property: color (ACI 1-255), on, frozen, locked. Does not save.' @{expected_drawing=$target;name=$str;action=@{type='string';enum=@('create','color','on','frozen','locked')};color=@{type='integer';minimum=1;maximum=255};value=@{type='boolean'}} @('expected_drawing','name','action') $false),
    (New-Tool 'save_drawing' 'Explicitly save the expected drawing to its EXISTING path. Invoke only when saving is requested; no Save As.' @{expected_drawing=$target} @('expected_drawing') $false)
)

function Assert-Args($name,$a) {
    $tool = $toolList | Where-Object name -eq $name
    if (!$tool) { throw "Unknown tool: $name" }
    if ($null -eq $a) { $a = [pscustomobject]@{} }
    foreach ($key in $tool.inputSchema.required) {
        if ($null -eq $a.PSObject.Properties[$key]) { throw "Missing argument: $key" }
    }
    foreach ($prop in $a.PSObject.Properties) {
        $s = $tool.inputSchema.properties[$prop.Name]; $v = $prop.Value
        if (!$s) { throw "Unknown argument: $($prop.Name)" }
        if ($null -eq $v) { throw "Null argument: $($prop.Name)" }
        switch ($s.type) {
            'string' { if ($v -isnot [string] -or ($s.minLength -and [string]::IsNullOrWhiteSpace($v))) { throw "Invalid string: $($prop.Name)" } }
            'boolean' { if ($v -isnot [bool]) { throw "Invalid boolean: $($prop.Name)" } }
            {$_ -in 'number','integer'} {
                if ($v -isnot [ValueType] -or $v -is [bool] -or [double]::IsNaN([double]$v) -or [double]::IsInfinity([double]$v)) { throw "Invalid number: $($prop.Name)" }
                if ($s.type -eq 'integer' -and [math]::Truncate([double]$v) -ne $v) { throw 'Expected integer.' }
                if (($s.ContainsKey('minimum') -and $v -lt $s.minimum) -or ($s.ContainsKey('maximum') -and $v -gt $s.maximum) -or ($s.ContainsKey('exclusiveMinimum') -and $v -le $s.exclusiveMinimum)) { throw "Number out of range: $($prop.Name)" }
            }
            'array' {
                if ($v -isnot [array] -or $v.Count -ne 3) { throw 'A point must have three coordinates.' }
                foreach ($n in $v) { if ($null -eq $n -or $n -isnot [ValueType] -or $n -is [bool] -or [double]::IsNaN([double]$n) -or [double]::IsInfinity([double]$n)) { throw 'Coordinates must be finite numbers.' } }
            }
        }
        if ($s.enum -and $v -cnotin $s.enum) { throw "Invalid choice: $($prop.Name)" }
    }
}
function Require-Arg($a,$key) { if ($null -eq $a.PSObject.Properties[$key]) { throw "Missing argument for this action: $key" } }
function Connect-Cad { [Runtime.InteropServices.Marshal]::GetActiveObject('AutoCAD.Application.25') }
function Drawing-Id($doc) { if ($doc.Path) { $doc.FullName } else { $doc.Name } }
function Assert-Target($doc,$expected) { if ((Drawing-Id $doc) -ine $expected) { throw 'Active drawing changed or expected_drawing is incorrect. Read drawing_info again.' } }
function Read-Entity($entity) {
    $r=@{handle=$entity.Handle;type=$entity.ObjectName;layer=$entity.Layer}
    foreach ($p in @('Color','Linetype','Lineweight','StartPoint','EndPoint','Center','Radius','InsertionPoint','TextString','Height','Rotation','Coordinates','Closed','Length','Area','Name')) {
        try { $v=$entity.$p; if ($null -ne $v) { $r[$p]=$v } } catch { }
    }
    return $r
}
function Get-Space($doc,$layout) { if (!$layout -or $layout -eq 'Model') { return ,$doc.ModelSpace } else { return ,($doc.Layouts.Item($layout).Block) } }
function Assert-Unlocked($doc,$layer) { $l=$doc.Layers.Item($layer); if ($l.Lock) { throw "Layer is locked: $layer" } }

function Invoke-CadTool($name,$a) {
    Assert-Args $name $a
    $cad=Connect-Cad
    if ($cad.Documents.Count -eq 0) { throw 'Open a drawing in AutoCAD first.' }
    $doc=$cad.ActiveDocument
    if ($a.expected_drawing) { Assert-Target $doc $a.expected_drawing }
    switch ($name) {
        'drawing_info' { return @{name=$doc.Name;path=$doc.FullName;drawing_id=(Drawing-Id $doc);version=$cad.Version;units_code=$doc.GetVariable('INSUNITS');model_space_objects=$doc.ModelSpace.Count;saved=$doc.Saved;read_only=$doc.ReadOnly;active_layout=$doc.ActiveLayout.Name;layouts=@($doc.Layouts | ForEach-Object {$_.Name})} }
        'list_layers' { return @{drawing=(Drawing-Id $doc);layers=@($doc.Layers | ForEach-Object {@{name=$_.Name;color=$_.Color;on=$_.LayerOn;frozen=$_.Freeze;locked=$_.Lock}})} }
        'list_entities' {
            $space=Get-Space $doc $a.layout; $limit=100; if ($a.limit) {$limit=$a.limit}; $i=[int]$a.offset
            $items=New-Object System.Collections.Generic.List[object]
            while ($i -lt $space.Count -and $items.Count -lt $limit) { $e=$space.Item($i); $i++; if (!$a.layer -or $e.Layer -ieq $a.layer) {$items.Add((Read-Entity $e))} }
            $next=$null; if ($i -lt $space.Count) {$next=$i}
            return @{drawing=(Drawing-Id $doc);entities=@($items.ToArray());next_offset=$next;collection_count=$space.Count}
        }
        'get_entity' { return (Read-Entity ($doc.HandleToObject($a.handle))) }
    }
    if ($doc.ReadOnly) { throw 'Drawing is read-only.' }
    if ($name -eq 'save_drawing') {
        if (!$doc.Path) { throw 'Save this drawing to a file in AutoCAD first.' }
        $doc.Save()
        return @{drawing=(Drawing-Id $doc);saved=$doc.Saved}
    }
    # Prevalidate all action-specific arguments before a mutation.
    switch ($name) {
        'create_entity' {
            Assert-Unlocked $doc $a.layer
            $space=Get-Space $doc $a.layout
            if ($a.kind -eq 'line') { Require-Arg $a 'end'; if (($a.point -join ',') -eq ($a.end -join ',')) {throw 'Line endpoints must differ.'} }
            if ($a.kind -eq 'circle') { Require-Arg $a 'radius' }
            if ($a.kind -eq 'text') { Require-Arg $a 'text'; Require-Arg $a 'height' }
        }
        'edit_entity' {
            $e=$doc.HandleToObject($a.handle)
            $owner=$doc.ObjectIDToObject($e.OwnerID)
            if (!$owner.IsLayout) { throw 'Only top-level layout/model-space entities can be edited.' }
            Assert-Unlocked $doc $e.Layer
            switch ($a.action) {
                'move' {Require-Arg $a 'displacement'}
                'change_layer' {Require-Arg $a 'layer'; Assert-Unlocked $doc $a.layer}
                'replace_text' {Require-Arg $a 'text'; if ($e.ObjectName -notin @('AcDbText','AcDbMText')) {throw 'Object is not TEXT or MTEXT.'}}
                'set_radius' {Require-Arg $a 'radius'; if ($e.ObjectName -ne 'AcDbCircle') {throw 'Object is not a circle.'}}
            }
        }
        'set_layer' {
            if ($a.action -ne 'create') {$l=$doc.Layers.Item($a.name)}
            if ($a.action -eq 'color') {Require-Arg $a 'color'}
            if ($a.action -in @('on','frozen','locked')) {Require-Arg $a 'value'}
        }
    }
    $doc.StartUndoMark()
    try {
        switch ($name) {
            'create_entity' {
                $e=$null
                try {
                    switch ($a.kind) {
                        'line' {$e=$space.AddLine([double[]]$a.point,[double[]]$a.end)}
                        'circle' {$e=$space.AddCircle([double[]]$a.point,[double]$a.radius)}
                        'text' {$e=$space.AddText([string]$a.text,[double[]]$a.point,[double]$a.height)}
                    }
                    $e.Layer=$a.layer
                } catch { if ($null -ne $e) {try {$e.Delete()} catch {}}; throw }
                $data=Read-Entity $e
            }
            'edit_entity' {
                switch ($a.action) {
                    'move' {$e.Move([double[]]@(0,0,0),[double[]]$a.displacement)}
                    'change_layer' {$e.Layer=$a.layer}
                    'replace_text' {$e.TextString=$a.text}
                    'set_radius' {$e.Radius=[double]$a.radius}
                    'delete' {$e.Delete()}
                }
                if ($a.action -eq 'delete') {$data=@{deleted_handle=$a.handle}} else {$data=Read-Entity $e}
            }
            'set_layer' {
                switch ($a.action) {
                    'create' {$l=$doc.Layers.Add($a.name)}
                    'color' {$l.Color=[int]$a.color}
                    'on' {$l.LayerOn=[bool]$a.value}
                    'frozen' {$l.Freeze=[bool]$a.value}
                    'locked' {$l.Lock=[bool]$a.value}
                }
                $data=@{layer=$l.Name;color=$l.Color;on=$l.LayerOn;frozen=$l.Freeze;locked=$l.Lock}
            }
        }
    } finally { $doc.EndUndoMark() }
    return @{drawing=(Drawing-Id $doc);result=$data;save_performed=$false}
}

if ($LibraryOnly) { return }
[Console]::InputEncoding=New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false)
while ($null -ne ($line=[Console]::ReadLine())) {
    if ([string]::IsNullOrWhiteSpace($line)) {continue}
    try {$r=$line | ConvertFrom-Json} catch {
        [Console]::WriteLine('{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}'); continue
    }
    if ($null -eq $r.id) {continue}
    $response=@{jsonrpc='2.0';id=$r.id}
    switch ($r.method) {
        'initialize' {
            $protocol='2024-11-05'; if ($r.params.protocolVersion -in @('2024-11-05','2025-03-26','2025-06-18','2025-11-25')) {$protocol=$r.params.protocolVersion}
            $response.result=@{protocolVersion=$protocol;capabilities=@{tools=@{}};serverInfo=@{name='autocad-2025-local';version='0.2.0'};instructions='Read drawing_info before editing; use drawing_id as expected_drawing. Inspect entities before modifying their handles. Writes are enabled for any active writable drawing. Coordinates use WCS and drawing units. Each edit is an Undo group, not an atomic transaction; inspect after errors before retrying. Saving requires the separate save_drawing tool and user intent to save. Blocks and xrefs are not expanded by list_entities.'}
        }
        'ping' {$response.result=@{}}
        'tools/list' {$response.result=@{tools=$toolList}}
        'tools/call' {
            try {$data=Invoke-CadTool $r.params.name $r.params.arguments; $response.result=@{content=@(@{type='text';text=($data | ConvertTo-Json -Depth 20 -Compress)});isError=$false}}
            catch {$response.result=@{content=@(@{type='text';text=$_.Exception.Message});isError=$true}}
        }
        default {$response.error=@{code=-32601;message='Method not found'}}
    }
    [Console]::WriteLine(($response | ConvertTo-Json -Depth 30 -Compress))
}
