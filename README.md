# Thermoflask PTMS — COMSOL / MATLAB

This repository contains the MATLAB scripts I use to build and run my COMSOL model of a thermoflask-based phase change material thermal management system (PTMS).

The model covers two stages of operation. During **downhole heating**, the thermoflask is exposed to a hot environment and the PCM absorbs heat. During **post-cooling**, thermal oil circulates through the system and heat is rejected to the surrounding air through the finned heat exchanger.

I am using these scripts as part of my thesis work. Keeping the model setup in MATLAB makes it easier to rebuild the same COMSOL model, repeat numerical checks and keep track of changes.

## Requirements

The scripts were developed with:

- COMSOL Multiphysics 6.3
- LiveLink for MATLAB
- MATLAB R2022b

You need a working COMSOL–MATLAB connection and the COMSOL physics modules used by the model. These scripts do not solve the governing equations in MATLAB; they control COMSOL through LiveLink.

## Files

| File | What it does |
| --- | --- |
| `COMSOL_Brain.m` | Main script. I use its sections to run the different tasks separately. |
| `COMSOL_builder.m` | Builds the geometry, materials, physics, meshes, studies, custom solvers and Results definitions, then saves the `.mph` file. |
| `COMSOL_ReferenceRun.m` | Runs the five reference studies and exports the calculated quantities to Excel. |
| `COMSOL_Mesh_Independence.m` | Repeats the studies with different meshes to check the effect of mesh refinement. |
| `COMSOL_Step_Independence.m` | Tests different maximum time steps for the transient studies. |
| `COMSOL_Turbulence_Comparison.m` | Compares the reference k-ε cooling-air model with Algebraic yPlus. |

The five reference studies are thermal oil (downhole), downhole heating, cooling air, thermal oil (upward) and post-cooling. Some studies use solutions from earlier ones, so their order matters.

## Running the model

I normally start **COMSOL with MATLAB**, open `COMSOL_Brain.m` and run only the section I need using **Run Section** in MATLAB.

The usual order is:

1. Run the builder to create the reference COMSOL model.
2. Run the reference studies and check that the solutions and post-processing quantities look reasonable.
3. Run the mesh, time-step or turbulence comparisons when needed.

The builder only creates the model; it does not run the five reference studies. The simulation scripts write Excel reports and diagnostic logs. They also try to preserve completed results if a later study fails. When a study depends on a solution that is missing, it cannot be treated as a successful run.

**Paths:** The current scripts use `D:\Elena` as the working directory. Some paths are hard-coded, so they need to be changed before running the project on another machine. Reports are generally saved in the `Reports` folder. COMSOL `.mph` files, checkpoints and large result files are kept separately from the source code.

## Work still to be added

I plan to extend `COMSOL_Brain.m` with two more sections:

- **Morris sensitivity analysis:** generating feasible parameter trajectories, running the corresponding COMSOL cases and comparing how the design parameters affect the quantities of interest.
- **Optimization:** testing alternative geometries and operating conditions to improve the thermal performance while respecting the geometric constraints.

I have been developing these analyses separately. They are **not yet integrated into the Brain script** shown here, and I will update this README when that part of the workflow is ready.

## Notes

The scripts reflect the current research model, not a finished software package. Solver settings, geometric selections and the transfer of temperature fields between studies are especially important for this model. I check these in COMSOL after making changes to the builder.

This repository is intended to accompany the thesis methodology and results. It provides the implementation behind the numerical studies; the modelling assumptions, verification and interpretation of the results are discussed in the thesis itself.
