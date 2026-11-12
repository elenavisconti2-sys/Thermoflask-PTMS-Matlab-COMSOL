# Thermoflask PTMS — COMSOL and MATLAB

MATLAB scripts for building, running, and assessing a COMSOL Multiphysics model of a thermoflask-based **Phase Change Material Thermal Management System (PTMS)**.

This repository accompanies ongoing thesis research. It documents the computational workflow and makes the implementation easier to inspect and reproduce.

## Software requirements

- **COMSOL Multiphysics 6.3**, with the physics interfaces and licenses used by the model
- **LiveLink for MATLAB**
- **MATLAB R2022b** (development environment)

The scripts use the COMSOL Java API through LiveLink. They are not standalone MATLAB simulations.

## Main files

| File | Purpose |
| --- | --- |
| `COMSOL_Brain.m` | Main entry point, divided into independently runnable sections. |
| `COMSOL_builder.m` | Reconstructs the COMSOL model, including geometry, materials, physics, meshes, solver configurations, and Results definitions. |
| `COMSOL_ReferenceRun.m` | Runs the five reference studies, saves solution checkpoints, and exports Derived Values. |
| `COMSOL_Mesh_Independence.m` | Compares numerical results across different mesh configurations. |
| `COMSOL_Step_Independence.m` | Compares transient results using different maximum time steps. |
| `COMSOL_Turbulence_Comparison.m` | Compares the reference k-ε model with the Algebraic yPlus turbulence approach, subject to COMSOL interface availability. |

The five reference studies cover thermal-oil flow during downhole operation, downhole heating, stationary cooling-air flow, thermal-oil flow during upward operation, and post-cooling.

## Workflow

1. Open **COMSOL with MATLAB** and make the repository scripts available on the MATLAB path.
2. Run the **Build** section of `COMSOL_Brain.m` to create the reference `.mph` model.
3. Run the **Reference** section to solve the five studies and export the reference results.
4. Run the **Mesh Independence**, **Time-Step Independence**, and **Turbulence Comparison** sections as required.


The scripts include error logging and attempt to continue with independent cases when a calculation fails. A study that requires an unavailable upstream solution is skipped rather than treated as a valid result.

### File paths and outputs

The current scripts were developed using `D:\Elena` as the project directory. **Update the hard-coded paths before running the code on another computer.** For the current setup, keep the main `.m` files together in that directory.

Simulation models (`.mph`), Excel reports (`.xlsx`), checkpoints, and diagnostic logs are generated locally. Most reports are written to `Reports/`. These generated files are not required to understand the source code and may be stored separately from the GitHub repository.

## Planned extensions

`COMSOL_Brain.m` is intended to become the central entry point for the complete thesis workflow. Two further sections are **planned but are not yet integrated into the current Brain**:

- **Morris sensitivity analysis** — generate feasible parameter trajectories, run the corresponding COMSOL simulations, and evaluate the sensitivity of selected outputs to design and operating parameters.
- **Optimization** — automate the evaluation of candidate designs and search for improved PTMS configurations subject to geometric and physical constraints.

The Morris and optimization workflows will be documented here once their integration and validation are complete.

**Project status:** Research and development. The repository will be updated as additional studies are completed and verified.
