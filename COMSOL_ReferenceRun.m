function model = COMSOL_ReferenceRun(modelFile, lastStudy, resultFile)
%% MY THERMOFLASK MODEL - RUN THE FIVE STUDIES IN ORDER
% MATLAB R2022b + COMSOL 6.3 LiveLink for MATLAB.
%
% First create the fresh model:
%   COMSOL_builder();
%
% Then run all the studies:
%   COMSOL_ReferenceRun();
%
% To run only std1/std2 (diagnose transfer before post-cooling):
%   COMSOL_ReferenceRun([],2);
%
% INPUT/OUTPUT:
%   Default input:     D:\Elena\COMSOL_Reference.mph
%   Default output:    D:\Elena\COMSOL_Reference.mph
%   Progress checkpoint (overwritten at each completed stage):
%                      D:\Elena\COMSOL_Reference_Progress.mph
%
% I use runNoGen() to preserve my existing custom sol1...sol5 settings.
% No UQ/Morris study (std6) is run. Do not use this diagnostic run for MOAT.
%
% If a stage fails, the last completed stage remains saved in Progress.mph.
%
% The Excel report is saved inside Reports and includes all the Derived Values
% defined for each study, with time along the rows for transient studies.
% If an evaluation fails, I write the reason to the Export_Index sheet.
%
% I need to check the first run in COMSOL before trusting the results.
% I save the Command Window messages to a text file for troubleshooting.

if nargin < 1 || isempty(modelFile)
    modelFile = fullfile('D:\Elena','COMSOL_Reference.mph');
end
if nargin < 2 || isempty(lastStudy)
    lastStudy = 5;
end
if nargin < 3 || isempty(resultFile)
    resultFile = fullfile('D:\Elena','COMSOL_Reference.mph');
end
validateattributes(lastStudy,{'numeric'},{'scalar','integer','>=',1,'<=',5});
modelFile = char(modelFile);
resultFile = char(resultFile);
assert(isfile(modelFile),'Input MPH not found: %s', modelFile);
progressFile = fullfile(fileparts(resultFile),'COMSOL_Reference_Progress.mph');
if ~isfolder(fileparts(resultFile))
    mkdir(fileparts(resultFile));
end

%% 1. CREATE A CLEAN RUN LOG
% I keep the checkpoint and the log separate. The checkpoint contains the
% numerical model; the log helps me see which study was last completed.
[resultFolder,resultBase] = fileparts(resultFile);
if isempty(resultFolder), resultFolder = pwd; end
logFile = fullfile(resultFolder,[resultBase '_RunStudies_Log.txt']);
errorFile = fullfile(resultFolder,[resultBase '_RunStudies_Error.txt']);
fid = fopen(logFile,'w');
assert(fid >= 0,'Cannot create study log: %s',logFile);
fclose(fid);
allStudiesTimer = tic;
currentStage = 'LOAD_MODEL';

tfOpen5Log(logFile,'==============================================================');
tfOpen5Log(logFile,'COMSOL REFERENCE - STUDY RUNNER');
tfOpen5Log(logFile,'Input MPH: %s',modelFile);
tfOpen5Log(logFile,'Output MPH: %s',resultFile);
tfOpen5Log(logFile,'Checkpoint: %s',progressFile);

%% 2. PREPARE THE REFERENCE REPORT
% I create a new dated workbook for every reference simulation. This also
% keeps the previous reports when I rebuild the model.
reportsFolder = fullfile(resultFolder,'Reports');
if ~isfolder(reportsFolder), mkdir(reportsFolder); end
reportStamp = datestr(now,'yyyy-mm-dd_HHMMSS');
reportFile = fullfile(reportsFolder,['REF_00_' reportStamp '.xlsx']);
version = 1;
while isfile(reportFile)
    reportFile = fullfile(reportsFolder, ...
        sprintf('REF_00_%s_%02d.xlsx',reportStamp,version));
    version = version + 1;
end
reportIndex = cell(0,7);
reportStats = cell(0,4);
reportCreated = datestr(now,'yyyy-mm-dd HH:MM:SS');
tfOpen5Log(logFile,'Reference report: %s',reportFile);
reportOK = true;
try
    refExcelHeader(reportFile,modelFile,reportCreated);
catch excelME
    reportOK = false;
    tfOpen5Log(logFile,'WARNING: Excel initialization failed: %s',excelME.message);
    % A spreadsheet lock should never discard an otherwise valid COMSOL run.
end

import com.comsol.model.util.*
modelTag = 'COMSOLReferenceStudyRun';
try
    ModelUtil.remove(modelTag);
catch
    % No previous model with this temporary tag.
end
% COMSOL's own solver messages are useful, but may depend on how LiveLink
% was started. My study summaries are printed regardless.
try
    ModelUtil.showProgress(true);
    tfOpen5Log(logFile,'COMSOL solver progress display requested.');
catch progressME
    tfOpen5Log(logFile,'COMSOL progress display unavailable: %s',progressME.message);
end

try
currentStage = 'LOAD_MODEL';
stepTimer = tic;
tfOpen5Log(logFile,'START: Loading fresh MPH');
model = mphload(modelFile,modelTag);
tfOpen5Log(logFile,'DONE: Loading fresh MPH (%.1f s)',toc(stepTimer));
if reportOK
    try
        refWriteParameters(model,reportFile);
    catch parME
        tfOpen5Log(logFile,'WARNING: Could not export reference parameters: %s',parME.message);
    end
end
studies = {'std1','std2','std3','std4','std5'};
names = {'Thermal Oil Stationary', 'Downhole Heating', ...
         'Cooling Air Stationary', 'Thermal Oil Upward', 'Post Cooling'};

%% 2. CHECK THE STUDY ORDER AND IMPORTANT ASSUMPTIONS
% I explicitly run the oil and air stationary studies before Post Cooling.
% I keep the last Downhole solution as the initial temperature for cooling.
% These messages describe the intended settings; LiveLink will still need
% to confirm that the temperature transfer worked.
% Verify the two key solver configuration properties before computing.
tfOpen5Log(logFile,'Input: %s',modelFile);
tfOpen5Log(logFile,'Expected BDF max step: 1 min for sol2 and sol5.');
tfOpen5Log(logFile,'Expected Post Cooling initialization: last saved solution of sol2.');

%% 3. RUN THE STUDIES ONE BY ONE
% A failed study does not end the entire run. I can still solve another
% independent study, but I never use missing data to initialize a transient.
% Dependencies: Downhole <- oil down; Oil upward <- cooling air;
% Post cooling <- Downhole + upward oil (and hence cooling air).
dependencies = {[],[1],[],[3],[2 4]};
studySolved = false(1,5);
for k = 1:lastStudy
    needed = dependencies{k};
    if any(~studySolved(needed))
        missing = sprintf('std%d ',needed(~studySolved(needed)));
        tfOpen5Log(logFile,'SKIPPED %s: missing solution(s) %s',studies{k},strtrim(missing));
        reportStats(end+1,:) = {studies{k},names{k},'SKIPPED - DEPENDENCY',NaN}; %#ok<AGROW>
        if reportOK
            try, refWriteReportIndex(reportFile,reportIndex,reportStats); catch, end
        end
        continue;
    end
    currentStage = sprintf('STUDY_%s',studies{k});
    tfOpen5Log(logFile,'START %d/%d: %s (%s)',k,lastStudy,names{k},studies{k});
    t0 = tic;
    try
        model.study(studies{k}).runNoGen();
    catch ME
        elapsed = toc(t0);
        tfOpen5Log(logFile,'FAILED %s after %.1f s: %s',studies{k},elapsed,ME.message);
        reportStats(end+1,:) = {studies{k},names{k},'FAILED',elapsed}; %#ok<AGROW>
        failFile = fullfile(resultFolder,sprintf('%s_%s_Error.txt',resultBase,studies{k}));
        fidError = fopen(failFile,'w');
        if fidError >= 0
            fprintf(fidError,'%s\n',getReport(ME,'extended','hyperlinks','off'));
            fclose(fidError);
        end
        tfOpen5Log(logFile,'Continuing with independent studies; error log: %s',failFile);
        if reportOK
            try, refWriteReportIndex(reportFile,reportIndex,reportStats); catch, end
        end
        continue;
    end
    studySolved(k) = true;
    studySeconds = toc(t0);
    tfOpen5Log(logFile,'DONE  %s, elapsed: %.1f s (%.2f min)',studies{k},studySeconds,studySeconds/60);
    reportStats(end+1,:) = {studies{k},names{k},'SOLVED',studySeconds}; %#ok<AGROW>


    tfOpen5Log(logFile,'Checking available diagnostics for %s',studies{k});

    % Diagnostic: verify that Downhole really produces the temperature
    % expected in the PCM, before attempting the Post Cooling mapping.
    if k == 2
        try
            pcmK = mphglobal(model,'comp1.avgPCM_UQ(comp1.T)', ...
                'dataset','dset44','solnum','end','unit','K');
            tfOpen5Log(logFile,'Downhole final mean PCM: %.3f K (%.3f degC)', ...
                pcmK(1),pcmK(1)-273.15);
        catch diagME
            tfOpen5Log(logFile,'WARNING: Downhole PCM temperature - %s',diagME.message);
            warning('Elena:DiagnosticDownhole', ...
                'Unable to evaluate final PCM temperature: %s',diagME.message);
        end
    end
    if k == 5
        try
            initPCM = mphglobal(model,'comp1.avgPCM_UQ(comp1.T)', ...
                'dataset','dset50','solnum',1,'unit','K');
            tfOpen5Log(logFile,'Post Cooling initial mean PCM: %.3f K (%.3f degC)', ...
                initPCM(1),initPCM(1)-273.15);
        catch diagME
            tfOpen5Log(logFile,'WARNING: Post Cooling initial PCM - %s',diagME.message);
            warning('Elena:DiagnosticCooling', ...
                'Unable to evaluate Post Cooling initial PCM temperature: %s',diagME.message);
        end
        try
            finalPCM = mphglobal(model,'comp1.minPCMsolid_UQ(comp1.Upward_Cooling.theta1)', ...
                'dataset','dset50','solnum','end');
            tfOpen5Log(logFile,'Post Cooling final minimum solid fraction: %.5f',finalPCM(1));
        catch diagME
            tfOpen5Log(logFile,'WARNING: PCM solid fraction - %s',diagME.message);
            warning('Elena:DiagnosticSolid', ...
                'Unable to evaluate final PCM fraction: %s',diagME.message);
        end
    end

    %% 4. UPDATE THE TIME-SERIES RESULTS AFTER EACH TRANSIENT
    % I populate these tables only after the corresponding solution exists.
    % Populate clean time-series tables only after their transients exist.
    % The original COMSOL export included tbl3/tbl7 but never populated them.
    if k == 2
        try
            model.result.numerical('gevDownAudit').setResult();
            tfOpen5Log(logFile,'Downhole time-series table tbl3 updated.');
        catch MEtable
            tfOpen5Log(logFile,'WARNING: Downhole time-series table - %s',MEtable.message);
            warning('Elena:DownholeTable', ...
                'Downhole time-series table not populated: %s',MEtable.message);
        end
    elseif k == 5
        try
            model.result.numerical('gevCoolAudit').setResult();
            tfOpen5Log(logFile,'Post Cooling time-series table tbl7 updated.');
        catch MEtable
            tfOpen5Log(logFile,'WARNING: Post Cooling time-series table - %s',MEtable.message);
            warning('Elena:PostCoolingTable', ...
                'Post Cooling time-series table not populated: %s',MEtable.message);
        end
        % Compare mapping independently of the phase-based stop condition.
        try
            tc0 = mphglobal(model,'comp1.avgDHS_UQ(comp1.T)', ...
                'dataset','dset50','solnum',1,'unit','degC');
            tcf = mphglobal(model,'comp1.avgDHS_UQ(comp1.T)', ...
                'dataset','dset50','solnum','end','unit','degC');
            tfOpen5Log(logFile,'Post Cooling heat source: initial %.3f degC, final %.3f degC',tc0(1),tcf(1));
            if tcf(1) > 30
                tfOpen5Log(logFile,'WARNING: final heat source temperature > 30 degC.');
                warning('Elena:HeatSource30', ...
                    'Post Cooling ended with heat-source mean > 30 degC. Current solver stop checks only PCM fraction.');
            end
        catch MEtemp
            tfOpen5Log(logFile,'WARNING: Heat source check - %s',MEtemp.message);
            warning('Elena:PostCoolingTempCheck', ...
                'Could not check 30 degC heat-source target: %s',MEtemp.message);
        end
    end

    %% 5. EXPORT ALL THE DERIVED VALUES FOR THIS STUDY
    % I keep the source descriptions and units in the Excel column names.
    % For transient studies every stored time gets its own Excel row.
    currentStage = sprintf('EXPORT_%s',studies{k});
    if reportOK
        try
            tfOpen5Log(logFile,'Exporting Results for %s ...',studies{k});
            newRows = refExportStudy(model,k,reportFile);
            reportIndex = [reportIndex;newRows]; %#ok<AGROW>
            refWriteReportIndex(reportFile,reportIndex,reportStats);
            tfOpen5Log(logFile,'Excel updated: %s',reportFile);
        catch reportME
            tfOpen5Log(logFile,'WARNING: Excel export for %s: %s',studies{k},reportME.message);
        end
    end

    % I save after every successful study, so I can inspect partial results.
    currentStage = sprintf('SAVE_AFTER_%s',studies{k});
    saveTimer = tic;
    tfOpen5Log(logFile,'Saving checkpoint after %s ...',studies{k});
    try
        mphsave(model,progressFile);
        tfOpen5Log(logFile,'Checkpoint saved in %.1f s: %s',toc(saveTimer),progressFile);
    catch saveME
        % The checkpoint may be open/locked in the graphical COMSOL session.
        backup = fullfile(resultFolder,sprintf('%s_%s_%s.mph', ...
            resultBase,studies{k},datestr(now,'yyyymmdd_HHMMSS')));
        tfOpen5Log(logFile,'Checkpoint locked/unavailable: %s',saveME.message);
        try
            mphsave(model,backup);
            tfOpen5Log(logFile,'Alternative checkpoint: %s',backup);
        catch altME
            tfOpen5Log(logFile,'WARNING: Alternative checkpoint failed: %s',altME.message);
        end
    end
end

%% 6. SAVE THE FINAL MODEL, EVEN IF SOME STUDIES FAILED
% I keep valid partial solutions. A locked output file gets a new filename
% rather than losing the hours already spent solving the model.
currentStage = 'SAVE_FINAL';
completed = nnz(studySolved(1:lastStudy));
tfOpen5Log(logFile,'Finished %d/%d studies successfully.',completed,lastStudy);
saveTimer = tic;
try
    mphsave(model,resultFile);
    finalSavedFile = resultFile;
catch saveME
    tfOpen5Log(logFile,'Final MPH is locked or unavailable: %s',saveME.message);
    finalSavedFile = fullfile(resultFolder, ...
        sprintf('%s_Recovery_%s.mph',resultBase,datestr(now,'yyyymmdd_HHMMSS')));
    try
        mphsave(model,finalSavedFile);
    catch altME
        tfOpen5Log(logFile,'WARNING: recovery save also failed: %s',altME.message);
        finalSavedFile = '(not saved; model remains in MATLAB memory)';
    end
end
tfOpen5Log(logFile,'Final save elapsed: %.1f s',toc(saveTimer));
tfOpen5Log(logFile,'Available model: %s',finalSavedFile);
tfOpen5Log(logFile,'Total run time: %.2f min',toc(allStudiesTimer)/60);
tfOpen5Log(logFile,'Excel report (if available): %s',reportFile);

catch ME
    tfOpen5Log(logFile,'FAILED during %s after %.1f min',currentStage,toc(allStudiesTimer)/60);
    tfOpen5Log(logFile,'ERROR: %s',ME.message);
    tfOpen5Log(logFile,'Last checkpoint (if available): %s',progressFile);
    fid = fopen(errorFile,'w');
    if fid >= 0
        fprintf(fid,'TF_OPEN5 study runner - error report\n');
        fprintf(fid,'Stage: %s\n',currentStage);
        fprintf(fid,'Elapsed: %.1f s\n\n',toc(allStudiesTimer));
        fprintf(fid,'%s\n',getReport(ME,'extended','hyperlinks','off'));
        fclose(fid);
        tfOpen5Log(logFile,'Full error report: %s',errorFile);
    end
    rethrow(ME);
end
end

function tfOpen5Log(logFile,formatText,varargin)
%% LOG TO THE COMMAND WINDOW AND TO MY STUDY FILE
% I use the same message format in the builder and in the study runner.
message = sprintf(formatText,varargin{:});
line = sprintf('[%s] [TF_OPEN5 STUDIES] %s', ...
    datestr(now,'yyyy-mm-dd HH:MM:SS'),message);
fprintf('%s\n',line);
fid = fopen(logFile,'a');
if fid >= 0
    fprintf(fid,'%s\n',line);
    fclose(fid);
else
    warning('Elena:StudyLog','Cannot append to log: %s',logFile);
end
end


function refExcelHeader(fileName,modelFile,created)
%% REFERENCE REPORT - BASIC INFORMATION
% I keep the study results in separate sheets so they are easy to compare.
writecell({'REFERENCE RUN - REF_00'},fileName,'Sheet','Overview','Range','A1');
writecell({'Report created',created;'COMSOL model',modelFile; ...
    'Reference identifier','REF_00';'Notes', ...
    'Time-dependent data: one row per stored solution time.'}, ...
    fileName,'Sheet','Overview','Range','A3');
writecell({'Study','Description','Status','Solver time [s]'}, ...
    fileName,'Sheet','Overview','Range','A10');
writecell({'Study','Derived Value tag','COMSOL description', ...
    'Expression','Unit','Status','Details'}, ...
    fileName,'Sheet','Export_Index','Range','A1');
end

function indexRows = refExportStudy(model,k,fileName)
%% EXTRACT THE DERIVED VALUES ALREADY DEFINED IN COMSOL
% I use the existing COMSOL numerical features, including their original
% selections and expressions. This avoids duplicating the physics in MATLAB.
% The list follows the five groups in the COMSOL Results tree.
tags = { ...
    {'av1','max1','av2'}, ...
    {'max2','av4','av5','av3','min1','max3','int1','int4','int2','int3','gevDownAudit'}, ...
    {'av6','av7','av8','av10','av14'}, ...
    {'av15','max6','av16'}, ...
    {'max4','av11','av12','av13','av17','av18','av19','min2','gevCoolAudit'} ...
    };
workbookSheets = {'01_Oil_Downhole','02_Downhole_Heating', ...
    '03_Cooling_Air','04_Oil_Upward','05_Post_Cooling'};
datasets = {'dset11','dset44','dset46','dset48','dset50'};
stdTags = {'std1','std2','std3','std4','std5'};
isTransient = ismember(k,[2,5]);

sheetName = workbookSheets{k};
dataset = datasets{k};
featureTags = tags{k};
indexRows = cell(0,7);

if isTransient
    try
        timeValues = double(mphglobal(model,'t/(1[min])', ...
            'dataset',dataset,'solnum','all'));
        timeValues = timeValues(:);
        if isempty(timeValues) || any(~isfinite(timeValues))
            error('Empty or invalid time vector in %s',dataset);
        end
    catch timeME
        error('Cannot export time series for %s: %s',stdTags{k},timeME.message);
    end
    values = timeValues;
    headings = {'Time [min]'};
else
    timeValues = [];
    values = zeros(1,0);
    headings = {};
end

for i = 1:numel(featureTags)
    tag = featureTags{i};
    try
        feature = model.result.numerical(tag);
        expressions = refFeatureStrings(feature,'expr');
        descriptions = refFeatureStrings(feature,'descr');
        units = refFeatureStrings(feature,'unit');
        featureName = char(feature.label());
        if isempty(expressions) || all(cellfun(@isempty,expressions))
            error('No expressions defined for this feature');
        end
        % With columnwise=true, each COMSOL expression is a column,
        % and the rows follow the stored solution times.
        matrix = double(feature.getReal(true));
        if isempty(matrix) || ~isnumeric(matrix)
            error('Empty numerical result');
        end
        nExpressions = numel(expressions);
        if size(matrix,2) ~= nExpressions && size(matrix,1) == nExpressions
            matrix = matrix.';
        end
        if size(matrix,2) ~= nExpressions
            error('Expected %d expressions, but got a %d x %d result', ...
                nExpressions,size(matrix,1),size(matrix,2));
        end
        if isTransient && size(matrix,1) ~= numel(timeValues)
            error('Time mismatch: %d values, but %d stored times', ...
                size(matrix,1),numel(timeValues));
        end
        if ~isTransient && size(matrix,1) ~= 1
            error('Expected one stationary value, but found %d rows',size(matrix,1));
        end
        for j = 1:nExpressions
            description = refGetCell(descriptions,j,featureName);
            if isempty(strtrim(description))
                description = featureName;
            end
            unit = refGetCell(units,j,'');
            expression = strtrim(refGetCell(expressions,j,''));
            if isempty(expression)
                error('Expression %d is empty',j);
            end
            heading = sprintf('%s [%s]',description,tag);
            if ~isempty(unit)
                heading = sprintf('%s (%s)',heading,unit);
            end
            headings{end+1} = heading; %#ok<AGROW>
            values(:,end+1) = matrix(:,j); %#ok<AGROW>
            indexRows(end+1,:) = {stdTags{k},tag,description,expression,unit, ...
                'OK',sprintf('%d values',size(matrix,1))}; %#ok<AGROW>
        end
    catch ME
        % A bad selection/expression must not prevent other Results from
        % being exported. I record it instead of silently losing a column.
        indexRows(end+1,:) = {stdTags{k},tag,'','','','FAILED', ...
            refShortError(ME.message)}; %#ok<AGROW>
        warning('COMSOL:DerivedValueExport', ...
            'Study %s, Derived Value %s: %s',stdTags{k},tag,ME.message);
    end
end

% Each time series uses the same time column and one column per result.
% A single stationary row is enough for the two fluid initialization runs.
writecell({sprintf('%s | %s',stdTags{k},sheetName)}, ...
    fileName,'Sheet',sheetName,'Range','A1');
writecell({sprintf('Dataset: %s',dataset); ...
    'Descriptions and units are taken from COMSOL Results -> Derived Values.'}, ...
    fileName,'Sheet',sheetName,'Range','A2');
if isempty(headings)
    writecell({'No valid quantities - check Export_Index'}, ...
        fileName,'Sheet',sheetName,'Range','A5');
else
    writecell(headings,fileName,'Sheet',sheetName,'Range','A5');
    writematrix(values,fileName,'Sheet',sheetName,'Range','A6');
end
end

function refWriteReportIndex(fileName,indexRows,stats)
%% INDEX AND RUN SUMMARY
% I can see exactly which COMSOL results were exported and which failed.
if ~isempty(indexRows)
    writecell(indexRows,fileName,'Sheet','Export_Index','Range','A2');
end
if ~isempty(stats)
    writecell(stats,fileName,'Sheet','Overview','Range','A11');
end
end

function out = refFeatureStrings(feature,propertyName)
% COMSOL returns Java string arrays. I convert them into MATLAB cell arrays.
try
    raw = feature.getStringArray(propertyName);
    if iscell(raw)
        out = cellfun(@char,raw,'UniformOutput',false);
    elseif isstring(raw)
        out = cellstr(raw);
    elseif ischar(raw)
        out = cellstr(raw);
    else
        out = cell(1,numel(raw));
        for ii = 1:numel(raw)
            out{ii} = char(raw(ii));
        end
    end
    out = reshape(out,1,[]);
catch
    out = {};
end
end

function value = refGetCell(source,index,defaultValue)
if index <= numel(source)
    value = char(source{index});
else
    value = defaultValue;
end
end

function shortText = refShortError(errorText)
shortText = regexprep(char(errorText),'[\r\n\t]+',' | ');
if numel(shortText) > 400
    shortText = [shortText(1:397) '...'];
end
end


function refWriteParameters(model,fileName)
%% REFERENCE GEOMETRY AND OPERATING CONDITIONS
% I store the parameter expressions used for the reference configuration.
% The thermoflask length is calculated by COMSOL, not sampled separately.
geometryTags = {'SK_length','SK_height','INS1_l','INS2_l', ...
    'PCM_SH_l','d_int','tube_s','AirHE_l','fin_extension', ...
    'fin_pitch','fin_thick','v_oil_down','v_oil_up','v_air'};
rows = cell(0,3);
for j = 1:numel(geometryTags)
    key = geometryTags{j};
    try
        val = char(model.param('par5').get(key));
    catch
        val = 'Not available';
    end
    rows(end+1,:) = {'par5',key,val}; %#ok<AGROW>
end
try
    val = char(model.param('par7').get('TF_L'));
catch
    val = 'INS1_l+AD_l+SK_length+PCM_SH_l+TWV_l+INS2_l';
end
rows(end+1,:) = {'par7','TF_L',val};
writecell({'Parameter group','Parameter','COMSOL value / expression'}, ...
    fileName,'Sheet','Reference_Inputs','Range','A1');
writecell(rows,fileName,'Sheet','Reference_Inputs','Range','A2');
end
