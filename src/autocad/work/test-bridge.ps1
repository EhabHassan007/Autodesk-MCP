$ErrorActionPreference='Stop'
. "$PSScriptRoot/../autocad-bridge.ps1" -LibraryOnly
function Check($ok,$message) {if (!$ok) {throw $message}}
function Must-Fail($block) {$failed=$false;try {& $block | Out-Null} catch {$failed=$true};Check $failed 'Expected rejection'}
function Args($json) {$json | ConvertFrom-Json}
Must-Fail {Assert-Args 'create_entity' (Args '{"kind":"circle"}')}
Must-Fail {Assert-Args 'create_entity' (Args '{"expected_drawing":"test","kind":"circle","layer":"0","point":[0,0,0],"radius":-1}')}
Must-Fail {Assert-Args 'create_entity' (Args '{"expected_drawing":"test","kind":"circle","layer":"0","point":[0,"bad",0],"radius":1}')}
Must-Fail {Assert-Args 'list_entities' (Args '{"limit":201}')}
Must-Fail {Assert-Args 'list_entities' (Args '{"limit":1.5}')}
Must-Fail {Assert-Args 'set_layer' (Args '{"expected_drawing":"test","name":"0","action":"locked","value":"false"}')}
Must-Fail {Assert-Args 'drawing_info' (Args '{"unexpected":1}')}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
public class MockLayer { public string Name="0"; public int Color=7; public bool LayerOn=true, Freeze=false, Lock=false; }
public class MockLayers : System.Collections.IEnumerable {
 private List<MockLayer> entries=new List<MockLayer>();
 public System.Collections.IEnumerator GetEnumerator(){return entries.GetEnumerator();}
 public MockLayer Item(string name) {var l=entries.Find(x=>x.Name==name);if(l==null)throw new Exception("Missing layer");return l;}
 public MockLayer Add(string name) {var l=entries.Find(x=>x.Name==name);if(l!=null)return l;l=new MockLayer{Name=name};entries.Add(l);return l;}
}
public class MockEntity {
 public string Handle="A1", ObjectName="AcDbCircle", Layer="0", TextString="";
 public double Radius=2, Height=1; public double[] Center=new double[]{0,0,0};
 public int OwnerID=1; public bool Deleted=false;
 public void Move(double[] a,double[] b) {for(int i=0;i<3;i++)Center[i]+=b[i]-a[i];}
 public void Delete(){Deleted=true;}
}
public class MockSpace : List<MockEntity> {
 public MockEntity Item(int i){return this[i];}
 public MockEntity AddCircle(double[] p,double r){var e=new MockEntity{Center=p,Radius=r};Add(e);return e;}
 public MockEntity AddLine(double[] p,double[] q){var e=new MockEntity{ObjectName="AcDbLine",Center=p};Add(e);return e;}
 public MockEntity AddText(string s,double[] p,double h){var e=new MockEntity{ObjectName="AcDbText",TextString=s,Center=p,Height=h};Add(e);return e;}
}
public class MockOwner { public bool IsLayout=true; }
public class MockLayout {public string Name="Model";}
public class MockDoc {
 public string Name="test.dwg",Path="D:\\",FullName="D:\\test.dwg";
 public bool ReadOnly=false,Saved=false; public int Marks=0,Saves=0;
 public MockSpace ModelSpace=new MockSpace();public MockLayers Layers=new MockLayers();public MockOwner Owner=new MockOwner();
 public MockLayout ActiveLayout=new MockLayout();public MockLayout[] Layouts=new[]{new MockLayout()};
 public int GetVariable(string n){return 4;}
 public MockEntity HandleToObject(string h){var e=ModelSpace.Find(x=>x.Handle==h&&!x.Deleted);if(e==null)throw new Exception("Missing handle");return e;}
 public MockOwner ObjectIDToObject(int id){return Owner;}
 public void StartUndoMark(){Marks++;} public void EndUndoMark(){Marks--;}
 public void Save(){Saves++;Saved=true;}
}
'@
$script:mockDoc=New-Object MockDoc
$null=$mockDoc.Layers.Add('0')
$script:mockCad=[pscustomobject]@{Documents=@($mockDoc);ActiveDocument=$mockDoc;Version='mock'}
function Connect-Cad {return $script:mockCad}
$id=$mockDoc.FullName
function A($values) { $values.expected_drawing=$id; [pscustomobject]$values }
$info=Invoke-CadTool 'drawing_info' ([pscustomobject]@{})
Check ($info.drawing_id -eq $id) 'Identity'
Must-Fail {Invoke-CadTool 'create_entity' (A @{kind='circle';layer='0';point=@(0,0,0)})}
Check ($mockDoc.ModelSpace.Count -eq 0) 'Invalid create mutated document'
Must-Fail {Invoke-CadTool 'create_entity' ([pscustomobject]@{expected_drawing='other';kind='circle';layer='0';point=@(0,0,0);radius=5})}
$mockDoc.ReadOnly=$true
Must-Fail {Invoke-CadTool 'create_entity' (A @{kind='circle';layer='0';point=@(0,0,0);radius=5})}
$mockDoc.ReadOnly=$false
$mockDoc.Layers.Item('0').Lock=$true
Must-Fail {Invoke-CadTool 'create_entity' (A @{kind='circle';layer='0';point=@(0,0,0);radius=5})}
$mockDoc.Layers.Item('0').Lock=$false
$null=Invoke-CadTool 'create_entity' (A @{kind='circle';layer='0';point=@(1,2,0);radius=5})
Check ($mockDoc.ModelSpace.Count -eq 1) 'Circle not created'
$null=Invoke-CadTool 'edit_entity' (A @{handle='A1';action='move';displacement=@(10,0,0)})
Check ($mockDoc.ModelSpace[0].Center[0] -eq 11) 'Move failed'
$null=Invoke-CadTool 'edit_entity' (A @{handle='A1';action='set_radius';radius=9})
Check ($mockDoc.ModelSpace[0].Radius -eq 9) 'Radius failed'
$mockDoc.Owner.IsLayout=$false
Must-Fail {Invoke-CadTool 'edit_entity' (A @{handle='A1';action='delete'})}
$mockDoc.Owner.IsLayout=$true
Must-Fail {Invoke-CadTool 'edit_entity' (A @{handle='A1';action='replace_text';text='test'})}
$null=Invoke-CadTool 'set_layer' (A @{name='NEW';action='create'})
$null=Invoke-CadTool 'set_layer' (A @{name='NEW';action='color';color=3})
$null=Invoke-CadTool 'edit_entity' (A @{handle='A1';action='change_layer';layer='NEW'})
$page=Invoke-CadTool 'list_entities' ([pscustomobject]@{limit=1})
Check ($page.entities.Count -eq 1 -and $page.entities[0].layer -eq 'NEW') 'Entity inspection'
Check ($mockDoc.Saves -eq 0 -and $mockDoc.Marks -eq 0) 'Unexpected save or open Undo group'
$null=Invoke-CadTool 'save_drawing' (A @{})
Check ($mockDoc.Saves -eq 1) 'Save failed'
$null=Invoke-CadTool 'edit_entity' (A @{handle='A1';action='delete'})
Check $mockDoc.ModelSpace[0].Deleted 'Delete failed'
$null=Invoke-CadTool 'create_entity' (A @{kind='text';layer='0';point=@(0,0,0);text='Old';height=2})
$null=Invoke-CadTool 'edit_entity' (A @{handle='A1';action='replace_text';text='New'})
Check ($mockDoc.ModelSpace[1].TextString -eq 'New') 'Text edit failed'
'PASS: validation, target/read-only/locked-layer/block guards, read, create, move, radius, layer, text, delete, explicit save, Undo grouping (mock AutoCAD).'
