function reportFile = COMSOL_Step_Independence(maxCases)
%% TIME-STEP INDEPENDENCE - DOWNHOLE AND POST COOLING
% I compare the two transient studies with three maximum BDF time steps:
% 2 min, 1 min and 0.5 min. The other solver settings stay unchanged.
%
% The stationary oil/air solutions are read from my solved reference MPH.
% I recompute Downhole Heating before each Post Cooling run, so both
% transients within a case use the same maximum time step.
%
% Full comparison:
%   COMSOL_Step_Independence();
%
% Quick check with the 2-minute case only:
%   COMSOL_Step_Independence(1);
%
% Output: Reports\Reference_Step_Report.xlsx
% There are only two sheets: Downhole_Heating and Post_Cooling.
%
% MATLAB R2022b / COMSOL 6.3 with LiveLink for MATLAB.

%% 1. MY FILES AND THE THREE TEST CASES
% All scripts live in the same folder. I never overwrite the reference MPH.
projectFolder = fileparts(mfilename('fullpath'));
modelFile = fullfile(projectFolder,'COMSOL_Reference.mph');
reportsFolder = fullfile(projectFolder,'Reports');
reportFile = fullfile(reportsFolder,'Reference_Step_Report.xlsx');
logFile = fullfile(reportsFolder,'Reference_Step_Report_Log.txt');
dataFile = fullfile(reportsFolder,'Reference_Step_Report_Data.mat');

maxSteps_min = [2, 1, 0.5];
labels = {'2 min','1 min','0.5 min'};
if nargin < 1 || isempty(maxCases)
    maxCases = numel(maxSteps_min);
end
validateattributes(maxCases,{'numeric'},{'scalar','integer','>=',1,'<=',3});
assert(isfile(modelFile), ...
    'Reference MPH is missing: %s. Run COMSOL_builder and COMSOL_ReferenceRun first.',modelFile);
if ~isfolder(reportsFolder), mkdir(reportsFolder); end

% I keep these tags in one place in case I change the Results tree later.
studyTags = {'std2','std5'};
solverTags = {'sol2','sol5'};
datasetTags = {'dset44','dset50'};
sheetNames = {'Downhole_Heating','Post_Cooling'};
featureTags = { ...
    {'max2','av4','av5','av3','min1','max3', ...
     'int1','int4','int2','int3','gevDownAudit'}, ...
    {'max4','av11','av12','av13','av17','av18','av19', ...
     'min2','gevCoolAudit'} ...
};

fid=fopen(logFile,'w');
assert(fid>=0,'Cannot create the step-independence log: %s',logFile);
fclose(fid);
siLog(logFile,'STEP INDEPENDENCE - %s',datestr(now));
siLog(logFile,'Reference model: %s',modelFile);
siLog(logFile,'Maximum steps: 2, 1, 0.5 min. Cases selected: %d/3',maxCases);

import com.comsol.model.util.*
try
    ModelUtil.showProgress(true);
catch
    % My own progress messages are enough if the COMSOL display is unavailable.
end

%% 2. READ MY DERIVED VALUES AND CHECK THE REFERENCE SOLUTIONS
% I take descriptions, units and expressions from the COMSOL model itself.
% In particular, I do not rebuild selections or rewrite the physics here.
siRemoveModel('StepIndependenceCatalog');
reference = mphload(modelFile,'StepIndependenceCatalog');
try
    for k = [1 3 4]
        assert(~reference.sol(sprintf('sol%d',k)).isEmpty(), ...
            ['Stationary solution sol%d is empty. Run COMSOL_ReferenceRun ' ...
             'before starting the step-independence test.'],k);
    end
    definitions = cell(1,2);
    for s = 1:2
        definitions{s} = siReadDefinitions(reference,featureTags{s});
        assert(~isempty(definitions{s}), ...
            'No Derived Values were found for %s.',studyTags{s});
        siLog(logFile,'%s: %d derived expressions found', ...
            studyTags{s},numel(definitions{s}));
    end
catch ME
    siRemoveModel('StepIndependenceCatalog');
    rethrow(ME);
end
siRemoveModel('StepIndependenceCatalog');
clear reference

%% 3. PREPARE THE MATLAB RESULTS
% I store each case separately, including warnings, so that an unsuccessful
% evaluation is visible in Excel instead of being mistaken for zero.
cases = repmat(struct(),1,3);
for c = 1:3
    cases(c).step_min = maxSteps_min(c);
    cases(c).label = labels{c};
    cases(c).status = {'NOT RUN','NOT RUN'};
    cases(c).solveTime_s = [NaN NaN];
    cases(c).study = struct([]);
    for s = 1:2
        cases(c).study(s).time_min = [];
        cases(c).study(s).values = repmat({[]},numel(definitions{s}),1);
        cases(c).study(s).errors = repmat({''},numel(definitions{s}),1);
    end
end

%% 4. RUN DOWNHOLE, THEN POST COOLING, FOR EACH MAXIMUM TIME STEP
% Loading the MPH again each time keeps the cases independent. The three
% stationary solutions are already available and do not need recalculating:
% changing the time-step limit has no effect on these stationary studies.
allTimer = tic;
for c = 1:maxCases
    siLog(logFile,'-----------------------------------------------------------');
    siLog(logFile,'CASE %d/%d - maximum time step %.1f min', ...
        c,maxCases,maxSteps_min(c));
    modelTag = 'StepIndependenceCase';
    siRemoveModel(modelTag);
    model = [];
    try
        model = mphload(modelFile,modelTag);

        % First remove the old transient solutions stored in the reference
        % MPH. I leave sol1, sol3 and sol4 untouched.
        model.sol('sol5').clearSolutionData();
        model.sol('sol2').clearSolutionData();

        % These are the internal BDF steps, not the 5-minute output times.
        % Both transient solvers use minutes as their time unit.
        for s = 1:2
            timeSolver = model.sol(solverTags{s}).feature('t1');
            timeSolver.set('maxstepconstraintbdf','const');
            timeSolver.set('maxstepbdf',maxSteps_min(c));
            siLog(logFile,'  %s: maximum BDF step = %.1f min', ...
                solverTags{s},maxSteps_min(c));
        end

        % I explicitly keep the last Downhole solution as the initial
        % thermal state of Post Cooling. Upward oil/air fields still come
        % from the precomputed sol4, as in the reference model.
        model.study('std5').feature('time').set('solnum','last');
        model.sol('sol5').feature('v1').set('solnum','last');

        %% 4A. DOWNHOLE HEATING
        siLog(logFile,'  START std2 - Downhole Heating');
        tSolve = tic;
        try
            model.study('std2').runNoGen();
            cases(c).solveTime_s(1) = toc(tSolve);
            cases(c).status{1} = 'SOLVED';
            siLog(logFile,'  std2 solved in %.1f s',cases(c).solveTime_s(1));
        catch ME2
            cases(c).status{1} = ['FAILED: ' siShort(ME2.message)];
            cases(c).status{2} = 'SKIPPED: Downhole failed';
            siLog(logFile,'  ERROR in std2: %s',siShort(ME2.message));
            % Post Cooling must not use a failed or incomplete Downhole run.
        end
        if strcmp(cases(c).status{1},'SOLVED')
            try
                cases(c).study(1) = siCollect(model,definitions{1},datasetTags{1});
                siLog(logFile,'  Downhole last stored time: %.3f min', ...
                    cases(c).study(1).time_min(end));
            catch readME
                cases(c).study(1).errors(:) = {siShort(readME.message)};
                siLog(logFile,'  WARNING: Downhole results extraction: %s', ...
                    siShort(readME.message));
            end
        end

        %% 4B. POST COOLING
        if strcmp(cases(c).status{1},'SOLVED')
            siLog(logFile,'  START std5 - Post Cooling');
            tSolve = tic;
            try
                model.study('std5').runNoGen();
                cases(c).solveTime_s(2) = toc(tSolve);
                cases(c).status{2} = 'SOLVED';
                siLog(logFile,'  std5 solved in %.1f s',cases(c).solveTime_s(2));
            catch ME5
                cases(c).status{2} = ['FAILED: ' siShort(ME5.message)];
                siLog(logFile,'  ERROR in std5: %s',siShort(ME5.message));
            end
            if strcmp(cases(c).status{2},'SOLVED')
                try
                    cases(c).study(2) = siCollect(model,definitions{2},datasetTags{2});
                    siLog(logFile,'  Post Cooling last stored time: %.3f min', ...
                        cases(c).study(2).time_min(end));
                catch readME
                    cases(c).study(2).errors(:) = {siShort(readME.message)};
                    siLog(logFile,'  WARNING: Post Cooling results extraction: %s', ...
                        siShort(readME.message));
                end
            end
        end

    catch caseME
        for s = 1:2
            if strcmp(cases(c).status{s},'NOT RUN')
                cases(c).status{s} = ['FAILED: ' siShort(caseME.message)];
            end
        end
        siLog(logFile,'  ERROR preparing case: %s',siShort(caseME.message));
    end

    % I keep a lightweight MATLAB checkpoint. I do not save modified MPH
    % files, because this comparison should not replace COMSOL_Reference.
    try
        save(dataFile,'cases','definitions','maxSteps_min','-v7.3');
    catch saveME
        siLog(logFile,'  WARNING: checkpoint not saved: %s',siShort(saveME.message));
    end
    siRemoveModel(modelTag);
    clear model
end

%% 5. EXPORT MY TWO TIME-SERIES SHEETS
% Each row is a physical time. Each quantity has three value columns and
% two percentage-difference columns, with 0.5 min as the reference.
% I only interpolate between saved times; I never extrapolate a transient
% after its stop condition has been reached.
siLog(logFile,'Writing the final Excel report ...');
try
    if isfile(reportFile), delete(reportFile); end
catch cleanME
    siLog(logFile,'WARNING: existing report locked: %s',siShort(cleanME.message));
    reportFile = fullfile(reportsFolder, ...
        ['Reference_Step_Report_' datestr(now,'yyyymmdd_HHMMSS') '.xlsx']);
end
for s = 1:2
    try
        siWriteSheet(reportFile,sheetNames{s},studyTags{s}, ...
            definitions{s},cases,maxSteps_min,labels,s);
    catch excelME
        siLog(logFile,'WARNING: worksheet %s failed: %s',sheetNames{s},siShort(excelME.message));
    end
end
siLog(logFile,'Excel report: %s',reportFile);
siLog(logFile,'MATLAB checkpoint: %s',dataFile);
siLog(logFile,'Total elapsed time: %.2f min',toc(allTimer)/60);
end

%% LOCAL FUNCTIONS - RESULT DEFINITIONS
function defs = siReadDefinitions(model,tags)
% I retain the original Description, Unit and COMSOL expression for each
% nonempty Derived Value. Some old result features contain blank slots.
defs = struct('tag',{},'index',{},'description',{},'unit',{},'expr',{});
for k = 1:numel(tags)
    tag = tags{k};
    feat = model.result.numerical(tag);
    expr = siStrings(feat,'expr');
    descr = siStrings(feat,'descr');
    units = siStrings(feat,'unit');
    nodeLabel = char(feat.label());
    for j = 1:numel(expr)
        expression = strtrim(expr{j});
        if isempty(expression), continue; end
        name = siPick(descr,j,nodeLabel);
        if isempty(strtrim(name)), name = nodeLabel; end
        defs(end+1) = struct( ... %#ok<AGROW>
            'tag',tag,'index',j,'description',name, ...
            'unit',siPick(units,j,''),'expr',expression);
    end
end
end

%% LOCAL FUNCTIONS - EXTRACT THE COMPLETE TIME SERIES
function output = siCollect(model,defs,dataset)
% COMSOL returns the selected Derived Values in the order of its stored
% solution times. The numerical features retain their original domains,
% boundaries and cut-plane datasets.
output.time_min = double(mphglobal(model,'t/(1[min])', ...
    'dataset',dataset,'solnum','all'));
output.time_min = output.time_min(:);
assert(~isempty(output.time_min) && all(isfinite(output.time_min)), ...
    'No stored times found in %s.',dataset);
assert(all(diff(output.time_min)>=0), ...
    'Stored times are not ordered in %s.',dataset);

nT = numel(output.time_min);
output.values = repmat({[]},numel(defs),1);
output.errors = repmat({''},numel(defs),1);
allTags = unique({defs.tag},'stable');
for k = 1:numel(allTags)
    tag = allTags{k};
    idx = find(strcmp({defs.tag},tag));
    feat = model.result.numerical(tag);

    % I remove blank expression slots from the working copy only.
    originalExpr = siStrings(feat,'expr');
    valid = find(~cellfun(@(x) isempty(strtrim(x)),originalExpr));
    if numel(valid) ~= numel(originalExpr)
        feat.set('expr',originalExpr(valid));
        originalDescr = siStrings(feat,'descr');
        originalUnits = siStrings(feat,'unit');
        if numel(originalDescr) >= max(valid)
            feat.set('descr',originalDescr(valid));
        end
        if numel(originalUnits) >= max(valid)
            feat.set('unit',originalUnits(valid));
        end
    end

    try
        raw = double(feat.getReal(true));
        M = siOrient(raw,nT,numel(idx),tag);
        for j = 1:numel(idx)
            output.values{idx(j)} = M(:,j);
        end
    catch groupedME
        % A single invalid expression should not hide the other results
        % in the same feature (for example, mean temperature and phase).
        for j = 1:numel(idx)
            d = defs(idx(j));
            try
                feat.set('expr',{d.expr});
                feat.set('descr',{d.description});
                if ~isempty(d.unit), feat.set('unit',{d.unit}); end
                raw = double(feat.getReal(true));
                M = siOrient(raw,nT,1,tag);
                output.values{idx(j)} = M(:,1);
            catch singleME
                output.errors{idx(j)} = siShort(singleME.message);
                if isempty(output.errors{idx(j)})
                    output.errors{idx(j)} = siShort(groupedME.message);
                end
            end
        end
    end
end
end

function M = siOrient(M,nTimes,nColumns,tag)
% getReal(true) is columnwise: time runs down the rows.
if isequal(size(M),[nColumns nTimes]) && ...
        ~isequal(size(M),[nTimes nColumns])
    M=M.';
end
assert(isequal(size(M),[nTimes nColumns]), ...
    'Result %s has size %dx%d; expected %dx%d.', ...
    tag,size(M,1),size(M,2),nTimes,nColumns);
end

%% LOCAL FUNCTIONS - TWO WORKSHEETS, TIME IN THE FIRST COLUMN
function siWriteSheet(file,sheet,studyTag,defs,cases,steps,labels,s)
writecell({sprintf('TIME-STEP INDEPENDENCE - %s',studyTag)}, ...
    file,'Sheet',sheet,'Range','A1');
writecell({'Same mesh and physical parameters. Only the maximum BDF time step changes.'}, ...
    file,'Sheet',sheet,'Range','A2');
writecell({'Reference for percentage differences: 0.5 min. Values are compared at the same physical time.'}, ...
    file,'Sheet',sheet,'Range','A3');

% A short overview makes it easy to tell whether all three solvers finished.
summary = cell(5,4);
summary(1,:) = [{'Run information'},labels];
summary(2,1) = {'Maximum time step [min]'};
summary(3,1) = {'Solver status'};
summary(4,1) = {'Solver time [s]'};
summary(5,1) = {'Last stored time [min]'};
for c = 1:3
    summary{2,c+1} = steps(c);
    summary{3,c+1} = cases(c).status{s};
    summary{4,c+1} = cases(c).solveTime_s(s);
    t = cases(c).study(s).time_min;
    if ~isempty(t), summary{5,c+1} = t(end); end
end
writecell(summary,file,'Sheet',sheet,'Range','A5');

% I use the union of stored times. When a solver stops earlier, its later
% values remain blank; this avoids inventing data beyond the stop event.
allTimes = [];
for c = 1:3
    allTimes = [allTimes; cases(c).study(s).time_min(:)]; %#ok<AGROW>
end
allTimes = unique(round(allTimes,8),'sorted');
nValues = numel(defs);
columnCount = 1+5*nValues;
headers = cell(1,columnCount);
headers{1} = 'Time [min]';
comparison = nan(max(1,numel(allTimes)),columnCount);
if ~isempty(allTimes)
    comparison(:,1) = allTimes;
end

for d = 1:nValues
    def = defs(d);
    base = sprintf('%s [%s] (%s)',def.description,def.unit,def.tag);
    firstCol = 2+(d-1)*5;
    for c = 1:3
        headers{firstCol+c-1} = sprintf('%s | %s',base,labels{c});
        t = cases(c).study(s).time_min;
        v = cases(c).study(s).values{d};
        if ~isempty(allTimes) && ~isempty(t) && numel(t)==numel(v)
            comparison(:,firstCol+c-1) = siInterpolate(t,v,allTimes);
        end
    end
    headers{firstCol+3} = sprintf('%s | 2 vs 0.5 min [%%]',base);
    headers{firstCol+4} = sprintf('%s | 1 vs 0.5 min [%%]',base);
    reference = comparison(:,firstCol+2);
    for c = 1:2
        current = comparison(:,firstCol+c-1);
        comparison(:,firstCol+2+c) = siRelativeDifference(current,reference);
    end
end

writecell({'TIME HISTORIES - every row is one saved physical time'}, ...
    file,'Sheet',sheet,'Range','A11');
writecell(headers,file,'Sheet',sheet,'Range','A12');
if ~isempty(allTimes)
    writematrix(comparison,file,'Sheet',sheet,'Range','A13');
else
    writecell({'No transient solutions available.'},file,'Sheet',sheet,'Range','A13');
end

% I also collect a compact error summary for each derived quantity.
% For percentages I exclude zero reference values rather than divide by 0.
summaryRow = 15+numel(allTimes);
writecell({'CONVERGENCE SUMMARY - compared only over common available times'}, ...
    file,'Sheet',sheet,'Range',sprintf('A%d',summaryRow));
writecell({'Description','Unit','Derived Value','Expression', ...
    'Max |2 min - 0.5 min|','Max |1 min - 0.5 min|', ...
    'Max relative difference, 2 min [%]','Max relative difference, 1 min [%]'}, ...
    file,'Sheet',sheet,'Range',sprintf('A%d',summaryRow+1));
summaryRows = cell(nValues,8);
for d = 1:nValues
    firstCol = 2+(d-1)*5;
    ref = comparison(:,firstCol+2);
    a = comparison(:,firstCol);
    b = comparison(:,firstCol+1);
    relA = comparison(:,firstCol+3);
    relB = comparison(:,firstCol+4);
    summaryRows(d,:) = {defs(d).description,defs(d).unit, ...
        defs(d).tag,defs(d).expr, ...
        siMaxFinite(abs(a-ref)),siMaxFinite(abs(b-ref)), ...
        siMaxFinite(relA),siMaxFinite(relB)};
end
writecell(summaryRows,file,'Sheet',sheet, ...
    'Range',sprintf('A%d',summaryRow+2));

% Any failed extraction is recorded in the same worksheet; I do not add a
% third sheet just to collect error messages.
errorRow = summaryRow+numel(defs)+5;
writecell({'NOTES / FAILED EVALUATIONS'},file,'Sheet',sheet, ...
    'Range',sprintf('A%d',errorRow));
issues = cell(0,3);
for c = 1:3
    if ~strcmp(cases(c).status{s},'SOLVED')
        issues(end+1,:) = {labels{c},'[STUDY]',cases(c).status{s}}; %#ok<AGROW>
    end
    for d = 1:nValues
        reason = cases(c).study(s).errors{d};
        if ~isempty(reason)
            issues(end+1,:) = {labels{c},defs(d).tag,reason}; %#ok<AGROW>
        end
    end
end
if isempty(issues)
    issues = {'All completed evaluations reported without errors.','',''};
end
writecell([{'Max step','Derived Value','Note'};issues], ...
    file,'Sheet',sheet,'Range',sprintf('A%d',errorRow+1));
end

function y = siInterpolate(timeValues,values,queryTimes)
% Interpolation is needed only when the solver stored an extra stop time.
y = nan(numel(queryTimes),1);
t = double(timeValues(:));
v = double(values(:));
[t,idx] = unique(t,'sorted');
v = v(idx);
if isempty(t), return; end
if numel(t)==1
    y(abs(queryTimes-t)<1e-7) = v(1);
else
    y = interp1(t,v,queryTimes,'linear',NaN);
end
end

function result = siRelativeDifference(value,reference)
% When the reference passes through zero, a percentage is meaningless.
result = nan(size(value));
valid = isfinite(value) & isfinite(reference) & abs(reference)>1e-12;
result(valid) = 100*abs(value(valid)-reference(valid))./abs(reference(valid));
end

function result = siMaxFinite(x)
x = x(isfinite(x));
if isempty(x)
    result = NaN;
else
    result = max(x);
end
end

%% LOCAL FUNCTIONS - SMALL MATLAB / COMSOL UTILITIES
function strings = siStrings(feat,key)
try
    raw = feat.getStringArray(key);
    if iscell(raw)
        strings = cellfun(@char,raw,'UniformOutput',false);
    elseif isstring(raw)
        strings = cellstr(raw);
    elseif ischar(raw)
        strings = cellstr(raw);
    else
        strings = cell(1,numel(raw));
        for k = 1:numel(raw), strings{k} = char(raw(k)); end
    end
    strings = reshape(strings,1,[]);
catch
    strings = {};
end
end

function value = siPick(source,index,fallback)
if index<=numel(source)
    value=char(source{index});
else
    value=fallback;
end
end

function siRemoveModel(tag)
try
    com.comsol.model.util.ModelUtil.remove(tag);
catch
    % There is no temporary model with this tag.
end
end

function msg = siShort(message)
msg = regexprep(char(message),'[\r\n\t]+',' | ');
if numel(msg)>350, msg=[msg(1:347),'...']; end
end

function siLog(file,format,varargin)
message = sprintf(format,varargin{:});
line = sprintf('[%s] [STEP TEST] %s',datestr(now,'yyyy-mm-dd HH:MM:SS'),message);
fprintf('%s\n',line);
fid = fopen(file,'a');
if fid>=0
    fprintf(fid,'%s\n',line);
    fclose(fid);
end
end
