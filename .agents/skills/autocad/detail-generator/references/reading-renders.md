# Reading renders and catalogue diagrams into a parts list

Renders and catalogue diagrams are the usual brief. Turn them into an interpretation list first: parts, materials and sizes, each marked **given** (a dimension in the brief) or **estimated** (read off the picture). The user confirms or corrects the list before anything is drawn. Then propose answers for what is still open, as a senior designer would, and mark them as proposals.

## Reading the dimensions

- **Find which surface each height measures to.** It may be the floor, the worktop, the transaction top or the top of a raised panel. Two heights on one counter (for example 800 and 1200) usually mean a low counter and a raised transaction panel, not two finishes.
- **On a curved counter, plan depth is not body depth.** An S-shaped counter can be 1600 deep on plan with a 600 deep body. Look for both; the body depth drives the section.
- **A dimension along a curve is a chord unless it is marked as an arc.** A curved module drawn "1580 wide" is 1580 across its ends. Derive the radius from the chord and the rise, or ask for it.
- **Perspective arrows are never scaled.** In a perspective render, receding dimensions shrink. Use them only to identify which edge is meant, and estimate other sizes from the given ones on the same face.
- **Overall versus module.** Modular products give a size per module and one for the assembly. The assembly can be smaller than the sum where modules overlap or nest.
- **Cantilevers.** A ledge running past the end of the counter (metal transaction tops often do) is part of the overall length only if the arrow says so.

## Typical sizes seen in catalogue samples

These are observed values for cross-checking estimates. They are not code requirements, and an accessible counter section still needs the authority's own code and values.

| Item | Range seen | Notes |
|---|---|---|
| Staff worktop (desk) | 730 to 800 | Knee clearance under a 730 desk was 692 |
| Transaction top / raised panel | 1050 to 1200 | 1160 overall on a desk with raised panel; 1200 on a curved reception |
| Raised panel top depth | about 276 to 300 | Above a 730 desk, about 405 high |
| Counter body depth | 380 (modules) to 800 (desks) | 600 typical for reception joinery |
| Low or lowered counter part | about 800 | Check whether it is meant to be the accessible part; values come from the code, not from the sample |
| Transaction shelf over a return | about 205 above the desk | On posts, often curved glass or acrylic |

## Materials and how the tool draws them

| Seen | Typical construction | `custom_section` material |
|---|---|---|
| Corian or solid-surface top or curved front | 12 solid surface on 18 MDF; curved fronts thermoformed | `corian` (substrate `mdf`) |
| White or coloured HPL panels | 0.8 HPL on 18 MDF | `mdf` (note the finish) |
| Marble-look slab | 12 sintered stone on 18 MR MDF | `marble` (substrate `mdf`) |
| Gold, brass or stainless ledge | 1.5 to 3 stainless sheet (PVD for gold) on MDF or steel flat | `steel` |
| Oak or timber slats | Veneered MDF, more stable than solid timber in air-conditioned spaces | `mdf` (note the veneer) |
| Glowing moulded modules | Rotomoulded polyethylene with LED inside: a factory product | `outline` (layout only; the maker details it) |
| Glass or acrylic shelf | 10 to 12 toughened glass or acrylic | `glass` |

## What the tool can and cannot draw yet

- **Straight counters, any section, elevations and plans with slats, shaped (polygon) panels and LED lines:** yes, with `custom_section` (`view`, `points`, `repeat`, `lines`).
- **Curved fronts and S-shaped plans:** not yet. Parts are straight-edged polygons. Until arc segments exist, draw curved plans with `apply_plan` arcs, and keep sections (which are straight through a curved counter) in `custom_section`.
- **Factory products** (moulded LED furniture, ready-made desks): layout views only, with the maker's references in the notes.

## Worked readings (generic, no brand names)

1. **Straight reception, slats and a diagonal marble panel:** 2000 × 600 × 1000 given. Diagonal, slat size and pitch, end panel, toe-kick and staff side were all proposals, confirmed by the user. Front elevation: marble listed last so it hides the slats behind it. Snap the diagonal ends into slat gaps.
2. **S-shaped reception:** 4600 long, 1600 deep on plan, 600 body, 800 low part and 1200 raised panel, Corian top and curved fronts, HPL support panels on the staff side, gold stainless ledge cantilevered past the end. Needs arcs for the plan. Sections: low part and raised part.
3. **Curved LED bar modules:** straight module 1050 × 380 × 1050, curved module 1580 chord × 650 deep × 1050, assembly 3330 × 1210 × 1050. Layout only.
4. **L-shaped workstation with raised top panel:** desk 1600 × 800 at 730, return 800 × 800 at 730, raised top panel 300 deep at 1160 overall, 405 above the desk, curved transaction shelf 205 above the return on posts, cable grommets in both tops.
