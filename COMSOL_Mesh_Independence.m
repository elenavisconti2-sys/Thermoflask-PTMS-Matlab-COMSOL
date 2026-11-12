function reportFile = COMSOL_Mesh_Independence(maxCases)
%% MESH INDEPENDENCE STUDY - THERMOFLASK REFERENCE
% I run the same reference model on four mesh configurations.
% Each configuration includes all five studies, in the usual order.
%
% I use a fresh copy of the MPH for each test. This is important because
% the initial conditions of the transient studies depend on earlier solutions.
%
% MATLAB R2022b + COMSOL 6.3 LiveLink for MATLAB.
%
% Full test:
%   COMSOL_Mesh_Independence();
%
% Quick test (only my customized coarse mesh):
%   COMSOL_Mesh_Independence(1);
%
% One final Excel file, with exactly five worksheets:
%   Reports\Reference_Mesh_Report.xlsx
%
% I do not change the geometry, physics, solver settings or reference inputs.
% I only change which mesh is used by each study step.

%% 1. FILES AND TEST SETTINGS
% All my MATLAB files and the reference MPH are stored in the same folder.
projectFolder = fileparts(mfilename('fullpath'));
modelFile = fullfile(projectFolder,'COMSOL_Reference.mph');
reportFolder = fullfile(projectFolder,'Reports');
reportFile = fullfile(reportFolder,'Reference_Mesh_Report.xlsx');
logFile = fullfile(reportFolder,'Reference_Mesh_Report_Log.txt');
checkpointFile = fullfile(reportFolder,'Reference_Mesh_Report_Data.mat');

if nargin < 1 || isempty(maxCases)
    maxCases = 4;
end
validateattributes(maxCases,{'numeric'},{'scalar','integer','>=',1,'<=',4});
assert(isfile(modelFile),'Reference model not found: %s',modelFile);
if ~isfolder(reportFolder), mkdir(reportFolder); end

% I use separate copies of the model for these four cases.
meshNames = {'Coarse simplified','Physics Coarser','Physics Normal','Physics Fine'};
meshCodes = {'CUSTOM','COARSER','NORMAL','FINE'};
meshLevels = [NaN,7,5,4]; % COMSOL: 7=Coarser, 5=Normal, 4=Fine.

studyTags = {'std1','std2','std3','std4','std5'};
studySteps = {'stat','time','stat','stat','time'};
studyNames = {'Thermal Oil Downhole','Downhole Heating', ...
              'Cooling Air','Thermal Oil Upward','Post Cooling'};
excelSheets = {'01_Oil_Downhole','02_Downhole_Heating', ...
               '03_Cooling_Air','04_Oil_Upward','05_Post_Cooling'};
resultDatasets = {'dset11','dset44','dset46','dset48','dset50'};

% These are the Derived Values defined and organized in the reference runner.
% Probe-generated numerical features are not included as independent metrics.
numericalTags = { ...
    {'av1','max1','av2'}, ...
    {'max2','av4','av5','av3','min1','max3','int1','int4','int2','int3','gevDownAudit'}, ...
    {'av6','av7','av8','av10','av14'}, ...
    {'av15','max6','av16'}, ...
    {'max4','av11','av12','av13','av17','av18','av19','min2','gevCoolAudit'} ...
    };

% The same five-minute output grid is used to compare the transients.
% I interpolate the stored COMSOL results onto this grid, but never beyond
% the time reached by the shortest successful simulation.
comparisonTimeStep_min = 5;

fid = fopen(logFile,'w');
assert(fid>=0,'Cannot create log file: %s',logFile);
fclose(fid);
miLog(logFile,'MESH INDEPENDENCE - %s',datestr(now));
miLog(logFile,'Source model: %s',modelFile);
miLog(logFile,'Tests requested: %d/4',maxCases);
miLog(logFile,'No changes to the original MPH will be saved.');

import com.comsol.model.util.*
try
    ModelUtil.showProgress(true);
catch
    % COMSOL progress messages are optional; I always have my own log.
end

%% 2. READ THE RESULTS DEFINITIONS FROM MY REFERENCE MODEL
% I take the expressions and descriptions from COMSOL, rather than typing
% them again. This way the Excel follows the model's Results tree.
miRemoveModel('MeshIndependenceCatalog');
catalog = mphload(modelFile,'MeshIndependenceCatalog');
definitions = cell(1,5);
for s = 1:5
    definitions{s} = miReadDefinitions(catalog,numericalTags{s});
    miLog(logFile,'%s: %d Derived Value expressions',studyTags{s},numel(definitions{s}));
end
miRemoveModel('MeshIndependenceCatalog');
clear catalog

%% 3. PREPARE EMPTY RESULTS FOR THE FOUR MESHES
% I collect the results in MATLAB first. There will be only one final
% workbook, written after the simulations have finished.
results = struct([]);
for m = 1:4
    results(m).mesh = meshNames{m}; %#ok<AGROW>
    results(m).code = meshCodes{m};
    results(m).status = repmat({'NOT RUN'},1,5);
    results(m).solverTime_s = nan(1,5);
    results(m).totalElements = nan(1,5);
    results(m).volumeElements = nan(1,5);
    results(m).averageQuality = nan(1,5);
    results(m).minimumQuality = nan(1,5);
    results(m).meshTag = repmat({''},1,5);
    results(m).study = struct([]);
    for s = 1:5
        results(m).study(s).time_min = [];
        results(m).study(s).values = cell(numel(definitions{s}),1);
        results(m).study(s).errors = repmat({''},numel(definitions{s}),1);
    end
end

%% 4. RUN EACH MESH CASE
% The studies need to run sequentially: std2 uses std1, and std5 uses
% both the Downhole result and the upward-flow initialization.
wholeTest = tic;
for m = 1:maxCases
    modelTag = 'MeshIndependenceCase';
    miRemoveModel(modelTag);
    miLog(logFile,'========================================================');
    miLog(logFile,'CASE %d/%d: %s',m,maxCases,meshNames{m});
    caseTimer = tic;
    model = [];
    activeStudy = 1;
    dependencies = {[],[1],[],[3],[2 4]};
    try
        model = mphload(modelFile,modelTag);

        % I clear old solutions in case COMSOL_Reference.mph was already
        % computed. Otherwise a previous solution could contaminate a test.
        for s = 1:5
            model.sol(sprintf('sol%d',s)).clearSolutionData();
        end

        for s = 1:5
            activeStudy = s;
            required = dependencies{s};
            if any(~strcmp(results(m).status(required),'SOLVED'))
                results(m).status{s} = 'SKIPPED: required solution failed';
                miLog(logFile,'  SKIPPED %s: a prerequisite was not solved',studyTags{s});
                continue;
            end
            miLog(logFile,'  START %d/5: %s',s,studyNames{s});
            try  % I isolate this study so the other branch can still run.
            tMesh = tic;

            %% 4A. BUILD OR SELECT THE MESH FOR THIS STUDY
            studyStep = model.study(studyTags{s}).feature(studySteps{s});
            if m == 1
                % This is the existing user-controlled mesh with the custom
                % size settings and the two Boundary Layer groups.
                currentMesh = 'mesh5';
                studyStep.mesh('geom1',currentMesh);
                if s == 1
                    model.component('comp1').mesh(currentMesh).run();
                end
            else
                % Physics-controlled meshes depend on the active physics.
                % I create a separate mesh for each study: that prevents a
                % later study from rebuilding a mesh used by an earlier one.
                currentMesh = sprintf('mi%d_s%d',meshLevels(m),s);
                model.component('comp1').mesh.create(currentMesh);
                meshObject = model.component('comp1').mesh(currentMesh);
                meshObject.label(sprintf('MI - %s - %s',meshNames{m},studyTags{s}));
                meshObject.automatic(true);
                meshObject.autoMeshSize(meshLevels(m));
                studyStep.mesh('geom1',currentMesh);
                meshObject.runForStudy(sprintf('%s/%s',studyTags{s},studySteps{s}));
            end

            % This is the crucial mesh assignment; creating a mesh alone
            % would not guarantee that the study actually uses it.
            selectedMesh = char(studyStep.mesh('geom1'));
            assert(strcmp(selectedMesh,currentMesh), ...
                'Study %s did not select the expected mesh.',studyTags{s});
            results(m).meshTag{s} = currentMesh;
            miLog(logFile,'    Mesh %s built/selected in %.1f s',currentMesh,toc(tMesh));

            % I also keep the element count and quality in the same report.
            try
                ms = mphmeshstats(model,currentMesh);
                results(m).totalElements(s) = sum(double(ms.numelem));
                types = ms.types;
                if isstring(types), types = cellstr(types); end
                if ischar(types), types = cellstr(types); end
                volumeTypes = ismember(types,{'tet','prism','pyr','hex','ctx'});
                results(m).volumeElements(s) = sum(double(ms.numelem(volumeTypes)));
                results(m).averageQuality(s) = double(ms.meanquality);
                results(m).minimumQuality(s) = double(ms.minquality);
            catch statsME
                miLog(logFile,'    Mesh statistics unavailable: %s',miShort(statsME.message));
            end

            %% 4B. SOLVE USING MY EXISTING CUSTOM SOLVER
            % runNoGen keeps the settings already defined in sol1...sol5.
            % In particular, I do not reset the time-dependent solvers.
            tSolve = tic;
            model.study(studyTags{s}).runNoGen();
            results(m).solverTime_s(s) = toc(tSolve);
            results(m).status{s} = 'SOLVED';
            miLog(logFile,'    SOLVED %s in %.1f s',studyTags{s},results(m).solverTime_s(s));

            %% 4C. COLLECT ALL DERIVED VALUES FOR THIS STUDY
            % I keep the complete time history for Downhole and Post Cooling.
            try
                results(m).study(s) = miCollectValues( ...
                    model,definitions{s},resultDatasets{s},ismember(s,[2,5]));
                nBad = nnz(~cellfun(@isempty,results(m).study(s).errors));
                if nBad>0
                    miLog(logFile,'    %d Derived Value expressions need checking.',nBad);
                end
            catch evalME
                miLog(logFile,'    WARNING: Results extraction failed: %s',miShort(evalME.message));
                results(m).study(s).errors(:) = {miShort(evalME.message)};
            end
            catch studyME
                results(m).status{s} = ['FAILED: ' miShort(studyME.message)];
                miLog(logFile,'  FAILED %s: %s',studyTags{s},miShort(studyME.message));
                detailPath = fullfile(reportFolder,sprintf('Mesh_Case_%d_%s_Error.txt',m,studyTags{s}));
                fidErr = fopen(detailPath,'w');
                if fidErr>=0
                    fprintf(fidErr,'%s\n',getReport(studyME,'extended','hyperlinks','off'));
                    fclose(fidErr);
                end
                % Continue to the next study only when its dependencies allow it.
            end
        end
        miLog(logFile,'CASE COMPLETE: %s (%.1f min)',meshNames{m},toc(caseTimer)/60);

    catch ME
        results(m).status{activeStudy} = ['FAILED: ' miShort(ME.message)];
        for later = activeStudy+1:5
            results(m).status{later} = 'NOT RUN (previous study failed)';
        end
        miLog(logFile,'CASE FAILED in %s: %s',studyTags{activeStudy},miShort(ME.message));
        errorFile = fullfile(reportFolder,sprintf('Mesh_Case_%d_Error.txt',m));
        efid = fopen(errorFile,'w');
        if efid>=0
            fprintf(efid,'%s\n',getReport(ME,'extended','hyperlinks','off'));
            fclose(efid);
        end
        miLog(logFile,'Details: %s',errorFile);
    end

    % The MAT file is a checkpoint, not an additional Excel report.
    % It lets me inspect partial data if a long test has problems.
    try
        save(checkpointFile,'results','definitions','meshNames','studyNames', ...
            'studyTags','modelFile','-v7.3');
    catch checkpointME
        miLog(logFile,'WARNING: MATLAB checkpoint failed: %s',miShort(checkpointME.message));
    end
    miRemoveModel(modelTag);
    clear model
end

%% 5. BUILD ONE EXCEL FILE WITH FIVE STUDY SHEETS
% Each sheet compares all four meshes side by side. For transient studies
% I show both the final state and a common-time comparison below it.
miLog(logFile,'Writing final Excel report ...');
try
    if isfile(reportFile)
        delete(reportFile);  % Never mix two independent comparisons.
    end
catch lockedReport
    % Excel may be holding the workbook open. Do not discard the simulations.
    miLog(logFile,'Original report is locked: %s',miShort(lockedReport.message));
    reportFile = fullfile(reportFolder, ...
        ['Reference_Mesh_Report_' datestr(now,'yyyymmdd_HHMMSS') '.xlsx']);
end
for s = 1:5
    try
        miWriteSheet(reportFile,excelSheets{s},studyNames{s},studyTags{s}, ...
            definitions{s},results,meshNames,comparisonTimeStep_min,ismember(s,[2,5]),s);
        miLog(logFile,'  Worksheet %d/5: %s',s,excelSheets{s});
    catch excelME
        miLog(logFile,'  FAILED worksheet %s: %s',excelSheets{s},miShort(excelME.message));
    end
end
miLog(logFile,'ALL DONE in %.2f min',toc(wholeTest)/60);
miLog(logFile,'Report: %s',reportFile);
miLog(logFile,'Log: %s',logFile);
miLog(logFile,'MAT checkpoint: %s',checkpointFile);
end

%% LOCAL FUNCTIONS
function defs = miReadDefinitions(model,tags)
% I treat every expression in a Derived Value as a separate comparison row.
defs = repmat(struct('tag','','index',0,'name','','unit','','expr',''),0,1);
for j=1:numel(tags)
    tag = tags{j};
    feat = model.result.numerical(tag);
    expr = miStrings(feat,'expr');
    descr = miStrings(feat,'descr');
    unit = miStrings(feat,'unit');
    label = char(feat.label());
    if isempty(expr)
        defs(end+1,1) = struct('tag',tag,'index',1,'name',label, ...
            'unit','','expr','[Expression unavailable]'); %#ok<AGROW>
        continue;
    end
    for p=1:numel(expr)
        % Some exported nodes contain empty expression slots (av11).
        % They are not physical quantities and should not enter the report.
        if isempty(strtrim(expr{p})), continue; end
        text = miPick(descr,p,label);
        if isempty(strtrim(text)), text = label; end
        defs(end+1,1) = struct('tag',tag,'index',p,'name',text, ...
            'unit',miPick(unit,p,''),'expr',expr{p}); %#ok<AGROW>
    end
end
end

function out = miCollectValues(model,defs,dataset,isTimeDependent)
% The numerical features keep their COMSOL selections and cut-plane data.
% I only read the results; I do not redefine any physical expression.
out.time_min = [];
out.values = cell(numel(defs),1);
out.errors = repmat({''},numel(defs),1);
if isTimeDependent
    rawTime = double(mphglobal(model,'t/(1[min])', ...
        'dataset',dataset,'solnum','all'));
    out.time_min = rawTime(:);
    assert(~isempty(out.time_min) && all(isfinite(out.time_min)), ...
        'No valid time values in %s.',dataset);
end
allTags = unique({defs.tag},'stable');
for j=1:numel(allTags)
    tag=allTags{j};
    idx=find(strcmp({defs.tag},tag));
    try
        feat=model.result.numerical(tag);
        exprStrings=miStrings(feat,'expr');
        validCols=find(~cellfun(@(x) isempty(strtrim(x)),exprStrings));
        nExpr=numel(idx);
        try
            M=double(feat.getReal(true));
        catch firstME
            % COMSOL sometimes rejects the empty slot in a numerical
            % expression list. Only in that case I evaluate a cleaned list.
            if numel(validCols)==numel(exprStrings)
                rethrow(firstME);
            end
            feat.set('expr',exprStrings(validCols));
            descrStrings=miStrings(feat,'descr');
            unitStrings=miStrings(feat,'unit');
            if numel(descrStrings)>=max(validCols)
                feat.set('descr',descrStrings(validCols));
            end
            if numel(unitStrings)>=max(validCols)
                feat.set('unit',unitStrings(validCols));
            end
            M=double(feat.getReal(true));
        end
        if size(M,2)~=nExpr && size(M,1)==nExpr
            M=M.';
        end
        % The original numerical feature may include placeholder columns.
        if size(M,2)==numel(exprStrings)
            for p=1:nExpr
                out.values{idx(p)}=M(:,defs(idx(p)).index);
            end
        elseif size(M,2)==nExpr
            for p=1:nExpr
                out.values{idx(p)}=M(:,p);
            end
        else
            error('Unexpected number of columns in %s (%d).',tag,size(M,2));
        end
        for p=1:nExpr
            if isTimeDependent
                assert(numel(out.values{idx(p)})==numel(out.time_min), ...
                    '%s returned an incompatible time series.',tag);
            else
                assert(isscalar(out.values{idx(p)}), ...
                    '%s returned more than one stationary value.',tag);
            end
        end
    catch ME
        for p=reshape(idx,1,[])
            out.errors{p}=miShort(ME.message);
        end
    end
end
end

function miWriteSheet(file,sheet,titleText,studyTag,defs,results,meshNames,step,transient,s)
% I prefer one row per quantity and one column per mesh: it is easier to
% compare values and percentage differences than four separate tables.
nMeshes=numel(meshNames);
writecell({sprintf('MESH INDEPENDENCE - %s',titleText)},file,'Sheet',sheet,'Range','A1');
writecell({'All four mesh tests use the same geometry, reference inputs and custom solvers.'}, ...
    file,'Sheet',sheet,'Range','A2');
if transient
    writecell({'Final values are at each mesh''s own stopping time. See the common-time section below.'}, ...
        file,'Sheet',sheet,'Range','A3');
else
    writecell({'Stationary solutions: values are evaluated after convergence.'}, ...
        file,'Sheet',sheet,'Range','A3');
end

% Mesh statistics and solver performance.
info = cell(9,5);
info(1,:) = [{'Mesh'},meshNames];
info(2,1) = {'COMSOL mesh tag'};
info(3,1) = {'Total mesh elements'};
info(4,1) = {'Volume elements'};
info(5,1) = {'Mean element quality'};
info(6,1) = {'Minimum element quality'};
info(7,1) = {'Solver time [s]'};
info(8,1) = {'Study status'};
info(9,1) = {'Final simulation time [min]'};
for m=1:nMeshes
    info{2,m+1}=results(m).meshTag{s};
    info{3,m+1}=results(m).totalElements(s);
    info{4,m+1}=results(m).volumeElements(s);
    info{5,m+1}=results(m).averageQuality(s);
    info{6,m+1}=results(m).minimumQuality(s);
    info{7,m+1}=results(m).solverTime_s(s);
    info{8,m+1}=results(m).status{s};
    if transient && ~isempty(results(m).study(s).time_min)
        info{9,m+1}=results(m).study(s).time_min(end);
    end
end
writecell(info,file,'Sheet',sheet,'Range','A5');

% All Derived Values, including multiple expressions in one COMSOL node.
writecell({'FINAL STATE / STATIONARY VALUES'},file,'Sheet',sheet,'Range','A16');
head = [{'Description','Unit','Derived Value','COMSOL expression'},meshNames, ...
    {'Custom vs Fine [%]','Coarser vs Fine [%]','Normal vs Fine [%]'}];
writecell(head,file,'Sheet',sheet,'Range','A17');
rows = cell(numel(defs)+(transient~=0),11);
for d=1:numel(defs)
    rows(d,1:4)={defs(d).name,defs(d).unit,defs(d).tag,defs(d).expr};
    vals=nan(1,4);
    for m=1:4
        v=results(m).study(s).values{d};
        if ~isempty(v), vals(m)=v(end); end
        rows{d,m+4}=vals(m);
    end
    diffs=miDifferences(vals);
    rows(d,9:11)=num2cell(diffs);
end
if transient
    d=numel(defs)+1;
    rows(d,1:4)={'Simulation duration','min','solver','t_final - t_initial'};
    vals=nan(1,4);
    for m=1:4
        t=results(m).study(s).time_min;
        if numel(t)>=2, vals(m)=t(end)-t(1); end
        rows{d,m+4}=vals(m);
    end
    rows(d,9:11)=num2cell(miDifferences(vals));
end
writecell(rows,file,'Sheet',sheet,'Range','A18');
nextRow = 18+size(rows,1)+3;

% It is not physically meaningful to compare temperature at 300 min with
% temperature at 360 min just because both are the final solution. Here I
% additionally compare the quantities at the same physical time.
if transient
    writecell({'COMMON-TIME COMPARISON'},file,'Sheet',sheet, ...
        'Range',sprintf('A%d',nextRow));
    nextRow=nextRow+1;
    writecell({'Values are linearly interpolated from the saved COMSOL solutions.'}, ...
        file,'Sheet',sheet,'Range',sprintf('A%d',nextRow));
    nextRow=nextRow+1;
    headTime=[{'Time [min]','Description','Unit','Derived Value'}, ...
        meshNames,{'Custom vs Fine [%]','Coarser vs Fine [%]','Normal vs Fine [%]'}];
    writecell(headTime,file,'Sheet',sheet,'Range',sprintf('A%d',nextRow));
    nextRow=nextRow+1;

    % Compare only simulations that actually reached the study in question.
    tStarts=[]; tEnds=[];
    for m=1:4
        t=results(m).study(s).time_min;
        if numel(t)>=2
            tStarts(end+1)=t(1); %#ok<AGROW>
            tEnds(end+1)=t(end); %#ok<AGROW>
        end
    end
    if isempty(tEnds)
        writecell({'No transient results available.'},file,'Sheet',sheet, ...
            'Range',sprintf('A%d',nextRow));
    else
        lo=max(tStarts); hi=min(tEnds);
        if hi>=lo
            tGrid=lo:step:hi;
            if isempty(tGrid) || abs(tGrid(end)-hi)>1e-7
                tGrid=[tGrid hi]; % Include the last time common to all valid cases.
            end
            allRows=cell(numel(tGrid)*numel(defs),11);
            r=0;
            for it=1:numel(tGrid)
                for d=1:numel(defs)
                    r=r+1;
                    allRows(r,1:4)={tGrid(it),defs(d).name,defs(d).unit,defs(d).tag};
                    vals=nan(1,4);
                    for m=1:4
                        t=results(m).study(s).time_min;
                        v=results(m).study(s).values{d};
                        if ~isempty(t) && numel(t)==numel(v) && ~isempty(v)
                            [uniqueTime,idx]=unique(t(:),'stable');
                            uniqueValues=v(idx);
                            if numel(uniqueTime)>=2 && tGrid(it)>=min(uniqueTime) && ...
                                    tGrid(it)<=max(uniqueTime)
                                vals(m)=interp1(uniqueTime,uniqueValues,tGrid(it),'linear');
                            end
                        end
                        allRows{r,m+4}=vals(m);
                    end
                    allRows(r,9:11)=num2cell(miDifferences(vals));
                end
            end
            writecell(allRows,file,'Sheet',sheet,'Range',sprintf('A%d',nextRow));
            nextRow=nextRow+size(allRows,1)+2;
        end
    end
end

% I record expression-specific failures in the same sheet. I do not hide a
% missing value or silently replace it with zero.
writecell({'EVALUATION NOTES / ERRORS'},file,'Sheet',sheet, ...
    'Range',sprintf('A%d',nextRow));
nextRow=nextRow+1;
issues={};
for m=1:4
    if ~strcmp(results(m).status{s},'SOLVED')
        issues(end+1,:)={meshNames{m},'[STUDY]',results(m).status{s}}; %#ok<AGROW>
    end
    for d=1:numel(defs)
        reason=results(m).study(s).errors{d};
        if ~isempty(reason)
            issues(end+1,:)={meshNames{m},defs(d).tag,reason}; %#ok<AGROW>
        end
    end
end
if isempty(issues), issues={'All completed evaluations reported without errors.','',''}; end
writecell([{'Mesh','Feature','Notes'};issues],file,'Sheet',sheet, ...
    'Range',sprintf('A%d',nextRow));
end

function diff=miDifferences(values)
% I use the Fine physics-controlled mesh as the comparison reference.
% A zero or unavailable reference has no meaningful relative percentage.
diff=nan(1,3);
fine=values(4);
if ~isfinite(fine) || abs(fine)<1e-12, return; end
for i=1:3
    if isfinite(values(i))
        diff(i)=100*abs(values(i)-fine)/abs(fine);
    end
end
end

function strings=miStrings(feature,key)
% Convert COMSOL's Java arrays into ordinary MATLAB cell arrays.
try
    x=feature.getStringArray(key);
    if iscell(x)
        strings=cellfun(@char,x,'UniformOutput',false);
    elseif isstring(x)
        strings=cellstr(x);
    elseif ischar(x)
        strings=cellstr(x);
    else
        strings=cell(1,numel(x));
        for k=1:numel(x), strings{k}=char(x(k)); end
    end
    strings=reshape(strings,1,[]);
catch
    strings={};
end
end

function value=miPick(strings,index,fallback)
if index<=numel(strings)
    value=char(strings{index});
else
    value=fallback;
end
end

function miRemoveModel(tag)
try
    com.comsol.model.util.ModelUtil.remove(tag);
catch
    % The temporary model is not loaded.
end
end

function out=miShort(message)
out=regexprep(char(message),'[\r\n\t]+',' | ');
if numel(out)>300, out=[out(1:297),'...']; end
end

function miLog(file,format,varargin)
msg=sprintf(format,varargin{:});
line=sprintf('[%s] [MESH TEST] %s',datestr(now,'yyyy-mm-dd HH:MM:SS'),msg);
fprintf('%s\n',line);
fid=fopen(file,'a');
if fid>=0
    fprintf(fid,'%s\n',line);
    fclose(fid);
end
end
