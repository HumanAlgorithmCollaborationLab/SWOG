USE COSMOS

-- ============================================
-- Create Encounter Cohort
-- ============================================
DROP TABLE IF EXISTS #MyEncounters
SELECT EncounterFact.EncounterKey, EncounterFact.PatientDurableKey, EncounterFact.DateKey, EncounterFact.AttendingProviderDurableKey,
	EncounterFact.AgeKey, EncounterFact.DerivedEncounterType_X, ProviderSpecialtyDimX.Specialty, EncounterFact.IsOutpatientFaceToFaceVisit,
	EncounterFact.Date, EncounterFact.SourceComboKey
INTO #MyEncounters
FROM
  EncounterFact
INNER JOIN
  ProviderSpecialtyDimX
    ON EncounterFact.AttendingProviderDurableKey = ProviderSpecialtyDimX.ProviderDurableKey
WHERE
  ProviderSpecialtyDimX.Specialty  IN (N'Hematology and Oncology', N'Oncology', N'Medical Oncology') AND
  EncounterFact.DerivedEncounterType_X IN (N'Office Visit', N'Hospital Outpatient Visit') AND
  IsOutpatientFaceToFaceVisit = 1 AND
  EncounterFact.DateKey >= 20230101 AND EncounterFact.DateKey <= 20231231 AND
  EncounterFact.Count = 1

-- Sample one encounter per patient
DROP TABLE IF EXISTS #MyEncountersFiltered
SELECT *
INTO #MyEncountersFiltered  
FROM (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY PatientDurableKey ORDER BY NEWID()) AS rn
    FROM #MyEncounters
) ranked
WHERE rn = 1

-- Join to PatientDim
DROP TABLE IF EXISTS #MyCohort
SELECT #MyEncountersFiltered.*, PatientDim.Ethnicity, PatientDim.FirstRace, PatientDim.DeathDate, PatientDim.Status, PatientDim.UseInCosmosAnalytics_X, 
       DurationDim.Years AS Age, CASE WHEN PatientDim.Sex = 'Female' THEN 1 WHEN PatientDim.Sex = 'Male' THEN 0 ELSE NULL END AS Sex
INTO #MyCohort	
FROM #MyEncountersFiltered
INNER JOIN PatientDim 
  ON #MyEncountersFiltered.PatientDurableKey = PatientDim.DurableKey
INNER JOIN DurationDim
  ON #MyEncountersFiltered.AgeKey = DurationDim.DurationKey
WHERE DurationDim.Years >= 18 AND PatientDim.IsCurrent = 1

-- Select Cancer Grouper Codes
DROP TABLE IF EXISTS #GrouperTableparam0004
SELECT DISTINCT DiagnosisKey AS basekey
INTO #GrouperTableparam0004
FROM dbo.DiagnosisSetDim 
WHERE ValueSetEpicId = '9503840' AND Trusted = 1

-- Create flag for cancer diagnosis and 180-day mortality outcome
DROP TABLE IF EXISTS #MyCohortFlagged
SELECT c.*, 
	   CASE WHEN cancer.PatientDurableKey IS NOT NULL THEN 1 ELSE 0 END AS HasCancerDiagnosis,
	   CASE WHEN c.Status = N'Deceased' AND c.DeathDate IS NOT NULL AND DATEDIFF(DAY, c.Date, c.DeathDate) <= 180 THEN 1 ELSE 0 END AS mortality_180
INTO #MyCohortFlagged
FROM #MyCohort c
LEFT JOIN (
    SELECT DISTINCT def.PatientDurableKey
    FROM dbo.DiagnosisEventFact def
    INNER JOIN #GrouperTableparam0004 g ON def.DiagnosisKey = g.basekey
    INNER JOIN #MyCohort c2 ON def.PatientDurableKey = c2.PatientDurableKey
    WHERE def.StartDateKey <= CONVERT(VARCHAR(8), c2.Date, 112)
      AND def.StartDateKey > 0
      AND (def.EndDateKey >= CONVERT(VARCHAR(8), DATEADD(YEAR, -1, c2.Date), 112) OR def.EndDateKey <= 0)
      AND def.[Type] IN ('Encounter Diagnosis','Admitting Diagnosis','Billing Admission Diagnosis','Billing Final Diagnosis','Billing Procedure Linked Diagnosis','Problem List')
) cancer ON c.PatientDurableKey = cancer.PatientDurableKey

-- Filter to cancer-only cohort
DROP TABLE IF EXISTS #CancerCohort
SELECT * INTO #CancerCohort FROM #MyCohortFlagged WHERE HasCancerDiagnosis = 1
-- ====================================================================================================================================
-- QUERY LAB DATA   ===================================================================================================================
-- ====================================================================================================================================
DROP TABLE IF EXISTS #LabStaging
SELECT
    c.PatientDurableKey,
    c.EncounterKey,
    c.Date AS EncounterDate,
    l.LabComponentResultKey,
    l.LabComponentKey,
    l.CollectionInstant,
    l.NumericValue,
    l.Unit,
	l.ReferenceValueLow_X,
	l.ReferenceValueHigh_X,
    d.LoincCode,
    d.LoincName
INTO #LabStaging
FROM #CancerCohort c
INNER JOIN LabComponentResultFact l
    ON c.PatientDurableKey = l.PatientDurableKey
INNER JOIN LabComponentDim d
    ON l.LabComponentKey = d.LabComponentKey
WHERE 
    d.LoincCode IN ('704-7', '26444-0', '706-2', '30180-4', '711-2', '26449-9', '713-8', '26450-7', '17849-1', '4679-7', '14196-0', '60474-4', '26507-4', '763-3', '764-1', '26508-2', '731-0', '26474-7', '736-9', '26478-8', '13046-8', '42250-1', '30412-1', '29262-3', '742-7', '26484-6', '5905-5', '26485-3', '749-2', '26498-6', '6690-2', '26464-8', '787-2', '788-0', '30385-9', '786-4', '28540-3', '771-6', '30392-5', '751-8', '26499-4', '718-7', '785-6', '28539-5', '777-3', '26515-7', '789-8', '26453-1', '778-1', '6768-6', '1920-8', '1742-6', '98979-8', '48643-1', '48642-3', '19123-9', '3094-0', '2345-7', '17861-6', '1975-2', '2777-1', '2160-0', '2028-9', '33037-3', '10466-1', '1863-0', '2524-7', '2075-0', '2951-2', '2823-3', '1751-7', '61151-7', '61152-5', '2862-1', '2885-2', '3255-7', '2276-4', '6301-6', '14979-9', '5902-2', '5964-2', '2466-1', '2472-9', '2458-8', '2571-8', '2093-3', '2532-0', '3084-1', '3016-3', '11580-8', '11579-0', '2039-6')
	AND l.CollectionInstant BETWEEN DATEADD(YEAR, -1, c.Date) AND c.Date
	AND l.NumericValue IS NOT NULL
	AND l.Count = 1
-- ============================================
-- Map LOINC codes to lab names (multiple codes can map to same lab)
-- ============================================
DROP TABLE IF EXISTS #LabMapping
CREATE TABLE #LabMapping (LoincCode VARCHAR(50), ColumnBaseName VARCHAR(100))
INSERT INTO #LabMapping (LoincCode, ColumnBaseName)
VALUES
	('704-7', 'basophils'),
	('26444-0', 'basophils'),
	('706-2', 'basophils_percent'),
	('30180-4', 'basophils_percent'),
	('711-2', 'eosinophils'),
	('26449-9', 'eosinophils'),
	('713-8', 'eosinophils_percent'),
	('26450-7', 'eosinophils_percent'),
	('17849-1', 'reticulocytes_percent'),
	('4679-7', 'reticulocytes_percent'),
	('14196-0', 'reticulocytes'),
	('60474-4', 'reticulocytes'),
	('26507-4', 'band_neutrophils_manual'),
	('763-3', 'band_neutrophils_manual'),
	('764-1', 'band_neutrophils_manual_percent'),
	('26508-2', 'band_neutrophils_manual_percent'),
	('731-0', 'lymphocytes'),
	('26474-7', 'lymphocytes'),
	('736-9', 'lymphocytes_percent'),
	('26478-8', 'lymphocytes_percent'),
	('13046-8', 'variant_lymphocytes_percent'),
	('42250-1', 'variant_lymphocytes_percent'),
	('30412-1', 'abnormal_lymphocytes_manual'),
	('29262-3', 'abnormal_lymphocytes_manual'),
	('742-7', 'monocytes'),
	('26484-6', 'monocytes'),
	('5905-5', 'monocytes_percent'),
	('26485-3', 'monocytes_percent'),
	('749-2', 'myelocytes_manual_percent'),
	('26498-6', 'myelocytes_manual_percent'),
	('6690-2', 'wbc'),
	('26464-8', 'wbc'),
	('787-2', 'mcv'),
	('788-0', 'rdw_percent'),
	('30385-9', 'rdw_percent'),
	('786-4', 'mchc'),
	('28540-3', 'mchc'),
	('771-6', 'nucleated_rbc'),
	('30392-5', 'nucleated_rbc'),
	('751-8', 'neutrophils'),
	('26499-4', 'neutrophils'),
	('718-7', 'hemoglobin'),
	('785-6', 'mch'),
	('28539-5', 'mch'),
	('777-3', 'platelets'),
	('26515-7', 'platelets'),
	('789-8', 'rbc'),
	('26453-1', 'rbc'),
	('778-1', 'rbc'),
	-- Comprehensive Metabolic Panel Labs	
	('6768-6', 'alkaline_phosphatase'),
	('1920-8', 'ast'),
	('1742-6', 'alt'), 
	('98979-8', 'egfr'),
	('48643-1', 'egfr'), -- AA
	('48642-3', 'egfr'), -- non AA
	('19123-9', 'magnesium'), -- can add moles/volume LOINC code 2601-3
	('3094-0', 'urea_nitrogen'),
	('2345-7', 'glucose'),
	('17861-6', 'calcium'),
	('1975-2', 'bilirubin'),
	('2777-1', 'phosphate'),
	('2160-0', 'creatinine'),
	('2028-9', 'carbon_dioxide'),
	('33037-3', 'anion_gap'),
	('10466-1', 'anion_gap'),
	('1863-0', 'anion_gap'),
	('2524-7', 'lactate'),
	('2075-0', 'chloride'),
	('2951-2', 'sodium'),
	('2823-3', 'potassium'),
	('1751-7', 'albumin'),
	('61151-7', 'albumin'),
	('61152-5', 'albumin'),
	('2862-1', 'albumin'),
	('2885-2', 'protein'),
	-- Coagulation Parameters
	('3255-7', 'fibrinogen'),
	('2276-4', 'ferritin'),
	('6301-6', 'inr'),
	('14979-9', 'aptt'),
	('5902-2', 'pt'),
	('5964-2', 'pt'),
	-- Immunoglobulins 
	('2466-1', 'igg'),
	('2472-9', 'igm'),
	('2458-8', 'iga'),
	-- Lipid Panel
	('2571-8', 'triglyceride'),
	('2093-3', 'total_cholesterol'),
	-- Other panels
	('2532-0', 'ldh'),
	('3084-1', 'uric_acid'),
	('3016-3', 'tsh'),
	('11580-8', 'tsh'),
	('11579-0', 'tsh'),
	('2039-6', 'cea')
-- ============================================
-- Filter and Transform lab values. Add lab mapping to staging data
-- ============================================
DROP TABLE IF EXISTS #LabStagingMapped
SELECT ls.PatientDurableKey, ls.EncounterKey, ls.EncounterDate, ls.LabComponentResultKey, ls.LabComponentKey, ls.CollectionInstant, ls.Unit,
	   ls.ReferenceValueLow_X, ls.ReferenceValueHigh_X, ls.LoincCode, ls.LoincName, lm.ColumnBaseName,
	   CASE 
		   WHEN lm.ColumnBaseName IN ('monocytes', 'band_neutrophils', 'nucleated_rbc', 'lymphocytes', 'basophils', 'reticulocytes', 'eosinophils', 'neutrophils', 'platelets') 
				AND ls.NumericValue >= 1000 
		   THEN ls.NumericValue / 1000
		   ELSE ls.NumericValue
	   END as NumericValue
INTO #LabStagingMapped
FROM #LabStaging ls
INNER JOIN #LabMapping lm
   ON ls.LoincCode = lm.LoincCode
WHERE NOT (ls.Unit = '%' AND lm.ColumnBaseName NOT LIKE '%_percent')
   AND NOT (lm.ColumnBaseName LIKE '%_percent' AND (ls.NumericValue < 0 OR ls.NumericValue > 100))
   AND ls.NumericValue < 100000
-- ============================================
-- Aggregate by ColumnBaseName. This combines multiple LOINC codes for the same lab
-- ============================================
DROP TABLE IF EXISTS #LabAggregates
SELECT
    PatientDurableKey,
    EncounterKey,
    ColumnBaseName, -- Group by lab name, not LOINC code
    COUNT(*) AS lab_count,
	STDEV(NumericValue) AS lab_stdev,
    MIN(NumericValue) AS lab_min,
    MAX(NumericValue) AS lab_max,
    MAX(CASE WHEN rn_asc = 1 THEN NumericValue END) AS lab_first,
    MAX(CASE WHEN rn_desc = 1 THEN NumericValue END) AS lab_last
INTO #LabAggregates
FROM (
    SELECT
        ls.PatientDurableKey,
        ls.EncounterKey,
        ls.ColumnBaseName,
        ls.NumericValue,
        ls.CollectionInstant,
        ROW_NUMBER() OVER (
            PARTITION BY ls.PatientDurableKey, ls.EncounterKey, ls.ColumnBaseName
            ORDER BY ls.CollectionInstant ASC
        ) AS rn_asc,
        ROW_NUMBER() OVER (
            PARTITION BY ls.PatientDurableKey, ls.EncounterKey, ls.ColumnBaseName
            ORDER BY ls.CollectionInstant DESC
        ) AS rn_desc
    FROM #LabStagingMapped ls
) sub
GROUP BY PatientDurableKey, EncounterKey, ColumnBaseName

-- ============================================
-- Dynamic SQL generation using unique lab names
-- ============================================
DECLARE @sql NVARCHAR(MAX) = ''
DECLARE @selectCols NVARCHAR(MAX) = ''
DECLARE @joins NVARCHAR(MAX) = ''
DECLARE @baseName VARCHAR(100), @alias VARCHAR(100)
DECLARE @CRLF NVARCHAR(2) = CHAR(13) + CHAR(10)
-- ============================================
-- Cursor now iterates over DISTINCT ColumnBaseName values
-- ============================================
DECLARE lab_cursor CURSOR FOR
SELECT DISTINCT ColumnBaseName FROM #LabMapping
OPEN lab_cursor
FETCH NEXT FROM lab_cursor INTO @baseName
WHILE @@FETCH_STATUS = 0
BEGIN
    -- Create alias for this lab table join
    SET @alias = 'lab_' + REPLACE(REPLACE(@baseName, '-', '_'), '%', 'pct')
    -- Build SELECT columns for this lab's metrics
    SET @selectCols = @selectCols + @CRLF +
        '    ' + @alias + '.lab_count AS ' + @baseName + '_count,' + @CRLF +
		'    ' + @alias + '.lab_stdev AS ' + @baseName + '_stdev,' + @CRLF +
        '    ' + @alias + '.lab_min AS ' + @baseName + '_min,' + @CRLF +
        '    ' + @alias + '.lab_max AS ' + @baseName + '_max,' + @CRLF +
        '    ' + @alias + '.lab_first AS ' + @baseName + '_first,' + @CRLF +
        '    ' + @alias + '.lab_last AS ' + @baseName + '_last,' + @CRLF

    -- Build LEFT JOIN for this lab's aggregated data
    SET @joins = @joins + @CRLF +
        'LEFT JOIN #LabAggregates ' + @alias + @CRLF +
        '    ON c.PatientDurableKey = ' + @alias + '.PatientDurableKey' + @CRLF +
        '   AND c.EncounterKey = ' + @alias + '.EncounterKey' + @CRLF +
        '   AND ' + @alias + '.ColumnBaseName = ''' + @baseName + '''' + @CRLF
    -- Fetch next row from cursor
    FETCH NEXT FROM lab_cursor INTO @baseName
END
-- ============================================
-- Close and deallocate cursor
-- ============================================
CLOSE lab_cursor
DEALLOCATE lab_cursor
-- ============================================
-- Remove trailing comma and newline from SELECT columns string
-- ============================================
SET @selectCols = LEFT(@selectCols, LEN(@selectCols) - 3)
-- ============================================
-- Build and execute final dynamic SQL query
-- ============================================
SET @sql = '
DROP TABLE IF EXISTS ##FinalCohortWithLabs
SELECT
    c.*,' + @selectCols + '
INTO ##FinalCohortWithLabs
FROM #CancerCohort c
' + @joins
EXEC sp_executesql @sql
-- ====================================================================================================================================
-- QUERY COMORBIDITY DATA   ===========================================================================================================
-- ====================================================================================================================================
-- Create Diagnosis Mapping Table (ICD10 Codes <->	Condition Features)
DROP TABLE IF EXISTS #DiagnosisMapping
CREATE TABLE #DiagnosisMapping (ICD10Code VARCHAR(10), DiagnosisType VARCHAR(100))
INSERT INTO #DiagnosisMapping (ICD10Code, DiagnosisType)
VALUES
    -- Alcohol abuse
    ('F10', 'alcohol_abuse'),
    ('E52', 'alcohol_abuse'),
    ('G621', 'alcohol_abuse'),
    ('I426', 'alcohol_abuse'),
    ('K292', 'alcohol_abuse'),
    ('K700', 'alcohol_abuse'),
    ('K703', 'alcohol_abuse'),
    ('K709', 'alcohol_abuse'),
    ('T51', 'alcohol_abuse'),
    ('Z502', 'alcohol_abuse'),
    ('Z714', 'alcohol_abuse'),
    ('Z721', 'alcohol_abuse'),

	-- Cardiac arrhythmias
    ('I441', 'cardiac_arrhythmias'),
    ('I442', 'cardiac_arrhythmias'),
    ('I443', 'cardiac_arrhythmias'),
    ('I456', 'cardiac_arrhythmias'),
    ('I459', 'cardiac_arrhythmias'),
    ('I47', 'cardiac_arrhythmias'),
    ('I48', 'cardiac_arrhythmias'),
    ('I49', 'cardiac_arrhythmias'),
    ('R000', 'cardiac_arrhythmias'),
    ('R001', 'cardiac_arrhythmias'),
    ('R008', 'cardiac_arrhythmias'),
    ('T821', 'cardiac_arrhythmias'),
    ('Z450', 'cardiac_arrhythmias'),
    ('Z950', 'cardiac_arrhythmias'),

	-- Blood loss anemia
   ('D500', 'blood_loss_anemia'),

   -- Congestive heart failure
   ('I099', 'congestive_heart_failure'),
   ('I110', 'congestive_heart_failure'),
   ('I130', 'congestive_heart_failure'),
   ('I132', 'congestive_heart_failure'),
   ('I255', 'congestive_heart_failure'),
   ('I420', 'congestive_heart_failure'),
   ('I425', 'congestive_heart_failure'),
   ('I426', 'congestive_heart_failure'),
   ('I427', 'congestive_heart_failure'),
   ('I428', 'congestive_heart_failure'),
   ('I429', 'congestive_heart_failure'),
   ('I43', 'congestive_heart_failure'),
   ('I50', 'congestive_heart_failure'),
   ('P290', 'congestive_heart_failure'),

   -- Chronic pulmonary disease
   ('I278', 'chronic_pulmonary_disease'),
   ('I279', 'chronic_pulmonary_disease'),
   ('J40', 'chronic_pulmonary_disease'),
   ('J41', 'chronic_pulmonary_disease'),
   ('J42', 'chronic_pulmonary_disease'),
   ('J43', 'chronic_pulmonary_disease'),
   ('J44', 'chronic_pulmonary_disease'),
   ('J45', 'chronic_pulmonary_disease'),
   ('J46', 'chronic_pulmonary_disease'),
   ('J47', 'chronic_pulmonary_disease'),
   ('J60', 'chronic_pulmonary_disease'),
   ('J61', 'chronic_pulmonary_disease'),
   ('J62', 'chronic_pulmonary_disease'),
   ('J63', 'chronic_pulmonary_disease'),
   ('J64', 'chronic_pulmonary_disease'),
   ('J65', 'chronic_pulmonary_disease'),
   ('J66', 'chronic_pulmonary_disease'),
   ('J67', 'chronic_pulmonary_disease'),
   ('J684', 'chronic_pulmonary_disease'),
   ('J701', 'chronic_pulmonary_disease'),
   ('J703', 'chronic_pulmonary_disease'),

   -- Coagulopathy
   ('D65', 'coagulopathy'),
   ('D66', 'coagulopathy'),
   ('D67', 'coagulopathy'),
   ('D68', 'coagulopathy'),
   ('D691', 'coagulopathy'),
   ('D693', 'coagulopathy'),
   ('D694', 'coagulopathy'),
   ('D695', 'coagulopathy'),
   ('D696', 'coagulopathy'),

   -- Deficiency anemia
   ('D508', 'deficiency_anemia'),
   ('D509', 'deficiency_anemia'),
   ('D51', 'deficiency_anemia'),
   ('D52', 'deficiency_anemia'),
   ('D53', 'deficiency_anemia'),

   -- Depression
   ('F204', 'depression'),
   ('F313', 'depression'),
   ('F314', 'depression'),
   ('F315', 'depression'),
   ('F32', 'depression'),
   ('F33', 'depression'),
   ('F341', 'depression'),
   ('F412', 'depression'),
   ('F432', 'depression'),

   -- Diabetes complicated
   ('E102', 'diabetes_complicated'),
   ('E103', 'diabetes_complicated'),
   ('E104', 'diabetes_complicated'),
   ('E105', 'diabetes_complicated'),
   ('E106', 'diabetes_complicated'),
   ('E107', 'diabetes_complicated'),
   ('E108', 'diabetes_complicated'),
   ('E112', 'diabetes_complicated'),
   ('E113', 'diabetes_complicated'),
   ('E114', 'diabetes_complicated'),
   ('E115', 'diabetes_complicated'),
   ('E116', 'diabetes_complicated'),
   ('E117', 'diabetes_complicated'),
   ('E118', 'diabetes_complicated'),
   ('E122', 'diabetes_complicated'),
   ('E123', 'diabetes_complicated'),
   ('E124', 'diabetes_complicated'),
   ('E125', 'diabetes_complicated'),
   ('E126', 'diabetes_complicated'),
   ('E127', 'diabetes_complicated'),
   ('E128', 'diabetes_complicated'),
   ('E132', 'diabetes_complicated'),
   ('E133', 'diabetes_complicated'),
   ('E134', 'diabetes_complicated'),
   ('E135', 'diabetes_complicated'),
   ('E136', 'diabetes_complicated'),
   ('E137', 'diabetes_complicated'),
   ('E138', 'diabetes_complicated'),
   ('E142', 'diabetes_complicated'),
   ('E143', 'diabetes_complicated'),
   ('E144', 'diabetes_complicated'),
   ('E145', 'diabetes_complicated'),
   ('E146', 'diabetes_complicated'),
   ('E147', 'diabetes_complicated'),
   ('E148', 'diabetes_complicated'),

   -- Diabetes uncomplicated
   ('E100', 'diabetes_uncomplicated'),
   ('E101', 'diabetes_uncomplicated'),
   ('E109', 'diabetes_uncomplicated'),
   ('E110', 'diabetes_uncomplicated'),
   ('E111', 'diabetes_uncomplicated'),
   ('E119', 'diabetes_uncomplicated'),
   ('E120', 'diabetes_uncomplicated'),
   ('E121', 'diabetes_uncomplicated'),
   ('E129', 'diabetes_uncomplicated'),
   ('E130', 'diabetes_uncomplicated'),
   ('E131', 'diabetes_uncomplicated'),
   ('E139', 'diabetes_uncomplicated'),
   ('E140', 'diabetes_uncomplicated'),
   ('E141', 'diabetes_uncomplicated'),
   ('E149', 'diabetes_uncomplicated'),

   -- Drug abuse
   ('F11', 'drug_abuse'),
   ('F12', 'drug_abuse'),
   ('F13', 'drug_abuse'),
   ('F14', 'drug_abuse'),
   ('F15', 'drug_abuse'),
   ('F16', 'drug_abuse'),
   ('F18', 'drug_abuse'),
   ('F19', 'drug_abuse'),
   ('Z715', 'drug_abuse'),
   ('Z722', 'drug_abuse'),

   -- Fluid and electrolyte disorders
   ('E222', 'fluid_electrolyte_disorders'),
   ('E86', 'fluid_electrolyte_disorders'),
   ('E87', 'fluid_electrolyte_disorders'),

   -- AIDS/HIV
   ('B20', 'aids_hiv'),
   ('B21', 'aids_hiv'),
   ('B22', 'aids_hiv'),
   ('B24', 'aids_hiv'),

   -- Hypertension complicated
   ('I11', 'hypertension_complicated'),
   ('I12', 'hypertension_complicated'),
   ('I13', 'hypertension_complicated'),
   ('I15', 'hypertension_complicated'),

   -- Hypertension uncomplicated
   ('I10', 'hypertension_uncomplicated'),

   -- Hypothyroidism
   ('E00', 'hypothyroidism'),
   ('E01', 'hypothyroidism'),
   ('E02', 'hypothyroidism'),
   ('E03', 'hypothyroidism'),
   ('E890', 'hypothyroidism'),

   -- Liver disease
   ('B18', 'liver_disease'),
   ('I85', 'liver_disease'),
   ('I864', 'liver_disease'),
   ('I982', 'liver_disease'),
   ('K70', 'liver_disease'),
   ('K711', 'liver_disease'),
   ('K713', 'liver_disease'),
   ('K714', 'liver_disease'),
   ('K715', 'liver_disease'),
   ('K717', 'liver_disease'),
   ('K72', 'liver_disease'),
   ('K73', 'liver_disease'),
   ('K74', 'liver_disease'),
   ('K760', 'liver_disease'),
   ('K762', 'liver_disease'),
   ('K763', 'liver_disease'),
   ('K764', 'liver_disease'),
   ('K765', 'liver_disease'),
   ('K766', 'liver_disease'),
   ('K767', 'liver_disease'),
   ('K768', 'liver_disease'),
   ('K769', 'liver_disease'),
   ('Z944', 'liver_disease'),

   -- Lymphoma
   ('C81', 'lymphoma'),
   ('C82', 'lymphoma'),
   ('C83', 'lymphoma'),
   ('C84', 'lymphoma'),
   ('C85', 'lymphoma'),
   ('C88', 'lymphoma'),
   ('C96', 'lymphoma'),
   ('C900', 'lymphoma'),
   ('C902', 'lymphoma'),

   -- Metastatic cancer
   ('C77', 'metastatic_cancer'),
   ('C78', 'metastatic_cancer'),
   ('C79', 'metastatic_cancer'),
   ('C80', 'metastatic_cancer'),

   -- Obesity
   ('E66', 'obesity'),

   -- Other neurological disorders
   ('G10', 'other_neurological_disorders'),
   ('G11', 'other_neurological_disorders'),
   ('G12', 'other_neurological_disorders'),
   ('G13', 'other_neurological_disorders'),
   ('G20', 'other_neurological_disorders'),
   ('G21', 'other_neurological_disorders'),
   ('G22', 'other_neurological_disorders'),
   ('G254', 'other_neurological_disorders'),
   ('G255', 'other_neurological_disorders'),
   ('G312', 'other_neurological_disorders'),
   ('G318', 'other_neurological_disorders'),
   ('G319', 'other_neurological_disorders'),
   ('G32', 'other_neurological_disorders'),
   ('G35', 'other_neurological_disorders'),
   ('G36', 'other_neurological_disorders'),
   ('G37', 'other_neurological_disorders'),
   ('G40', 'other_neurological_disorders'),
   ('G41', 'other_neurological_disorders'),
   ('G931', 'other_neurological_disorders'),
   ('G934', 'other_neurological_disorders'),
   ('R470', 'other_neurological_disorders'),
   ('R56', 'other_neurological_disorders'),

   -- Pulmonary circulation disorder
   ('I26', 'pulmonary_circulation_disorder'),
   ('I27', 'pulmonary_circulation_disorder'),
   ('I280', 'pulmonary_circulation_disorder'),
   ('I288', 'pulmonary_circulation_disorder'),
   ('I289', 'pulmonary_circulation_disorder'),

   -- Peptic ulcer disease excluding bleeding
   ('K257', 'peptic_ulcer_disease_excluding_bleeding'),
   ('K259', 'peptic_ulcer_disease_excluding_bleeding'),
   ('K267', 'peptic_ulcer_disease_excluding_bleeding'),
   ('K269', 'peptic_ulcer_disease_excluding_bleeding'),
   ('K277', 'peptic_ulcer_disease_excluding_bleeding'),
   ('K279', 'peptic_ulcer_disease_excluding_bleeding'),
   ('K287', 'peptic_ulcer_disease_excluding_bleeding'),
   ('K289', 'peptic_ulcer_disease_excluding_bleeding'),

   -- Pulmonary valvular disorder
   ('I70', 'pulmonary_valvular_disorder'),
   ('I71', 'pulmonary_valvular_disorder'),
   ('I731', 'pulmonary_valvular_disorder'),
   ('I738', 'pulmonary_valvular_disorder'),
   ('I739', 'pulmonary_valvular_disorder'),
   ('I771', 'pulmonary_valvular_disorder'),
   ('I790', 'pulmonary_valvular_disorder'),
   ('I792', 'pulmonary_valvular_disorder'),
   ('K551', 'pulmonary_valvular_disorder'),
   ('K558', 'pulmonary_valvular_disorder'),
   ('K559', 'pulmonary_valvular_disorder'),
   ('Z958', 'pulmonary_valvular_disorder'),
   ('Z959', 'pulmonary_valvular_disorder'),

   -- Paralysis
   ('G041', 'paralysis'),
   ('G114', 'paralysis'),
   ('G801', 'paralysis'),
   ('G802', 'paralysis'),
   ('G81', 'paralysis'),
   ('G82', 'paralysis'),
   ('G830', 'paralysis'),
   ('G831', 'paralysis'),
   ('G832', 'paralysis'),
   ('G833', 'paralysis'),
   ('G834', 'paralysis'),
   ('G839', 'paralysis'),

   -- Psychoses
   ('F20', 'psychoses'),
   ('F22', 'psychoses'),
   ('F23', 'psychoses'),
   ('F24', 'psychoses'),
   ('F25', 'psychoses'),
   ('F28', 'psychoses'),
   ('F29', 'psychoses'),
   ('F302', 'psychoses'),
   ('F312', 'psychoses'),
   ('F315', 'psychoses'),

   -- Renal failure
   ('I120', 'renal_failure'),
   ('I131', 'renal_failure'),
   ('N18', 'renal_failure'),
   ('N19', 'renal_failure'),
   ('N250', 'renal_failure'),
   ('Z490', 'renal_failure'),
   ('Z491', 'renal_failure'),
   ('Z492', 'renal_failure'),
   ('Z940', 'renal_failure'),
   ('Z992', 'renal_failure'),

   -- Rheumatoid arthritis/collagen vascular diseases
   ('L940', 'rheumatoid_arthritis_collagen_vascular'),
   ('L941', 'rheumatoid_arthritis_collagen_vascular'),
   ('L943', 'rheumatoid_arthritis_collagen_vascular'),
   ('M05', 'rheumatoid_arthritis_collagen_vascular'),
   ('M06', 'rheumatoid_arthritis_collagen_vascular'),
   ('M08', 'rheumatoid_arthritis_collagen_vascular'),
   ('M120', 'rheumatoid_arthritis_collagen_vascular'),
   ('M123', 'rheumatoid_arthritis_collagen_vascular'),
   ('M30', 'rheumatoid_arthritis_collagen_vascular'),
   ('M310', 'rheumatoid_arthritis_collagen_vascular'),
   ('M311', 'rheumatoid_arthritis_collagen_vascular'),
   ('M312', 'rheumatoid_arthritis_collagen_vascular'),
   ('M313', 'rheumatoid_arthritis_collagen_vascular'),
   ('M32', 'rheumatoid_arthritis_collagen_vascular'),
   ('M33', 'rheumatoid_arthritis_collagen_vascular'),
   ('M34', 'rheumatoid_arthritis_collagen_vascular'),
   ('M35', 'rheumatoid_arthritis_collagen_vascular'),
   ('M45', 'rheumatoid_arthritis_collagen_vascular'),
   ('M461', 'rheumatoid_arthritis_collagen_vascular'),
   ('M468', 'rheumatoid_arthritis_collagen_vascular'),
   ('M469', 'rheumatoid_arthritis_collagen_vascular'),

   -- Solid tumor without metastasis
   ('C0', 'solid_tumor_without_metastasis'),
   ('C1', 'solid_tumor_without_metastasis'),
   ('C20', 'solid_tumor_without_metastasis'),
   ('C21', 'solid_tumor_without_metastasis'),
   ('C22', 'solid_tumor_without_metastasis'),
   ('C23', 'solid_tumor_without_metastasis'),
   ('C24', 'solid_tumor_without_metastasis'),
   ('C25', 'solid_tumor_without_metastasis'),
   ('C26', 'solid_tumor_without_metastasis'),
   ('C30', 'solid_tumor_without_metastasis'),
   ('C31', 'solid_tumor_without_metastasis'),
   ('C32', 'solid_tumor_without_metastasis'),
   ('C33', 'solid_tumor_without_metastasis'),
   ('C34', 'solid_tumor_without_metastasis'),
   ('C37', 'solid_tumor_without_metastasis'),
   ('C38', 'solid_tumor_without_metastasis'),
   ('C39', 'solid_tumor_without_metastasis'),
   ('C40', 'solid_tumor_without_metastasis'),
   ('C41', 'solid_tumor_without_metastasis'),
   ('C43', 'solid_tumor_without_metastasis'),
   ('C45', 'solid_tumor_without_metastasis'),
   ('C46', 'solid_tumor_without_metastasis'),
   ('C47', 'solid_tumor_without_metastasis'),
   ('C48', 'solid_tumor_without_metastasis'),
   ('C49', 'solid_tumor_without_metastasis'),
   ('C50', 'solid_tumor_without_metastasis'),
   ('C51', 'solid_tumor_without_metastasis'),
   ('C52', 'solid_tumor_without_metastasis'),
   ('C53', 'solid_tumor_without_metastasis'),
   ('C54', 'solid_tumor_without_metastasis'),
   ('C55', 'solid_tumor_without_metastasis'),
   ('C56', 'solid_tumor_without_metastasis'),
   ('C57', 'solid_tumor_without_metastasis'),
   ('C58', 'solid_tumor_without_metastasis'),
   ('C6', 'solid_tumor_without_metastasis'),
   ('C70', 'solid_tumor_without_metastasis'),
   ('C71', 'solid_tumor_without_metastasis'),
   ('C72', 'solid_tumor_without_metastasis'),
   ('C73', 'solid_tumor_without_metastasis'),
   ('C74', 'solid_tumor_without_metastasis'),
   ('C75', 'solid_tumor_without_metastasis'),
   ('C76', 'solid_tumor_without_metastasis'),
   ('C97', 'solid_tumor_without_metastasis'),

   -- Valvular disease
   ('A520', 'valvular_disease'),
   ('I05', 'valvular_disease'),
   ('I06', 'valvular_disease'),
   ('I07', 'valvular_disease'),
   ('I08', 'valvular_disease'),
   ('I091', 'valvular_disease'),
   ('I098', 'valvular_disease'),
   ('I34', 'valvular_disease'),
   ('I35', 'valvular_disease'),
   ('I36', 'valvular_disease'),
   ('I37', 'valvular_disease'),
   ('I38', 'valvular_disease'),
   ('I39', 'valvular_disease'),
   ('Q230', 'valvular_disease'),
   ('Q231', 'valvular_disease'),
   ('Q232', 'valvular_disease'),
   ('Q233', 'valvular_disease'),
   ('Z952', 'valvular_disease'),
   ('Z953', 'valvular_disease'),
   ('Z954', 'valvular_disease'),

   -- Weight loss
   ('E40', 'weight_loss'),
   ('E41', 'weight_loss'),
   ('E42', 'weight_loss'),
   ('E43', 'weight_loss'),
   ('E44', 'weight_loss'),
   ('E45', 'weight_loss'),
   ('E46', 'weight_loss'),
   ('R634', 'weight_loss'),
   ('R64', 'weight_loss');
-- ============================================
-- Get relevant diagnosis events for our cohort within date range
-- ============================================
DROP TABLE IF EXISTS #DiagnosisStaging
SELECT 
    c.PatientDurableKey,
    c.EncounterKey,
    c.Date AS EncounterDate,
    def.StartDateKey,
    dtd.Value AS ICD10Code,
    dm.DiagnosisType
INTO #DiagnosisStaging
FROM ##FinalCohortWithLabs c
INNER JOIN DiagnosisEventFact def
    ON c.PatientDurableKey = def.PatientDurableKey
INNER JOIN DiagnosisTerminologyDim dtd
    ON def.DiagnosisKey = dtd.DiagnosisKey
INNER JOIN #DiagnosisMapping dm
    ON REPLACE(dtd.Value, '.', '') LIKE dm.ICD10Code + '%'
WHERE 
    dtd.Type = 'ICD-10-CM'
    AND def.StartDateKey > 0
    AND def.StartDateKey <= CONVERT(VARCHAR(8), c.Date, 112)  -- All previous diagnoses

select top (30) * from #DiagnosisStaging
-- ============================================
-- Aggregate diagnosis counts by patient and diagnosis type
-- ============================================
DROP TABLE IF EXISTS #DiagnosisAggregates
SELECT 
    PatientDurableKey,
    EncounterKey,
    DiagnosisType,
    COUNT(*) AS diagnosis_total_count,
    SUM(CASE WHEN StartDateKey >= CONVERT(VARCHAR(8), DATEADD(YEAR, -1, EncounterDate), 112) 
             THEN 1 ELSE 0 END) AS diagnosis_recent_count
INTO #DiagnosisAggregates
FROM #DiagnosisStaging
GROUP BY PatientDurableKey, EncounterKey, DiagnosisType

-- ============================================
-- Build dynamic SQL to pivot diagnosis counts into columns
-- ============================================
DECLARE @sql NVARCHAR(MAX) = ''
DECLARE @selectCols NVARCHAR(MAX) = ''
DECLARE @joins NVARCHAR(MAX) = ''
DECLARE @diagType VARCHAR(100), @alias VARCHAR(100)
DECLARE @CRLF NVARCHAR(2) = CHAR(13) + CHAR(10)

-- Cursor over distinct diagnosis types
DECLARE diag_cursor CURSOR FOR
SELECT DISTINCT DiagnosisType FROM #DiagnosisMapping
OPEN diag_cursor
FETCH NEXT FROM diag_cursor INTO @diagType

WHILE @@FETCH_STATUS = 0
BEGIN
    -- Create alias for this diagnosis type join
    SET @alias = 'diag_' + @diagType
    -- Build SELECT columns for this diagnosis counts (both total and recent)
    SET @selectCols = @selectCols + @CRLF +
        '    ' + @alias + '.diagnosis_total_count AS ' + @diagType + '_total_count,' + @CRLF +
        '    ' + @alias + '.diagnosis_recent_count AS ' + @diagType + '_recent_count,' + @CRLF
    -- Build LEFT JOIN for this diagnosis aggregated data
    SET @joins = @joins + @CRLF +
        'LEFT JOIN #DiagnosisAggregates ' + @alias + @CRLF +
        '    ON c.PatientDurableKey = ' + @alias + '.PatientDurableKey' + @CRLF +
        '   AND c.EncounterKey = ' + @alias + '.EncounterKey' + @CRLF +
        '   AND ' + @alias + '.DiagnosisType = ''' + @diagType + '''' + @CRLF
    FETCH NEXT FROM diag_cursor INTO @diagType
END

CLOSE diag_cursor
DEALLOCATE diag_cursor

-- Remove trailing comma from SELECT columns string
SET @selectCols = LEFT(@selectCols, LEN(@selectCols) - 3)
-- Build final dynamic SQL
SET @sql = '
DROP TABLE IF EXISTS ##FinalCohortWithLabsAndDiagnoses
SELECT c.*,' + @selectCols + '
INTO ##FinalCohortWithLabsAndDiagnoses
FROM ##FinalCohortWithLabs c' + @joins

-- Execute the dynamic SQL
EXEC sp_executesql @sql
-- ============================================
-- View Final Results
-- ============================================
SELECT TOP (10) *
FROM ##FinalCohortWithLabsAndDiagnoses

-- Dynamically creates CREATE TABLE statement to copy and paste
SELECT 
   '    ' + COLUMN_NAME + ' ' + 
   UPPER(DATA_TYPE) + 
   CASE 
       WHEN DATA_TYPE IN ('varchar','nvarchar','char','nchar') AND CHARACTER_MAXIMUM_LENGTH IS NOT NULL
       THEN '(' + CAST(CHARACTER_MAXIMUM_LENGTH AS VARCHAR) + ')'
       WHEN DATA_TYPE IN ('decimal','numeric') AND NUMERIC_PRECISION IS NOT NULL
       THEN '(' + CAST(NUMERIC_PRECISION AS VARCHAR) + ',' + CAST(NUMERIC_SCALE AS VARCHAR) + ')'
       ELSE '' 
   END + 
   CASE WHEN IS_NULLABLE = 'NO' THEN ' NOT NULL' ELSE '' END + 
   CASE WHEN ORDINAL_POSITION < (SELECT MAX(ORDINAL_POSITION) FROM tempdb.INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME LIKE '##FinalCohortWithLabsAndDiagnoses%') THEN ',' ELSE '' END AS ColumnDefinition
FROM tempdb.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME LIKE '##FinalCohortWithLabsAndDiagnoses%'
ORDER BY ORDINAL_POSITION

-- Run Save_To_Projects_Code file before this
INSERT INTO PROJECTS.ProjectD41E126.dbo.AAG_SWOG_Cohort
SELECT *
FROM ##FinalCohortWithLabsAndDiagnoses


