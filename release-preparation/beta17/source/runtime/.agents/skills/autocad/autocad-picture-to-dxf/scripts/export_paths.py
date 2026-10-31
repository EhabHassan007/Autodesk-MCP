"""Write audited closed DXF polylines from traced pixel coordinates."""
import argparse
import json
import math
from pathlib import Path
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--library-dir', type=Path)
    args = parser.parse_args()
    if args.library_dir:
        sys.path.insert(0, str(args.library_dir.resolve()))
    import ezdxf

    data = json.loads(args.input.read_text(encoding='utf-8-sig'))
    height = float(data['image_height'])
    scale = float(data.get('scale', 1))
    if not all(math.isfinite(v) and v > 0 for v in (height, scale)):
        raise ValueError('image_height and scale must be positive finite numbers')
    paths = []
    for item in data['paths']:
        points = [(float(x)*scale, (height-float(y))*scale) for x,y in item['points']]
        if len(points)<3 or len(set(points))<3 or points[0]==points[-1]:
            raise ValueError('Each closed path needs at least 3 distinct vertices and no duplicated closing vertex')
        if not all(math.isfinite(v) for p in points for v in p):
            raise ValueError('Coordinates must be finite')
        paths.append((item.get('layer', 'OUTLINES'), points))
    if not paths:
        raise ValueError('No paths supplied')
    doc = ezdxf.new('R2010')
    doc.units = int(data.get('units', 0))
    for layer in sorted({name for name,_ in paths}):
        if layer not in doc.layers:
            doc.layers.new(layer, dxfattribs={'color':7})
    for layer, points in paths:
        doc.modelspace().add_lwpolyline(points, close=True, dxfattribs={'layer':layer})
    xs = [x for _,p in paths for x,y in p]
    ys = [y for _,p in paths for x,y in p]
    doc.set_modelspace_vport(height=max(max(ys)-min(ys),max(xs)-min(xs),1)*1.15,
                            center=((max(xs)+min(xs))/2,(max(ys)+min(ys))/2))
    if args.output.exists():
        raise FileExistsError(f'Refusing to overwrite {args.output}; choose a new output filename')
    doc.saveas(args.output)
    readback = ezdxf.readfile(args.output)
    audit = readback.audit()
    entities = list(readback.modelspace())
    if audit.errors or audit.fixes or len(entities)!=len(paths):
        raise RuntimeError('DXF readback/audit failed')
    for entity,(layer,points) in zip(entities,paths):
        if entity.dxftype()!='LWPOLYLINE' or not entity.closed or entity.dxf.layer!=layer or list(entity.get_points('xy'))!=points:
            raise RuntimeError('Geometry changed during DXF round trip')
    print(json.dumps({'file':str(args.output.resolve()),'closed_polylines':len(paths),
                      'vertices':sum(len(p) for _,p in paths),'audit_errors':0,
                      'audit_fixes':0,'geometry_verified':True,'live_autocad_verified':False}))


if __name__ == '__main__':
    main()
