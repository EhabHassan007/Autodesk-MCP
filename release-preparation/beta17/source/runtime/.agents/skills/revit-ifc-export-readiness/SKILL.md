---
name: revit-ifc-export-readiness
description: Preflight a Revit model for IFC export by checking model segregation, storeys, rooms, classifications, required properties, coordinates, units, links, and export settings. Use before authority submission or IFC handover; validate the exported IFC separately.
---

# Revit IFC export readiness

Perform a pre-export review without changing the model unless fixes are explicitly requested. A Revit-side pass is evidence of readiness, not proof that the exported IFC is compliant.

## Set the target

1. Identify the receiving requirement: authority standard, exchange information requirements, BEP, IDS, client property set, IFC schema, model view definition, permit stage, and file-naming rule.
2. Use the actual supplied requirement files where possible. Confirm their revision and effective date. Treat remembered or example values as unverified.
3. Record the intended model scope, building, discipline, phase, and whether the delivery is one file or several segregated parts.

## Revit preflight

Check:

1. **File and model segregation** — one agreed building/discipline/part per file, consistent naming, no duplicated scope across exports, and a clear rule for podiums, towers, shared basements, or size-based splits.
2. **Storeys and levels** — unique and standard-compliant names, correct elevations, intended building-storey status, reference/dummy levels excluded, and cross-model agreement.
3. **Rooms and spaces** — placed and enclosed spaces, unique identifiers, correct boundaries and heights, required usage data, unit grouping, parking data, and area reconciliation against the project's declared calculations.
4. **Classification and mapping** — intended IFC class and predefined type for every required category; explicit exclusion for items that should not export; no reliance on category defaults where the exchange requirement expects a deliberate mapping.
5. **Required information** — property sets, shared parameters, type/instance placement, data types, controlled vocabulary, and completeness at the stated project stage. Distinguish a missing parameter binding from a bound but empty value.
6. **Geometry and modelling** — correct host/storey, no unintended multi-storey elements, duplicate geometry, major gaps, floating objects, unresolved links, inappropriate placeholder content, or known hard clashes that affect the delivery.
7. **Coordinates and units** — agreed coordinate reference, shared position, easting/northing/elevation, project and export units, true north, site placement, and gate/benchmark elevation when required.
8. **Export configuration** — schema and model view definition, user-defined property sets, base quantities, space boundaries, linked-file handling, selected-view scope, phase, splitting settings, and geographic reference. Compare values, not only the setup name.
9. **Package readiness** — file names, revision, issue status, expected companion files, folder structure, and package-size or compression constraints from the current delivery requirement.

## Exported IFC verification

After export, validate the actual IFC rather than assuming Revit settings produced the intended result:

- schema and syntax validation;
- project/site/building/storey hierarchy;
- coordinates, units, and orientation;
- entity classification and predefined types;
- required property sets and values;
- rooms/spaces, quantities, and area totals;
- missing, duplicated, or unexpectedly split geometry;
- file-name and internal-identifier cross-checks;
- visual placement against the parcel/control model when applicable;
- IDS or authority checker results when supplied.

Keep Revit element ids, IFC GlobalIds, and checker entity ids together when a mapping is available. A Revit finding resolved before export remains unverified until the new IFC is checked.

## Findings and fixes

Report each issue with severity, source requirement, model/file scope, element or entity identity, observed value, expected condition, correction, and verification status. Never populate missing project information from sample data. Renaming, classification changes, parameter binding, room placement, deletion, purging, and export-setting changes require explicit approval and readback or re-export verification.

## Deliverable

State one of: **not ready**, **ready with exceptions**, or **ready for test export**. List blockers first, then required information gaps, geometry/coordination risks, and warnings. Separate Revit preflight results from exported-IFC results and avoid describing either as authority certification.
