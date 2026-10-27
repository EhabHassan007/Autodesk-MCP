"""Plan unfolded wall panels from measured faces; no CAD or filesystem mutation beyond output."""
import json
import math
import sys
from pathlib import Path


def number(value, label, allow_zero=False):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f'{label} must be a number')
    value = float(value)
    if not math.isfinite(value) or value < 0 or (not allow_zero and value == 0):
        raise ValueError(f'{label} must be finite and {"nonnegative" if allow_zero else "positive"}')
    return value


def plan_unfold(data):
    height = number(data['wall_height_mm'], 'wall_height_mm')
    segments = data['segments']
    if not isinstance(segments, list) or not segments:
        raise ValueError('segments must be a nonempty list')
    faces, panels, openings = [], [], []
    ids, door_ids = set(), set()
    station = 0.0
    for index, raw in enumerate(segments, 1):
        face_id = raw.get('id', f'W{index:02}')
        if not isinstance(face_id, str) or not face_id.strip() or face_id in ids:
            raise ValueError('Wall face identifiers must be unique nonempty strings')
        ids.add(face_id)
        length = number(raw['length_mm'], f'{face_id}.length_mm')
        local_openings = []
        for op_index, raw_op in enumerate(raw.get('openings', []), 1):
            op_id = raw_op.get('id', f'{face_id}-D{op_index:02}')
            if not isinstance(op_id, str) or not op_id.strip() or op_id in door_ids:
                raise ValueError('Opening identifiers must be unique nonempty strings')
            door_ids.add(op_id)
            start = number(raw_op['start_mm'], f'{op_id}.start_mm', True)
            width = number(raw_op['width_mm'], f'{op_id}.width_mm')
            op_height = number(raw_op.get('height_mm', data.get('door_height_mm')), f'{op_id}.height_mm')
            if start + width > length or op_height > height:
                raise ValueError(f'{op_id} exceeds its wall face')
            local_openings.append(dict(id=op_id, face_id=face_id, start_mm=start,
                                       station_mm=station+start, width_mm=width, height_mm=op_height))
        local_openings.sort(key=lambda op: op['start_mm'])
        cursor = 0.0
        for op in local_openings:
            if op['start_mm'] < cursor:
                raise ValueError(f'Overlapping openings in {face_id}')
            if op['start_mm'] > cursor:
                panels.append(dict(face_id=face_id, kind='wall', station_mm=station+cursor,
                                   length_mm=op['start_mm']-cursor, height_mm=height, bottom_mm=0.0))
            if op['height_mm'] < height:
                panels.append(dict(face_id=face_id, kind='header', opening_id=op['id'],
                                   station_mm=op['station_mm'], length_mm=op['width_mm'],
                                   height_mm=height-op['height_mm'], bottom_mm=op['height_mm']))
            cursor = op['start_mm']+op['width_mm']
        if cursor < length:
            panels.append(dict(face_id=face_id, kind='wall', station_mm=station+cursor,
                               length_mm=length-cursor, height_mm=height, bottom_mm=0.0))
        face = dict(id=face_id, station_mm=station, length_mm=length, openings=local_openings)
        if 'source' in raw:
            face['source'] = raw['source']
        faces.append(face)
        openings.extend(local_openings)
        station += length
    gross_area = station*height/1e6
    opening_area = sum(op['width_mm']*op['height_mm']/1e6 for op in openings)
    panel_area = sum(p['length_mm']*p['height_mm']/1e6 for p in panels)
    if not math.isclose(panel_area, gross_area-opening_area, rel_tol=1e-10, abs_tol=1e-8):
        raise ValueError('Panel areas do not reconcile')
    return dict(units='mm', wall_height_mm=height, faces=faces, panels=panels, openings=openings,
                total_length_mm=station, gross_area_m2=gross_area,
                opening_area_m2=opening_area, net_area_m2=panel_area)


def main():
    if len(sys.argv) != 3:
        raise SystemExit('Usage: plan_unfold.py measured-input.json panel-plan.json')
    source, target = map(Path, sys.argv[1:])
    if source.resolve() == target.resolve():
        raise SystemExit('Input and output paths must differ')
    try:
        result = plan_unfold(json.loads(source.read_text(encoding='utf-8-sig')))
    except (ValueError, KeyError, TypeError) as exc:
        raise SystemExit(f'Invalid wall plan: {exc}') from exc
    target.write_text(json.dumps(result, indent=2, allow_nan=False)+'\n', encoding='utf-8')
    print(f"{len(result['faces'])} faces, {len(result['panels'])} panels, "
          f"{len(result['openings'])} openings; {result['total_length_mm']/1000:.3f} m; "
          f"{result['net_area_m2']:.3f} m2 net")


if __name__ == '__main__':
    main()
