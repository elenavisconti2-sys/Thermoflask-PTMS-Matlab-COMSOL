%% COMSOL BRAIN
% I keep my COMSOL scripts in this folder. Each section can run by itself.
cd(fileparts(mfilename('fullpath')));

%% 1. Build the model
% Rebuild my geometry, meshes, physics, solvers and Results.
try
    model = COMSOL_builder();
catch ME
    fprintf(2,'Builder failed: %s\n',ME.message);
end

%% 2. Run the reference studies
% Each study checks its prerequisites. The runner keeps partial solutions.
try
    model = COMSOL_ReferenceRun();
catch ME
    fprintf(2,'Reference run failed: %s\n',ME.message);
end

%% 3. Mesh independence
% Continue with the next mesh case if one case does not converge.
try
    meshReport = COMSOL_Mesh_Independence();
catch ME
    fprintf(2,'Mesh independence failed: %s\n',ME.message);
end

%% 4. Time-step independence
% A failed time-step case does not stop the other cases.
try
    stepReport = COMSOL_Step_Independence();
catch ME
    fprintf(2,'Time-step independence failed: %s\n',ME.message);
end

%% 5. Turbulence model comparison
% Compare k-epsilon with Algebraic yPlus, if that interface is available.
try
    turbulenceReport = COMSOL_Turbulence_Comparison();
catch ME
    fprintf(2,'Turbulence comparison failed: %s\n',ME.message);
end
