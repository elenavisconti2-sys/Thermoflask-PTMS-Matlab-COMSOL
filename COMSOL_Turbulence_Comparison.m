function reportFile = COMSOL_Turbulence_Comparison(algebraicModelFile)
%% TURBULENCE MODEL COMPARISON - REFERENCE THERMOFLASK
% I compare my reference k-epsilon model with Algebraic yPlus.
% Everything else (geometry, material properties, operating parameters and
% meshes) should remain unchanged. Each case is solved from a separate copy.
%
% MATLAB R2022b / COMSOL 6.3 with LiveLink.
%
% Normal use:
%   turbulenceReport = COMSOL_Turbulence_Comparison();
%
% If the automatic conversion is not supported by my COMSOL installation,
% I can prepare the Algebraic yPlus model once in the COMSOL GUI and pass it:
%   turbulenceReport = COMSOL_Turbulence_Comparison('COMSOL_Algebraic_yPlus_Prepared.mph');
%
% The GUI-prepared file must use the ORIGINAL geometry and meshes, and must
% contain a Wall Distance Initialization before the air stationary step.
% The script still recomputes all five studies for a fair comparison.

%% 1. FOLDERS AND OUTPUT FILES
projectFolder = fileparts(mfilename('fullpath'));
referenceFile = fullfile(projectFolder,'COMSOL_Reference.mph');
reportFolder = fullfile(projectFolder,'Reports');
caseFolder = fullfile(reportFolder,'Turbulence_Comparison');
reportFile = fullfile(reportFolder,'Reference_Turbulence_Report.xlsx');
logFile = fullfile(caseFolder,'Turbulence_Comparison_Log.txt');
checkpointFile = fullfile(caseFolder,'Turbulence_Comparison_Checkpoint.mat');
assert(isfile(referenceFile),'Reference model is missing: %s',referenceFile);
if ~isfolder(reportFolder), mkdir(reportFolder); end
if ~isfolder(caseFolder), mkdir(caseFolder); end
if nargin < 1 || isempty(algebraicModelFile)
    algebraicModelFile = '';
elseif ~isfile(algebraicModelFile)
    candidate = fullfile(projectFolder,char(algebraicModelFile));
    assert(isfile(candidate),'Prepared Algebraic yPlus model not found: %s',candidate);
    algebraicModelFile = candidate;
end
try
    if isfile(reportFile), delete(reportFile); end
catch lockedReport
    % Keep older results when a workbook is open in Excel.
    reportFile = fullfile(reportFolder, ...
        ['Reference_Turbulence_Report_' datestr(now,'yyyymmdd_HHMMSS') '.xlsx']);
end
fid = fopen(logFile,'w');
assert(fid>0,'Could not create log file: %s',logFile);
fclose(fid);

studyTags = {'std1','std2','std3','std4','std5'};
studySteps = {'stat','time','stat','stat','time'};
studyNames = {'Thermal oil downhole','Downhole heating', ...
              'Cooling air','Thermal oil upward','Post cooling'};
sheetNames = {'01_Oil_Downhole','02_Downhole_Heating', ...
              '03_Cooling_Air','04_Oil_Upward','05_Post_Cooling'};
datasetTags = {'dset11','dset44','dset46','dset48','dset50'};
numericalTags = { ...
    {'av1','max1','av2'}, ...
    {'max2','av4','av5','av3','min1','max3','int1','int4','int2','int3','gevDownAudit'}, ...
    {'av6','av7','av8','av10','av14'}, ...
    {'av15','max6','av16'}, ...
    {'max4','av11','av12','av13','av17','av18','av19','min2','gevCoolAudit'} ...
};
caseNames = {'k-epsilon reference','Algebraic yPlus'};
caseCodes = {'KE','ALG'};

%% 2. START THE COMSOL CONNECTION AND RECORD MY SETTINGS
import com.comsol.model.util.*
try
    ModelUtil.showProgress(true);
catch
    % Solver progress depends on how LiveLink was started.
end
writeLog(logFile,'TURBULENCE COMPARISON | %s',datestr(now));
writeLog(logFile,'Reference model: %s',referenceFile);
writeLog(logFile,'Only Cooling Air turbulence model should change.');
writeLog(logFile,'Same geometry, same mesh sequence per study, five studies per case.');

emptyMetric = struct('key',{},'tag',{},'description',{},'expression',{}, ...
                     'unit',{},'values',{});
emptyStudy = struct('status','NOT_STARTED','elapsed_s',NaN,'mesh','', ...
                    'times',[],'metrics',emptyMetric,'error','');
results = repmat(struct('name','','code','','modelFile','','study', ...
                        repmat(emptyStudy,1,5),'notes',{{}}),1,2);
for c = 1:2
    results(c).name = caseNames{c};
    results(c).code = caseCodes{c};
end

algebraicReady = true;
algebraicProblem = '';

%% 3. CHECK THE ALGEBRAIC CONVERSION BEFORE ANY LONG RUN
% The k-epsilon reference can take several hours. I therefore test the
% conversion, the Wall Distance Initialization and the air solver first.
% If something is not supported, I want to know now, not after six hours.
if isempty(algebraicModelFile)
    prepTag = 'COMSOL_Turbulence_Preflight';
    removeModel(prepTag);
    try
        writeLog(logFile,'PRE-FLIGHT: checking automatic Algebraic yPlus conversion');
        pre = mphload(referenceFile,prepTag);
        for jj = 1:5
            try, pre.sol(sprintf('sol%d',jj)).clearSolutionData(); catch, end
        end
        switchToAlgebraicYPlus(pre,logFile);
        addWallDistanceInitialization(pre,logFile);
        pre.study('std3').showAutoSequences('sol');
        refreshAirDataset(pre,logFile);
        algebraicModelFile = fullfile(caseFolder,'Turbulence_ALG_Prepared.mph');
        mphsave(pre,algebraicModelFile);
        writeLog(logFile,'PRE-FLIGHT OK: %s',algebraicModelFile);
        removeModel(prepTag);
    catch prepError
        removeModel(prepTag);
        writeLog(logFile,'PRE-FLIGHT FAILED: %s',prepError.message);
        algebraicReady = false;
        algebraicProblem = prepError.message;
        % I still collect the k-epsilon reference results, but I do NOT
        % substitute another turbulence model for the missing Algebraic case.
    end
else
    writeLog(logFile,'Using pre-existing Algebraic yPlus model: %s',algebraicModelFile);
end
if algebraicReady
    try
        checkCaseConsistency(referenceFile,algebraicModelFile,logFile,studyTags,studySteps);
    catch consistencyME
        algebraicReady = false;
        algebraicProblem = consistencyME.message;
        writeLog(logFile,'Algebraic model rejected: %s',consistencyME.message);
    end
end

%% 4. EXECUTE THE TWO COMPLETE STUDY SEQUENCES
% I explicitly compute both cases: comparing a cached k-epsilon solution
% with a fresh Algebraic yPlus run would not give meaningful CPU times.
for c = 1:2
    if c == 2 && ~algebraicReady
        results(c).study(1).status = 'SKIPPED';
        for ss = 2:5
            results(c).study(ss).status = 'SKIPPED';
        end
        results(c).notes{end+1,1} = ['Algebraic yPlus unavailable: ' algebraicProblem];
        writeLog(logFile,'ALG case SKIPPED: %s',algebraicProblem);
        continue;
    end
    tag = sprintf('COMSOL_Turbulence_%s',caseCodes{c});
    model = [];
    writeLog(logFile,'--------------------------------------------------------');
    writeLog(logFile,'START CASE %d/2: %s',c,caseNames{c});
    removeModel(tag);

    try
        if c == 1
            model = mphload(referenceFile,tag);
        else
            model = mphload(algebraicModelFile,tag);
        end

        % This copy starts without any old numerical solutions, even when
        % the reference MPH has already been solved and saved.
        for s = 1:5
            try
                model.sol(sprintf('sol%d',s)).clearSolutionData();
            catch
                % A GUI-prepared model may use different solver tags.
            end
        end

        if c == 2
            % The conversion was checked before starting the expensive runs.
            % This case contains Algebraic yPlus and the wall-distance step.
            assertAlgebraicModel(model);
            refreshAirDataset(model,logFile);
        else
            % The user's manually corrected k-epsilon segregated groups
            % should already be saved in COMSOL_Reference.mph.
            checkReferenceSegregation(model,logFile);
        end

        %% 3B. USE THE SAME MESHES AS THE ORIGINAL MODEL
        % Do NOT set autoMeshSize or regenerate physics-controlled meshes.
        % Since both cases start from the same MPH, the built mesh settings
        % and the mesh choice for each study remain identical.
        for s = 1:5
            studyFeature = model.study(studyTags{s}).feature(studySteps{s});
            try
                meshName = char(studyFeature.mesh('geom1'));
            catch
                meshName = '(COMSOL default mesh)';
            end
            results(c).study(s).mesh = meshName;
        end

        %% 3C. RUN THE FIVE STUDIES IN THE ORIGINAL ORDER
        dependencies = {[],[1],[],[3],[2 4]};
        for s = 1:5
            needed = dependencies{s};
            if any(~strcmp({results(c).study(needed).status},'SOLVED'))
                results(c).study(s).status = 'SKIPPED';
                results(c).study(s).error = 'A required preceding solution failed.';
                writeLog(logFile,'  SKIPPED %s due to missing prerequisite',studyTags{s});
                continue;
            end
            writeLog(logFile,'  START %s [%s] | mesh %s', ...
                studyNames{s},studyTags{s},results(c).study(s).mesh);
            tStudy = tic;
            try
                % I keep the custom solvers for all the unchanged physics.
                % Only std3 uses a newly generated solver in the ALG case.
                model.study(studyTags{s}).runNoGen();
                results(c).study(s).elapsed_s = toc(tStudy);
                results(c).study(s).status = 'SOLVED';
                writeLog(logFile,'  DONE %s | %.1f s (%.1f min)', ...
                    studyNames{s},results(c).study(s).elapsed_s, ...
                    results(c).study(s).elapsed_s/60);

                %% 3D. READ THE ORIGINAL DERIVED VALUES AND TIME SERIES
                [times,metrics,warningsList] = collectStudyResults( ...
                    model,s,datasetTags{s},numericalTags{s});
                results(c).study(s).times = times;
                results(c).study(s).metrics = metrics;
                results(c).notes = [results(c).notes; warningsList(:)]; %#ok<AGROW>
                writeLog(logFile,'    Collected %d derived-value columns',numel(metrics));
                if s == 5
                    % A quick consistency check: the first cooling PCM
                    % temperature should match the last downhole one.
                    downPCM = lastMetric(results(c).study(2),'av4_1');
                    coolPCM = firstMetric(results(c).study(5),'av11_1');
                    if isfinite(downPCM) && isfinite(coolPCM) && ...
                            abs(downPCM-coolPCM)>1
                        msg = sprintf(['Initial PCM mapping differs by %.2f degC ' ...
                            '(downhole %.2f, cooling %.2f).'], ...
                            abs(downPCM-coolPCM),downPCM,coolPCM);
                        results(c).notes{end+1,1} = msg;
                        writeLog(logFile,'    WARNING: %s',msg);
                    end
                end

                try
                    save(checkpointFile,'results','-v7.3');
                catch saveME
                    writeLog(logFile,'WARNING: MATLAB checkpoint: %s',saveME.message);
                end
            catch studyError
                results(c).study(s).elapsed_s = toc(tStudy);
                results(c).study(s).status = 'FAILED';
                results(c).study(s).error = studyError.message;
                results(c).notes{end+1,1} = sprintf('%s failed: %s', ...
                    studyTags{s},studyError.message);
                writeLog(logFile,'  FAILED at %s: %s',studyTags{s},studyError.message);
                try
                    save(checkpointFile,'results','-v7.3');
                catch saveME
                    writeLog(logFile,'WARNING: MATLAB checkpoint: %s',saveME.message);
                end
                % Other independent studies can still be attempted.
            end
        end

        % I save a separate solved MPH for checking the plots in COMSOL.
        % The reference file is never overwritten by this function.
        results(c).modelFile = fullfile(caseFolder, ...
            sprintf('Turbulence_%s_Solved.mph',caseCodes{c}));
        try
            mphsave(model,results(c).modelFile);
            writeLog(logFile,'Saved %s',results(c).modelFile);
        catch saveError
            results(c).notes{end+1,1} = ['MPH save: ' saveError.message];
            writeLog(logFile,'WARNING: Could not save case MPH: %s',saveError.message);
        end
    catch caseError
        results(c).notes{end+1,1} = caseError.message;
        writeLog(logFile,'CASE %s FAILED: %s',caseCodes{c},caseError.message);
        % The error is kept in the log and in the Excel notes; the other
        % model is never silently substituted for Algebraic yPlus.
    end
    removeModel(tag);
end

%% 5. EXPORT ALL THE COMPARISONS TO ONE EXCEL WORKBOOK
try
    writeComparison(results,sheetNames,studyNames,reportFile,logFile);
catch excelME
    writeLog(logFile,'WARNING: Excel comparison export failed: %s',excelME.message);
end
try
    save(checkpointFile,'results','-v7.3');
catch saveME
    writeLog(logFile,'WARNING: MATLAB checkpoint: %s',saveME.message);
end
writeLog(logFile,'FINISHED | Excel (if available): %s',reportFile);
end

%% LOCAL FUNCTIONS -------------------------------------------------------

function checkCaseConsistency(referenceFile,algebraicFile,logFile,studyTags,studySteps)
% Do this before the expensive calculations. Two models with different
% geometric dimensions or different mesh tags would not be a valid test.
tagA = 'Turbulence_Compare_CheckRef';
tagB = 'Turbulence_Compare_CheckAlg';
removeModel(tagA); removeModel(tagB);
try
    A = mphload(referenceFile,tagA);
    B = mphload(algebraicFile,tagB);
    parameters = {'SK_length','SK_height','INS1_l','INS2_l','PCM_SH_l', ...
        'd_int','tube_s','AirHE_l','fin_extension','fin_pitch', ...
        'fin_thick','v_air','v_oil_down','v_oil_up'};
    for k = 1:numel(parameters)
        p = parameters{k};
        va = char(A.param('par5').get(p));
        vb = char(B.param('par5').get(p));
        assert(strcmp(va,vb), ...
            'Parameter %s differs between the two models (%s vs %s).',p,va,vb);
    end
    for k = 1:numel(studyTags)
        aa = char(A.study(studyTags{k}).feature(studySteps{k}).mesh('geom1'));
        bb = char(B.study(studyTags{k}).feature(studySteps{k}).mesh('geom1'));
        assert(strcmp(aa,bb), ...
            'Study %s uses different mesh tags: %s vs %s.',studyTags{k},aa,bb);
        writeLog(logFile,'CONSISTENCY: %s uses mesh %s in both models',studyTags{k},aa);
    end
    assertAlgebraicModel(B);
    writeLog(logFile,'Consistency check passed: same parameters and mesh tags.');
catch ME
    removeModel(tagA); removeModel(tagB);
    rethrow(ME);
end
removeModel(tagA); removeModel(tagB);
end

function switchToAlgebraicYPlus(model,logFile)
% The available property keys can vary with the physics interface.
% I inspect the actual COMSOL property list rather than guessing a token.
phys = model.component('comp1').physics('Cooling_Air');
propTags = toCell(phys.prop().tags());
changed = false;
for ig = 1:numel(propTags)
    ptag = propTags{ig};
    p = phys.prop(ptag);
    props = toCell(p.properties());
    for ip = 1:numel(props)
        pname = props{ip};
        if isempty(regexpi(pname,'turb.*model|model.*turb|rans.*model','once'))
            continue;
        end
        try
            allowed = toCell(p.getAllowedPropertyValues(pname));
        catch
            allowed = {};
        end
        for j = 1:numel(allowed)
            option = allowed{j};
            if ~isempty(regexpi(option,'algebraic|yplus|y_plus|alg.*plus','once'))
                p.set(pname,option);
                actual = char(p.getString(pname));
                assert(strcmpi(actual,option), ...
                    'COMSOL did not accept Algebraic yPlus option %s',option);
                changed = true;
                writeLog(logFile,'Algebraic yPlus set using %s/%s = %s', ...
                    ptag,pname,option);
                break;
            end
        end
        if changed, break; end
    end
    if changed, break; end
end
if ~changed
    error('Unable to locate a supported Algebraic yPlus physics property in Cooling_Air.');
end
phys.label('Turbulent Flow, Algebraic yPlus - test');
% Existing feature selections and artificial slip walls remain untouched.
% I check them later in the copied model; no new geometry is created.
end

function addWallDistanceInitialization(model,logFile)
% COMSOL 6.3 requires a Wall Distance Initialization study step before
% solving Algebraic yPlus in Stationary. This is NOT optional.
st = model.study('std3');
existing = toCell(st.feature().tags());
if any(strcmp(existing,'wdinit'))
    writeLog(logFile,'Wall Distance Initialization already exists.');
    return;
end
st.create('wdinit','WallDistanceInitialization');
st.feature().move('wdinit',0);
% Use the very same mesh chosen by the stationary air study.
meshTag = char(st.feature('stat').mesh('geom1'));
if ~isempty(meshTag)
    st.feature('wdinit').mesh('geom1',meshTag);
end
writeLog(logFile,'Wall Distance Initialization inserted before std3/stat.');
end

function assertAlgebraicModel(model)
% I check the actual turbulence-model selection. A label is not sufficient:
% it would be too easy to rename k-epsilon without changing its equations.
phys = model.component('comp1').physics('Cooling_Air');
propTags = toCell(phys.prop().tags());
isAlgebraic = false;
for ig = 1:numel(propTags)
    p = phys.prop(propTags{ig});
    keys = toCell(p.properties());
    for ik = 1:numel(keys)
        if isempty(regexpi(keys{ik},'turb.*model|model.*turb|rans.*model','once'))
            continue;
        end
        try
            current = char(p.getString(keys{ik}));
            if ~isempty(regexpi(current,'algebraic|yplus|y_plus|alg.*plus','once'))
                isAlgebraic = true;
                break;
            end
        catch
        end
    end
    if isAlgebraic, break; end
end
assert(isAlgebraic, ...
    ['Cooling_Air does not report Algebraic yPlus in its physics properties. ' ...
     'I will not compare two mislabeled k-epsilon cases.']);
st = model.study('std3');
steps = toCell(st.feature().tags());
assert(any(strcmp(steps,'wdinit')) || ...
       any(cellfun(@(x) contains(lower(x),'wd'),steps)), ...
       'The prepared std3 study is missing Wall Distance Initialization.');
end

function refreshAirDataset(model,logFile)
% COMSOL may attach a new solver tag when it regenerates only study std3.
% I keep the old Results dataset linked to the CURRENT air solution.
sols = toCell(model.study('std3').getSolverSequences('SolverSequence'));
if isempty(sols)
    error('No solver sequence is attached to the updated Cooling Air study.');
end
solTag = sols{end};
if ~strcmp(solTag,'sol3')
    model.result.dataset('dset46').set('solution',solTag);
    writeLog(logFile,'Air Results dataset dset46 -> %s',solTag);
else
    writeLog(logFile,'Air Results dataset dset46 -> sol3');
end
end

function checkReferenceSegregation(model,logFile)
% This only warns: the reference solution is never modified here.
try
    v = model.sol('sol3').feature('s1').feature('se1').feature('ss1').getStringArray('segvar');
    if isempty(v)
        writeLog(logFile,['WARNING: the saved reference still has an empty ' ...
            'first segregated step. Save your corrected COMSOL_Reference.mph first.']);
    end
catch
    writeLog(logFile,'Could not inspect reference Segregated Step 1.');
end
end

function [times,metrics,notes] = collectStudyResults(model,studyNo,dset,tags)
% Every derived-value column gets its description from the Results tree.
% One malformed feature should not hide the other values.
notes = {};
metrics = struct('key',{},'tag',{},'description',{},'expression',{}, ...
                 'unit',{},'values',{});
if ismember(studyNo,[2,5])
    times = double(mphglobal(model,'t/(1[min])', ...
        'dataset',dset,'solnum','all'));
    times = times(:);
else
    times = [];
end
for it = 1:numel(tags)
    tag = tags{it};
    try
        feat = model.result.numerical(tag);
        expr = toCell(feat.getStringArray('expr'));
        descr = toCell(feat.getStringArray('descr'));
        units = toCell(feat.getStringArray('unit'));
        data = double(feat.getReal(true));
        if size(data,2) ~= numel(expr) && size(data,1) == numel(expr)
            data = data.';
        end
        if size(data,2) ~= numel(expr)
            error('Expected %d expressions, obtained %d result columns.', ...
                numel(expr),size(data,2));
        end
        if ~isempty(times) && size(data,1) ~= numel(times)
            error('Number of solutions does not match the time vector.');
        end
        for j = 1:numel(expr)
            if isempty(strtrim(expr{j}))
                notes{end+1,1} = sprintf('%s expression %d is empty',tag,j); %#ok<AGROW>
                continue;
            end
            m.key = sprintf('%s_%d',tag,j);
            m.tag = tag;
            m.description = safeGet(descr,j,char(feat.label()));
            m.expression = expr{j};
            m.unit = safeGet(units,j,'');
            m.values = data(:,j);
            metrics(end+1) = m; %#ok<AGROW>
        end
    catch ME
        notes{end+1,1} = sprintf('%s: %s',tag,ME.message); %#ok<AGROW>
    end
end
% These two quantities were not in my original Derived Values group.
% I evaluate them directly over the named Cooling Air domain selection.
if studyNo == 3
    extraExpressions = {'Cooling_Air.U','Cooling_Air.U'};
    extraNames = {'Average air velocity','Maximum air velocity'};
    extraTags = {'airMeanU','airMaxU'};
    for jj = 1:2
        try
            if jj == 1
                v = mphmean(model,extraExpressions{jj},3, ...
                    'dataset',dset,'selection','geom1_sel37');
            else
                v = mphmax(model,extraExpressions{jj},3, ...
                    'dataset',dset,'selection','geom1_sel37');
            end
            v = double(v);
            assert(numel(v)==1 && isfinite(v),'No valid scalar air velocity');
            m.key = [extraTags{jj} '_1'];
            m.tag = extraTags{jj};
            m.description = extraNames{jj};
            m.expression = extraExpressions{jj};
            m.unit = 'm/s';
            m.values = v;
            metrics(end+1) = m; %#ok<AGROW>
        catch ME
            notes{end+1,1} = sprintf('%s: %s',extraNames{jj},ME.message); %#ok<AGROW>
        end
    end
end
end

function writeComparison(results,sheets,names,reportFile,logFile)
% I keep the data flat in Excel: each line is a result (stationary) or a
% time instant (transient). No nested table, no thousands of stacked rows.
writecell({'TURBULENCE MODEL COMPARISON'},reportFile, ...
    'Sheet','Overview','Range','A1');
writecell({'Reference','k-epsilon';'Alternative','Algebraic yPlus'; ...
    'Same mesh','Study mesh tags copied from COMSOL_Reference.mph'; ...
    'Relative difference','100*(ALG-KE)/abs(KE)'; ...
    'Important','Compare both solver time and physical outputs'; ...
    'Generated',datestr(now)},reportFile,'Sheet','Overview','Range','A3');
writecell({'Study','k-eps status','ALG status','k-eps [min]', ...
    'ALG [min]','Speed-up KE/ALG','k-eps mesh','ALG mesh'}, ...
    reportFile,'Sheet','Overview','Range','A12');
summary = cell(5,8);
for s = 1:5
    a = results(1).study(s);
    b = results(2).study(s);
    ratio = NaN;
    if isfinite(a.elapsed_s) && isfinite(b.elapsed_s) && b.elapsed_s>0
        ratio = a.elapsed_s/b.elapsed_s;
    end
    summary(s,:) = {names{s},a.status,b.status, ...
        a.elapsed_s/60,b.elapsed_s/60,ratio,a.mesh,b.mesh};
end
writecell(summary,reportFile,'Sheet','Overview','Range','A13');

notes = {'Model','Study','Message'};
for c = 1:2
    for s = 1:5
        if ~isempty(results(c).study(s).error)
            notes(end+1,:) = {results(c).name,names{s}, ...
                results(c).study(s).error}; %#ok<AGROW>
        end
    end
    for j = 1:numel(results(c).notes)
        notes(end+1,:) = {results(c).name,'Results', ...
            results(c).notes{j}}; %#ok<AGROW>
    end
end
writecell(notes,reportFile,'Sheet','Export_Notes','Range','A1');

for s = 1:5
    a = results(1).study(s);
    b = results(2).study(s);
    [keys,labels,units] = allMetrics(a.metrics,b.metrics);
    isTime = ismember(s,[2,5]);
    if isTime
        grid = unique([a.times(:);b.times(:)]);
        grid = grid(isfinite(grid));
        header = {'Time [min]'};
        values = grid;
    else
        header = {'Description / Derived Value','Unit','Expression'};
        values = cell(0,6);
    end
    if isTime
        for k = 1:numel(keys)
            A = metricSeries(a,keys{k},grid,true);
            B = metricSeries(b,keys{k},grid,true);
            rel = 100*(B-A)./max(abs(A),1e-12);
            keyLabel = sprintf('%s [%s]',labels{k},keys{k});
            if ~isempty(units{k}), keyLabel = [keyLabel ' (' units{k} ')']; end
            header(end+1:end+3) = {[keyLabel ' | k-eps'], ...
                [keyLabel ' | Algebraic yPlus'],[keyLabel ' | Delta [%]']}; %#ok<AGROW>
            values(:,end+1:end+3) = [A B rel]; %#ok<AGROW>
        end
        writecell({sprintf('%s | transient values vs time',names{s})}, ...
            reportFile,'Sheet',sheets{s},'Range','A1');
        writecell({'Time grids are aligned by linear interpolation; no extrapolation.'}, ...
            reportFile,'Sheet',sheets{s},'Range','A2');
        writecell(header,reportFile,'Sheet',sheets{s},'Range','A4');
        if ~isempty(values)
            writematrix(values,reportFile,'Sheet',sheets{s},'Range','A5');
        end
    else
        values = cell(numel(keys),6);
        for k = 1:numel(keys)
            A = metricSeries(a,keys{k},[],false);
            B = metricSeries(b,keys{k},[],false);
            rel = NaN;
            if isfinite(A) && isfinite(B)
                rel = 100*(B-A)/max(abs(A),1e-12);
            end
            values(k,:) = {labels{k},units{k},metricExpr(a,b,keys{k}), ...
                A,B,rel};
        end
        writecell({names{s}},reportFile,'Sheet',sheets{s},'Range','A1');
        writecell([header,{'k-epsilon','Algebraic yPlus','Delta [%]'}], ...
            reportFile,'Sheet',sheets{s},'Range','A4');
        if ~isempty(values)
            writecell(values,reportFile,'Sheet',sheets{s},'Range','A5');
        end
    end
end

%% ADDITIONAL COMPARISON METRICS FOR CFD AND THERMAL PERFORMANCE
% These are derived from the original COMSOL selections, not estimates.
extra = {'Quantity','Unit','k-epsilon','Algebraic yPlus','Difference [%]'};
requested = { ...
    'Air pressure drop (inlet - outlet)','Pa',3,'av14_1','av10_1'; ...
    'Velocity at first fin','m/s',3,'av6_1',''; ...
    'Velocity at second fin','m/s',3,'av7_1',''; ...
    'Average air speed (entire cooling-air domain)','m/s',3,'airMeanU_1',''; ...
    'Maximum air speed (entire cooling-air domain)','m/s',3,'airMaxU_1',''; ...
    'Average wall resolution','1',3,'av8_1',''; ...
    'Air outlet temperature (post cooling final)','degC',5,'av19_1',''; ...
    'Heat source temperature (post cooling final)','degC',5,'av13_1',''; ...
    'PCM minimum solid fraction (post cooling final)','1',5,'min2_1',''; ...
    'Thermal oil temperature at fins - inlet (final)','degC',5,'av17_1',''; ...
    'Thermal oil temperature at fins - outlet (final)','degC',5,'av18_1','' ...
};
for k = 1:size(requested,1)
    aa = results(1).study(requested{k,3});
    bb = results(2).study(requested{k,3});
    val1 = lastMetric(aa,requested{k,4});
    val2 = lastMetric(bb,requested{k,4});
    if ~isempty(requested{k,5})
        val1 = val1-lastMetric(aa,requested{k,5});
        val2 = val2-lastMetric(bb,requested{k,5});
    end
    pct = NaN;
    if isfinite(val1) && isfinite(val2)
        pct = 100*(val2-val1)/max(abs(val1),1e-12);
    end
    extra(end+1,:) = {requested{k,1},requested{k,2},val1,val2,pct}; %#ok<AGROW>
end
for k = [2 5]
    aa = results(1).study(k).times;
    bb = results(2).study(k).times;
    val1 = NaN; val2 = NaN;
    if numel(aa)>1, val1 = aa(end)-aa(1); end
    if numel(bb)>1, val2 = bb(end)-bb(1); end
    pct = NaN;
    if isfinite(val1) && isfinite(val2)
        pct = 100*(val2-val1)/max(abs(val1),1e-12);
    end
    extra(end+1,:) = {[names{k} ' duration'],'min',val1,val2,pct}; %#ok<AGROW>
end
writecell(extra,reportFile,'Sheet','Key_Indicators','Range','A1');
writecell({'The total air-side heat removal is not reported unless an', ...
           'appropriate heat-flux integration boundary is defined in COMSOL.'}, ...
           reportFile,'Sheet','Key_Indicators','Range','A18');
writeLog(logFile,'Excel comparison updated: %s',reportFile);
end

function [keys,labels,units] = allMetrics(a,b)
keys = {}; labels = {}; units = {};
for src = {a,b}
    m = src{1};
    for k = 1:numel(m)
        if ~ismember(m(k).key,keys)
            keys{end+1} = m(k).key; %#ok<AGROW>
            labels{end+1} = m(k).description; %#ok<AGROW>
            units{end+1} = m(k).unit; %#ok<AGROW>
        end
    end
end
end

function v = metricSeries(st,key,grid,isTime)
v = NaN(max(1,numel(grid)),1);
idx = find(strcmp({st.metrics.key},key),1);
if isempty(idx), return; end
source = double(st.metrics(idx).values(:));
if ~isTime
    if ~isempty(source), v = source(end); end
    return;
end
x = double(st.times(:));
if numel(x) ~= numel(source) || isempty(x), return; end
[x,ix] = unique(x,'stable');
source = source(ix);
if numel(x)==1
    v(abs(grid-x) < 1e-9) = source(1);
elseif numel(x)>1
    [x,ii] = sort(x);
    source = source(ii);
    v = interp1(x,source,grid,'linear',NaN);
end
end

function expr = metricExpr(a,b,key)
expr = '';
for m = {a.metrics,b.metrics}
    id = find(strcmp({m{1}.key},key),1);
    if ~isempty(id), expr = m{1}(id).expression; return; end
end
end

function x = lastMetric(st,key)
x = NaN;
idx = find(strcmp({st.metrics.key},key),1);
if ~isempty(idx) && ~isempty(st.metrics(idx).values)
    x = double(st.metrics(idx).values(end));
end
end

function x = firstMetric(st,key)
x = NaN;
idx = find(strcmp({st.metrics.key},key),1);
if ~isempty(idx) && ~isempty(st.metrics(idx).values)
    x = double(st.metrics(idx).values(1));
end
end

function out = safeGet(c,k,default)
if k <= numel(c) && ~isempty(c{k}), out = c{k};
else, out = default;
end
end

function c = toCell(javaArray)
% Java string arrays are not MATLAB cell arrays in every LiveLink version.
if isempty(javaArray), c = {}; return; end
if ischar(javaArray), c = {javaArray}; return; end
if isstring(javaArray), c = cellstr(javaArray); return; end
if iscell(javaArray)
    c = cellfun(@char,javaArray,'UniformOutput',false);
    return;
end
c = cell(1,numel(javaArray));
for k = 1:numel(javaArray), c{k} = char(javaArray(k)); end
end

function removeModel(tag)
try
    com.comsol.model.util.ModelUtil.remove(tag);
catch
    % The temporary model may not have been loaded yet.
end
end

function writeLog(logFile,fmt,varargin)
message = sprintf(fmt,varargin{:});
line = sprintf('[%s] %s',datestr(now,'yyyy-mm-dd HH:MM:SS'),message);
fprintf('%s\n',line);
fid = fopen(logFile,'a');
if fid>0
    fprintf(fid,'%s\n',line);
    fclose(fid);
end
end
